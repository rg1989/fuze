import ScreenCaptureKit
import AVFoundation

/// Captures SYSTEM audio via ScreenCaptureKit → 16 kHz mono Float32, the same
/// format AudioRecorder produces. Requires the Screen Recording TCC grant
/// (kTCCServiceScreenCapture) — reuse PermissionsService.hasScreenRecording.
/// Only SCStreamOutputType.audio is used (macOS 12.3+); the mic stays on
/// AVAudioEngine.
@available(macOS 12.3, *)
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var srcFormat: AVAudioFormat?                 // rebuild converter if this changes
    private var onSamples: (([Float]) -> Void)?          // live push to the hub
    /// Called if the stream stops unexpectedly mid-session (e.g. permission revoked).
    var onError: ((Error) -> Void)?
    private let outputQueue = DispatchQueue(label: "com.rgv250cc.fuse.meeting.sysaudio")
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16000, channels: 1, interleaved: false)!

    /// `onSamples` is called on outputQueue with each converted 16k mono chunk.
    func start(onSamples: @escaping ([Float]) -> Void) async throws {
        outputQueue.sync { self.onSamples = onSamples }
        // Fetching shareable content is what triggers the Screen Recording prompt.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw VoiceError.noInputDevice }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000            // advisory; we resample from the actual ASBD
        config.channelCount = 2
        if #available(macOS 13.0, *) { config.excludesCurrentProcessAudio = true }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.width = 2; config.height = 2   // video path is mandatory; keep it tiny, never read .screen

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async {
        let s = stream
        if let s { try? await s.stopCapture() }
        // Clear mutable state on outputQueue so it orders against any in-flight callback.
        outputQueue.sync { stream = nil; converter = nil; srcFormat = nil; onSamples = nil; onError = nil }
    }

    // MARK: SCStreamOutput — audio CMSampleBuffers arrive on outputQueue.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let fmtDesc = sampleBuffer.formatDescription,
              var asbd = fmtDesc.audioStreamBasicDescription,
              let src = AVAudioFormat(streamDescription: &asbd)
        else { return }

        // (Re)build the converter if the source format changed (device switch).
        if converter == nil || srcFormat?.isEqual(src) != true {
            converter = AVAudioConverter(from: src, to: targetFormat)
            srcFormat = src
        }
        guard let converter else { return }

        // Convert INSIDE the closure — never let the AudioBufferList pointer escape.
        try? sampleBuffer.withAudioBufferList { abl, _ in
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: src,
                                               bufferListNoCopy: abl.unsafePointer,
                                               deallocator: nil)
            else { return }
            let ratio = 16000.0 / src.sampleRate
            let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return inBuf
            }
            if let err {
                Log.voice.error("system-audio convert failed: \(err.localizedDescription, privacy: .public)")
                return
            }
            guard let ch = out.floatChannelData else { return }
            let chunk = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            self.onSamples?(chunk)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.voice.error("system-audio stream stopped: \(error.localizedDescription, privacy: .public)")
        onError?(error)
    }
}
