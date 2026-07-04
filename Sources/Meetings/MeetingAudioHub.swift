import AVFoundation

/// Fans a single 16 kHz mono Float32 stream to the transcriber. Mic runs on
/// AVAudioEngine (AudioRecorderLiveTap); system audio (optional) runs on
/// SCStream. For mic+system the two legs are summed sample-for-sample on one
/// serial clock (see the spec's §8 for the long-meeting drift caveat).
///
/// @unchecked Sendable: the cross-thread state (`pendingSystem`, `stopped`,
/// `onFrame`, the mix) is touched only inside `clock.async`/`clock.sync`, which
/// serializes it.
final class MeetingAudioHub: @unchecked Sendable {
    private let mode: AudioSourceMode
    private let micRecorder = AudioRecorderLiveTap()
    private var sysCapture: SystemAudioCapture?
    private let clock = DispatchQueue(label: "com.rgv250cc.fuse.meeting.clock")
    private var onFrame: (([Float]) -> Void)?
    private var pendingSystem: [Float] = []
    private var stopped = false

    /// Called (off the main thread) if a capture leg degrades mid-session.
    var onDegrade: ((String) -> Void)?

    /// ~3 s of 16 kHz system audio — caps memory and mix latency if the mic stalls.
    private static let systemCapSamples = 16000 * 3

    init(mode: AudioSourceMode) { self.mode = mode }

    func start(onFrame: @escaping ([Float]) -> Void) async throws {
        clock.sync { self.onFrame = onFrame; self.stopped = false; self.pendingSystem.removeAll() }
        try micRecorder.start { [weak self] frame in
            self?.clock.async { self?.ingest(mic: frame) }
        }
        if mode == .micSystem {
            if #available(macOS 12.3, *) {
                let sys = SystemAudioCapture()
                sys.onError = { [weak self] err in
                    self?.onDegrade?("System audio stopped (\(err.localizedDescription)); continuing mic-only.")
                }
                try await sys.start { [weak self] frame in
                    self?.clock.async {
                        guard let self, !self.stopped else { return }
                        self.pendingSystem.append(contentsOf: frame)
                        let overflow = self.pendingSystem.count - Self.systemCapSamples
                        if overflow > 0 { self.pendingSystem.removeFirst(overflow) }   // drop oldest
                    }
                }
                sysCapture = sys
            }
        }
    }

    private func ingest(mic: [Float]) {   // runs on clock
        guard !stopped, !mic.isEmpty else { return }
        let n = mic.count
        let out: [Float]
        if mode == .micSystem {
            let m = min(n, pendingSystem.count)
            var mixed = [Float](repeating: 0, count: n)
            for i in 0..<n {
                if i < m {
                    mixed[i] = max(-1, min(1, (mic[i] + pendingSystem[i]) * 0.8))  // headroom while both hot
                } else {
                    mixed[i] = max(-1, min(1, mic[i]))                            // mic-only stretch: unity
                }
            }
            if m > 0 { pendingSystem.removeFirst(m) }   // in-place drain, no realloc of the tail
            out = mixed
        } else {
            out = mic
        }
        onFrame?(out)
    }

    func stop() async {
        _ = micRecorder.stop()
        if let sysCapture { await sysCapture.stop() }
        // Barrier: drain queued ingest blocks, then drop any further frames.
        clock.sync { self.stopped = true; self.onFrame = nil; self.pendingSystem.removeAll() }
    }
}
