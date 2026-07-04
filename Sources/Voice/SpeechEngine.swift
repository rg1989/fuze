import FluidAudio
import Foundation

/// A swappable speech-to-text backend. Two impls: `Transcriber` (WhisperKit,
/// multilingual) and `ParakeetTranscriber` (FluidAudio, English-only, faster).
/// The active engine is chosen by the "voice.engine" default.
protocol SpeechEngine: Sendable {
    /// Idempotent load. `modelName` is meaningful only to Whisper; Parakeet
    /// ignores it (it has a single fixed model).
    func prepare(modelName: String) async throws
    /// Transcribes 16 kHz mono Float32 samples. `language` is a two-letter code
    /// used by multilingual Whisper models; Parakeet (English-only) ignores it.
    func transcribe(samples: [Float], language: String) async throws -> String
}

/// Parakeet (NVIDIA) speech-to-text via FluidAudio's CoreML models. Uses the
/// English-only v2 model — top English accuracy and much faster than Whisper.
/// First prepare() downloads parakeet-tdt-0.6b-v2-coreml from Hugging Face;
/// cached on disk after.
// ponytail: hardcoded to v2 (English). FluidAudio also ships a multilingual v3
// (25 European langs + Japanese) — switch `.v2` → `.v3` here if you want it.
actor ParakeetTranscriber: SpeechEngine {
    private var manager: AsrManager?
    private var isPreparing = false

    func prepare(modelName: String) async throws {
        if manager != nil { return }
        while isPreparing {
            try await Task.sleep(nanoseconds: 200_000_000) // 0.2 s
        }
        if manager != nil { return }
        isPreparing = true
        defer { isPreparing = false }
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let mgr = AsrManager(config: .default)
        try await mgr.loadModels(models)
        manager = mgr
    }

    func transcribe(samples: [Float], language: String) async throws -> String {
        guard let manager else { throw VoiceError.modelNotReady }
        // Fresh decoder state per one-shot dictation clip (2 LSTM layers = v2/v3).
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state)
        return result.text
    }
}
