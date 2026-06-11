import AppKit

/// Pure recording lifecycle: a transition function from (phase, event) to
/// (next phase, side effect to perform). The Process handle deliberately
/// lives in RecordingService, not in the enum, so phases stay Equatable.
enum RecordingStateMachine {
    enum Phase: Equatable {
        case idle, selectingRegion, recording, finishing
    }

    enum Event: Equatable {
        case toggle           // hotkey or menu item
        case regionConfirmed  // picker delivered a region / fullScreen
        case regionCancelled  // picker Esc
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
            return (.recording, .startProcess)
        case (.selectingRegion, .regionCancelled):
            return (.idle, .none)
        case (.selectingRegion, .toggle):
            return (.idle, .dismissRegionPicker)
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

    /// Finished file (may not exist / be empty — consumer checks), or nil
    /// when nothing was recorded. Set by CaptureController.
    var onFinished: ((URL?) -> Void)?
    /// Phase observer for the HUD and the menu-item title.
    var onPhaseChange: ((RecordingStateMachine.Phase) -> Void)?

    var isRecording: Bool { phase == .recording || phase == .finishing }

    func toggle() { handle(.toggle) }
    func stop() { handle(.stopRequested) }

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
                    self.handle(.regionConfirmed)
                case .region(let cocoaRect):
                    self.pendingRegion = cocoaRect
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
