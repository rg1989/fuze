import Foundation
import os

/// Detects utterance boundaries from real audio silence — the reliable "the
/// speaker paused" signal (Parakeet's streaming token timings don't reflect
/// silence well). Fed each 16 kHz mono frame from the audio thread; records the
/// audio-clock time (seconds from stream start, the SAME origin as ASR token
/// timings) at the moment speech RESUMES after `pauseSeconds` of quiet.
/// Thread-safe.
final class PauseSegmenter: @unchecked Sendable {
    private struct State {
        var fedSamples = 0
        var silentSamples = 0
        var inSilence = true      // start "in silence" so the first speech isn't a boundary
        var boundaries: [Double] = []
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let pauseSamples: Int
    private let sampleRate = 16000.0
    private let silenceThreshold: Float = 0.02   // peak amplitude; speech clears this easily

    init(pauseSeconds: Double = 1.5) { pauseSamples = Int(pauseSeconds * 16000) }

    func process(_ frame: [Float]) {
        guard !frame.isEmpty else { return }
        var peak: Float = 0
        for x in frame { let a = abs(x); if a > peak { peak = a } }
        let silent = peak < silenceThreshold
        lock.withLock { s in
            if silent {
                s.silentSamples += frame.count
                if s.silentSamples >= pauseSamples { s.inSilence = true }
            } else {
                if s.inSilence && s.fedSamples > 0 {
                    s.boundaries.append(Double(s.fedSamples) / sampleRate)   // new utterance starts here
                }
                s.inSilence = false
                s.silentSamples = 0
            }
            s.fedSamples += frame.count
        }
    }

    /// Audio-clock times (seconds) where a new utterance begins.
    func boundaries() -> [Double] { lock.withLock { $0.boundaries } }
}
