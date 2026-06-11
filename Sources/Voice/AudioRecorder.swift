import AVFoundation

enum VoiceError: Error {
    case noInputDevice
    case converterSetupFailed
    case modelNotReady
}

/// Captures microphone audio via AVAudioEngine, converting on the fly to
/// 16 kHz mono Float32. The tap callback runs on an audio thread; all
/// sample-buffer access is funneled through `samplesQueue`.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let samplesQueue = DispatchQueue(label: "com.rgv250cc.fuse.voice.samples")

    func start() throws {
        samplesQueue.sync { samples.removeAll() }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw VoiceError.noInputDevice }
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16000,
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw VoiceError.converterSetupFailed
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let ratio = 16000.0 / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var fed = false
            var convError: NSError?
            converter.convert(to: out, error: &convError) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard convError == nil, let channel = out.floatChannelData else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
            self.samplesQueue.async { self.samples.append(contentsOf: chunk) }
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops the engine and returns all captured 16 kHz mono samples.
    /// Safe to call even if start() failed or was never called.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        return samplesQueue.sync { samples }
    }
}
