import Foundation

/// Splits a continuous 16 kHz mono Float32 stream into utterances for batch
/// transcription: an utterance starts on speech, ends after `pauseSeconds` of
/// silence, or after `maxSeconds` of continuous speech (a latency cap so a
/// non-stop talker still gets periodic output). Leading silence is dropped.
/// Emits each utterance's samples + [start,end] in audio-clock seconds (the same
/// clock the diarizer sees). Fed from the audio thread; all state lives on one
/// serial queue, so it is safe to call `feed` concurrently with `flush`.
final class UtteranceBuffer: @unchecked Sendable {
    private let q = DispatchQueue(label: "com.rgv250cc.fuse.meeting.uttbuf")
    private var samples: [Float] = []
    private var startTime = 0.0
    private var fedSamples = 0
    private var silentSamples = 0
    private var speaking = false
    private let rate = 16000.0
    private let pauseSamples: Int
    private let maxSamples: Int
    private let threshold: Float = 0.02   // peak amplitude; speech clears this easily

    /// Fires (on the buffer queue) when an utterance completes.
    var onUtterance: ((_ samples: [Float], _ start: Double, _ end: Double) -> Void)?
    /// Fires (on the buffer queue) each frame with live capture state.
    var onStatus: ((_ speaking: Bool, _ seconds: Double) -> Void)?

    init(pauseSeconds: Double = 1.0, maxSeconds: Double = 12) {
        pauseSamples = Int(pauseSeconds * 16000)
        maxSamples = Int(maxSeconds * 16000)
    }

    func feed(_ frame: [Float]) { q.async { [weak self] in self?.ingest(frame) } }

    /// Force-close the in-progress utterance (call at stop, on the caller thread).
    func flush() { q.sync { self.close() } }

    private func ingest(_ frame: [Float]) {
        guard !frame.isEmpty else { return }
        var peak: Float = 0
        for x in frame { let a = abs(x); if a > peak { peak = a } }
        let isSilent = peak < threshold
        let frameTime = Double(fedSamples) / rate
        fedSamples += frame.count

        if speaking {
            samples.append(contentsOf: frame)
            if isSilent {
                silentSamples += frame.count
                if silentSamples >= pauseSamples { close(); return }   // pause → end utterance
            } else {
                silentSamples = 0
            }
            if samples.count >= maxSamples { close(); return }         // latency cap
            onStatus?(true, Double(samples.count) / rate)
        } else if !isSilent {
            speaking = true
            startTime = frameTime
            samples.append(contentsOf: frame)
            silentSamples = 0
            onStatus?(true, Double(samples.count) / rate)
        } else {
            onStatus?(false, 0)   // waiting for speech (leading silence dropped)
        }
    }

    private func close() {
        defer { samples = []; speaking = false; silentSamples = 0 }
        guard speaking, !samples.isEmpty else { return }
        // Trim the trailing silence that closed the utterance (keep a 0.15s margin
        // so word tails aren't clipped) — it degrades ASR and inflates timecodes.
        let margin = 2400   // 0.15s at 16 kHz
        let keep = silentSamples > 0 ? max(0, samples.count - silentSamples + margin) : samples.count
        let out = keep < samples.count ? Array(samples[0..<keep]) : samples
        guard !out.isEmpty else { return }
        onUtterance?(out, startTime, startTime + Double(out.count) / rate)
        onStatus?(false, 0)
    }
}
