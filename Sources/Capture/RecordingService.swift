import AppKit

/// Pure recording lifecycle: a transition function from (phase, event) to
/// (next phase, side effect to perform). The Process handle deliberately
/// lives in RecordingService, not in the enum, so phases stay Equatable.
enum RecordingStateMachine {
    enum Phase: Equatable {
        case idle, selectingRegion, armed, recording, finishing
    }

    enum Event: Equatable {
        case toggle           // hotkey or menu item
        case regionConfirmed  // picker delivered a region / fullScreen
        case regionCancelled  // picker Esc / armed-HUD Cancel button
        case startRequested   // armed-HUD Start button
        case stopRequested    // HUD Stop button
        case processExited    // screencapture terminated (any reason)
    }

    enum Action: Equatable {
        case presentRegionPicker
        case dismissRegionPicker
        case startProcess
        case stopProcess
        case finalize
        case none
    }

    static func transition(from phase: Phase, on event: Event) -> (phase: Phase, action: Action) {
        switch (phase, event) {
        case (.idle, .toggle):
            return (.selectingRegion, .presentRegionPicker)
        case (.selectingRegion, .regionConfirmed):
            return (.armed, .none)   // selection done; wait for explicit Start
        case (.selectingRegion, .regionCancelled):
            return (.idle, .none)
        case (.selectingRegion, .toggle):
            return (.idle, .dismissRegionPicker)
        case (.armed, .startRequested), (.armed, .toggle):
            return (.recording, .startProcess)   // hotkey also starts when armed
        case (.armed, .regionCancelled):
            return (.idle, .dismissRegionPicker) // tear the frozen overlay down
        case (.recording, .toggle), (.recording, .stopRequested):
            return (.finishing, .stopProcess)
        case (.recording, .processExited):
            return (.idle, .finalize)   // crashed / killed externally — recover
        case (.finishing, .processExited):
            return (.idle, .finalize)
        default:
            return (phase, .none)
        }
    }
}

/// Owns the screen-recording flow: region picker → screencapture -v process
/// → SIGINT to stop → finished-file callback. Impure shell around the pure
/// state machine above. Main-thread only (all entry points are UI events;
/// the termination handler hops to main).
final class RecordingService {
    private(set) var phase: RecordingStateMachine.Phase = .idle
    private let picker = RegionPicker()
    private var process: Process?
    private var outputURL: URL?
    private var pendingRegion: CGRect?   // Cocoa coords; nil = entire screen
    /// The confirmed selection (Cocoa coords) for HUD placement; survives
    /// through the recording phase, cleared on finalize. nil = full screen.
    private(set) var currentRegion: CGRect?

    /// Finished file (may not exist / be empty — consumer checks), or nil
    /// when nothing was recorded. Set by CaptureController.
    var onFinished: ((URL?) -> Void)?
    /// Phase observer for the HUD and the menu-item title.
    var onPhaseChange: ((RecordingStateMachine.Phase) -> Void)?

    var isRecording: Bool { phase == .recording || phase == .finishing }

    func toggle() { handle(.toggle) }
    func stop() { handle(.stopRequested) }
    func startArmed() { handle(.startRequested) }
    func cancelArmed() { handle(.regionCancelled) }

    /// Cut a clear opening in the dim overlay at the REC controls' frame
    /// (GLOBAL Cocoa coords) so the Stop pill never sits under the dark
    /// layer. The HUD belongs to CaptureController, hence the hand-off.
    func revealControls(at globalRect: CGRect?) {
        picker.cutControlsOpening(at: globalRect)
    }

    private func handle(_ event: RecordingStateMachine.Event) {
        let (next, action) = RecordingStateMachine.transition(from: phase, on: event)
        phase = next
        onPhaseChange?(next)
        switch action {
        case .presentRegionPicker:
            picker.present { [weak self] result in
                guard let self else { return }
                switch result {
                case .cancelled:
                    self.handle(.regionCancelled)
                case .fullScreen:
                    self.pendingRegion = nil
                    self.currentRegion = nil
                    self.handle(.regionConfirmed)
                case .region(let cocoaRect):
                    self.pendingRegion = cocoaRect
                    self.currentRegion = cocoaRect
                    self.handle(.regionConfirmed)
                }
            }
        case .dismissRegionPicker:
            picker.dismiss()
        case .startProcess:
            startProcess()
        case .stopProcess:
            process?.interrupt()   // SIGINT — screencapture finalizes the .mov
        case .finalize:
            picker.dismiss()        // overlay stays up through recording; drop it now
            currentRegion = nil
            let url = outputURL
            process = nil
            outputURL = nil
            onFinished?(url)
        case .none:
            break
        }
    }

    private func startProcess() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuse-recording-\(UUID().uuidString).mov")
        outputURL = url
        var args = ["-v"]
        if let cocoaRect = pendingRegion {
            // screencapture -R wants GLOBAL points with TOP-LEFT origin.
            let primaryHeight = NSScreen.screens[0].frame.height
            let r = CaptureGeometry.topLeftRect(fromCocoaRect: cocoaRect,
                                                primaryScreenHeight: primaryHeight)
            args += ["-R", String(format: "%.0f,%.0f,%.0f,%.0f",
                                  r.minX, r.minY, r.width, r.height)]
        }
        args.append(url.path)
        pendingRegion = nil

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = args
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.handle(.processExited)
            }
        }
        do {
            try proc.run()
            process = proc
            Log.capture.info("recording started → \(url.path, privacy: .public)")
        } catch {
            Log.capture.error("screencapture -v failed to launch: \(error.localizedDescription, privacy: .public)")
            outputURL = nil
            handle(.processExited)   // → idle, finalize(nil)
        }
    }
}
