import AVFoundation
import os

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

/// Live variant of AudioRecorder: forwards each converted 16 kHz mono chunk to
/// a callback as it arrives (the push-to-talk AudioRecorder only accumulates).
/// Used by the meeting recorder's audio hub. Reinstalls its tap on an audio
/// device/format change so switching the input mid-meeting doesn't silently kill
/// the mic. The push-to-talk AudioRecorder above is left untouched.
final class AudioRecorderLiveTap {
    private let engine = AVAudioEngine()
    // The converter is read on the audio render thread and swapped by reinstall();
    // guard it with an unfair lock so a device switch can't tear a live read.
    private let converter = OSAllocatedUnfairLock<AVAudioConverter?>(initialState: nil)
    private var onFrame: (([Float]) -> Void)?
    private var configObserver: NSObjectProtocol?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                       channels: 1, interleaved: false)!

    func start(onFrame: @escaping ([Float]) -> Void) throws {
        self.onFrame = onFrame
        try installTap()
        // A device switch (or sample-rate change) invalidates the converter and
        // the tap format — rebuild both when the engine reconfigures. Delivered on
        // the main queue so reinstall() is serialized (never on an audio thread).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.reinstall()
        }
    }

    private func installTap() throws {
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0 else { throw VoiceError.noInputDevice }
        guard let conv = AVAudioConverter(from: inFmt, to: target) else {
            throw VoiceError.converterSetupFailed
        }
        converter.withLock { $0 = conv }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buffer, _ in
            guard let self, let conv = self.converter.withLock({ $0 }) else { return }
            let ratio = 16000.0 / inFmt.sampleRate
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            if let err {
                Log.voice.error("mic live-tap convert failed: \(err.localizedDescription, privacy: .public)")
                return
            }
            guard let ch = out.floatChannelData else { return }
            self.onFrame?(Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))))
        }
        engine.prepare()
        try engine.start()
    }

    private func reinstall() {   // always on the main queue
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do { try installTap() }
        catch { Log.voice.error("mic live-tap reinstall failed: \(String(describing: error))") }
    }

    @discardableResult func stop() -> Bool {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        converter.withLock { $0 = nil }; onFrame = nil
        return true
    }
}

/// Fast pre-check before handing audio to Whisper. Only rejects takes where
/// the loudest moment is still near the noise floor — real speech always
/// clears these bars on a Mac mic.
enum AudioSilence {
    /// 100 ms windows at 16 kHz.
    static let windowSize = 1600
    /// Peak sample amplitude across the whole take.
    static let peakThreshold: Float = 0.025
    /// Loudest window RMS — speech bursts far exceed this.
    static let maxWindowRMSThreshold: Float = 0.012

    static func isEffectivelySilent(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }

        var peak: Float = 0
        var maxWindowRMS: Float = 0
        var index = 0
        while index < samples.count {
            let count = min(windowSize, samples.count - index)
            var sumSquares: Float = 0
            for i in index..<(index + count) {
                let sample = samples[i]
                peak = max(peak, abs(sample))
                sumSquares += sample * sample
            }
            maxWindowRMS = max(maxWindowRMS, sqrt(sumSquares / Float(count)))
            index += windowSize
        }

        return peak < peakThreshold && maxWindowRMS < maxWindowRMSThreshold
    }
}
