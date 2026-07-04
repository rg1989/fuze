import Foundation
import AVFoundation
import os
import FluidAudio

/// The streaming meeting engine. Owns a streaming Parakeet ASR
/// (`SlidingWindowAsrManager`, English v2) and a streaming speaker diarizer
/// (`SortformerDiarizer`, .fastV2_1). Both are fed the same 16 kHz mono frames
/// from `MeetingAudioHub` on one clock; their second-based timestamps are
/// aligned by the pure `SpeakerAligner` into `[SpeakerLine]`.
@MainActor
final class MeetingTranscriber: ObservableObject {
    @Published private(set) var lines: [SpeakerLine] = []
    @Published private(set) var status: Status = .idle
    enum Status: Equatable { case idle, loading, running, finishing, saved, failed(String) }

    func markFailed(_ message: String) { status = .failed(message) }

    private let asr = SlidingWindowAsrManager(config: .streaming)   // 1s hypothesis updates for live feedback
    private let diar = SortformerDiarizer(config: .fastV2_1)   // ~1.04 s latency, 4 slots
    private let diarQueue = DispatchQueue(label: "com.rgv250cc.fuse.meeting.diar")
    private let asrFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 16000, channels: 1, interleaved: false)!

    // Tokens keyed by start time in ms — a confirmed token overwrites the volatile
    // one at the same time; nothing is dropped when one update replaces another.
    private var tokensByStartMs: [Int: AlignToken] = [:]
    private var finalizedSegs: [AlignSpeakerSegment] = []
    private var tentativeSegs: [AlignSpeakerSegment] = []

    // Ordered ASR feed: feed() yields frames into asrFeedCont; a single pump
    // awaits streamAudio one buffer at a time, preserving capture order (no
    // per-frame Task). The continuation is a nonisolated Sendable let so the
    // audio thread can yield to it; the stream is consumed once by the pump.
    private let asrFeed: AsyncStream<[Float]>
    private nonisolated let asrFeedCont: AsyncStream<[Float]>.Continuation
    private var asrPump: Task<Void, Never>?
    private var consumer: Task<Void, Never>?

    // Set once teardown begins so late audio-thread callbacks drop their frames.
    private let stopping = OSAllocatedUnfairLock(initialState: false)

    init() {
        (asrFeed, asrFeedCont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: Load
    func load() async throws {
        status = .loading
        let models = try await AsrModels.downloadAndLoad(version: .v2)     // English-tuned 0.6B
        try await asr.loadModels(models)
        let diarModels = try await SortformerModels.loadFromHuggingFace(
            config: .fastV2_1, computeUnits: .all)
        diar.initialize(models: diarModels)
    }

    // MARK: Start streaming
    func start() async throws {
        let updates = await asr.transcriptionUpdates          // grab exactly once
        try await asr.startStreaming(source: .microphone)     // source is a label only
        status = .running

        let feedStream = asrFeed
        asrPump = Task { [weak self] in
            for await frame in feedStream {
                guard let self, let buf = self.makeBuffer(frame) else { continue }
                await self.asr.streamAudio(buf)               // ordered, one at a time
            }
        }
        consumer = Task { [weak self] in
            for await u in updates {
                await MainActor.run { self?.ingestASR(u) }
            }
        }
    }

    // MARK: Feed audio (called by MeetingAudioHub.onFrame, off the main thread)
    nonisolated func feed(_ frame: [Float]) {
        guard !frame.isEmpty, !stopping.withLock({ $0 }) else { return }
        asrFeedCont.yield(frame)                               // ordered ASR path
        diarQueue.async { [weak self] in                      // ordered diarizer path
            guard let self, !self.stopping.withLock({ $0 }) else { return }
            guard let update = try? self.diar.process(samples: frame, sourceSampleRate: nil) else { return }
            // main-queue FIFO preserves order relative to other diar updates.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.ingestDiar(update) } }
        }
    }

    nonisolated private func makeBuffer(_ frame: [Float]) -> AVAudioPCMBuffer? {
        guard let buf = AVAudioPCMBuffer(pcmFormat: asrFormat,
                                         frameCapacity: AVAudioFrameCount(frame.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(frame.count)
        frame.withUnsafeBufferPointer { src in
            buf.floatChannelData!.pointee.update(from: src.baseAddress!, count: frame.count)
        }
        return buf
    }

    // MARK: Ingest ASR update — merge tokens by start time (no loss, no dup)
    private func ingestASR(_ u: SlidingWindowTranscriptionUpdate) {
        for t in u.tokenTimings {
            let key = Int((t.startTime * 1000).rounded())
            tokensByStartMs[key] = AlignToken(text: t.token, start: t.startTime, end: t.endTime)
        }
        rebuildLines()
    }

    // MARK: Ingest diarizer update
    private func ingestDiar(_ update: DiarizerTimelineUpdate) {
        func map(_ s: DiarizerSegment) -> AlignSpeakerSegment {
            AlignSpeakerSegment(speakerIndex: s.speakerIndex,
                                start: Double(s.startTime), end: Double(s.endTime),
                                isFinalized: s.isFinalized)
        }
        finalizedSegs.append(contentsOf: update.finalizedSegments.map(map))
        tentativeSegs = update.tentativeSegments.map(map)      // replace tentative each tick
        rebuildLines()
    }

    private func rebuildLines() {
        let tokens = tokensByStartMs.values.sorted { $0.start < $1.start }
        let segs = (finalizedSegs + tentativeSegs).sorted { $0.start < $1.start }
        lines = SpeakerAligner.lines(tokens: tokens, segments: segs)
    }

    // MARK: Finish → the final saveable lines
    func finish() async -> [SpeakerLine] {
        status = .finishing
        stopping.withLock { $0 = true }        // drop any further audio-thread frames

        // 1. Close the ordered feed and let the pump flush every buffered frame
        //    into the ASR actor (in order) before we finish the stream.
        asrFeedCont.finish()
        await asrPump?.value; asrPump = nil

        // 2. Finish ASR — processes the remaining windows and yields the trailing
        //    updates into the (unbounded) updates buffer. Note: finish() does NOT
        //    terminate the transcriptionUpdates stream (only cancel()/cleanup() do,
        //    per SlidingWindowAsrManager 0.15.4). So we then cleanup() to finish
        //    the stream; the already-buffered trailing updates are still delivered
        //    to the consumer before its `for await` ends. This drains the tail
        //    without deadlocking on a stream that would otherwise never end.
        do { _ = try await asr.finish() }
        catch { Log.voice.error("meeting ASR finish failed: \(String(describing: error))") }
        await asr.cleanup()                     // cancel + finish the updates stream (idempotent)
        await consumer?.value                   // drain every buffered update, incl. the tail
        consumer = nil

        // 3. Drain queued diarizer work and finalize OFF the main thread, then
        //    ingest the tail back on the MainActor.
        let tail: DiarizerTimelineUpdate? = await withCheckedContinuation { c in
            diarQueue.async { c.resume(returning: try? self.diar.finalizeSession()) }
        }
        if let tail { ingestDiar(tail) }

        rebuildLines()
        status = .saved
        return lines
    }

    func teardown() async {
        stopping.withLock { $0 = true }
        await asr.cleanup()                     // releases models
    }
}
