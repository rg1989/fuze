import Foundation
import WhisperKit

/// Owns the WhisperKit pipeline. First prepare(modelName:) downloads the CoreML
/// model from Hugging Face (argmaxinc/whisperkit-coreml); cached on disk after.
actor Transcriber {
    private var whisperKit: WhisperKit?
    private(set) var loadedModelName: String?
    private var isPreparing = false

    /// Idempotent: no-op if the requested model is already loaded; reloads when
    /// the name changed. If another prepare is in flight (actor re-entrancy at
    /// await points), waits for it instead of downloading twice.
    func prepare(modelName: String) async throws {
        if whisperKit != nil, loadedModelName == modelName { return }
        while isPreparing {
            try await Task.sleep(nanoseconds: 200_000_000) // 0.2 s
        }
        // Re-check: the in-flight prepare we waited on may have loaded our model.
        if whisperKit != nil, loadedModelName == modelName { return }
        isPreparing = true
        defer { isPreparing = false }
        whisperKit = nil
        loadedModelName = nil
        let kit = try await WhisperKit(model: modelName)
        whisperKit = kit
        loadedModelName = modelName
    }

    /// Transcribes 16 kHz mono Float32 samples. `language` is a two-letter code
    /// ("en", "de", …); English-only models (*.en) ignore it.
    func transcribe(samples: [Float], language: String) async throws -> String {
        guard let kit = whisperKit else { throw VoiceError.modelNotReady }
        var options = DecodingOptions()
        options.language = language
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
    }
}
