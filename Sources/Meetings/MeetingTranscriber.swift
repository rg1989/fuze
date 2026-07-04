import Foundation
import AVFoundation
import os
import FluidAudio

/// The meeting engine. Segments the audio into pause-delimited utterances
/// (`UtteranceBuffer`) and transcribes each with BATCH Parakeet
/// (`ParakeetTranscriber` — the same accurate path dictation uses), while a
/// streaming `SortformerDiarizer` runs continuously to say WHO spoke. Each
/// finished utterance becomes one speaker-attributed message. Publishes a live
/// `activity` (listening → transcribing) so the UI can show the pipeline.
@MainActor
final class MeetingTranscriber: ObservableObject {
    @Published private(set) var lines: [SpeakerLine] = []       // finished messages, in order
    @Published private(set) var status: Status = .idle
    @Published private(set) var activity: Activity = .idle
    enum Status: Equatable { case idle, loading, running, finishing, saved, failed(String) }
    enum Activity: Equatable { case idle, listening, transcribing }

    func markFailed(_ message: String) { status = .failed(message) }

    private let asr = ParakeetTranscriber.shared                // batch Parakeet, shared with dictation
    private let diar = SortformerDiarizer(config: .fastV2_1)    // who's talking, streaming
    private let diarQueue = DispatchQueue(label: "com.rgv250cc.fuse.meeting.diar")
    private let buffer = UtteranceBuffer(pauseSeconds: 1.0, maxSeconds: 12)

    private var diarSegments: [AlignSpeakerSegment] = []        // finalized, accumulated
    private var tentativeSegs: [AlignSpeakerSegment] = []

    // Ordered per-utterance transcription: the buffer yields utterances here and
    // one pump transcribes them in order (no overlap, messages stay in sequence).
    private struct Utterance { let samples: [Float]; let start: Double; let end: Double }
    private let uttStream: AsyncStream<Utterance>
    private nonisolated let uttCont: AsyncStream<Utterance>.Continuation
    private var pump: Task<Void, Never>?

    private let stopping = OSAllocatedUnfairLock(initialState: false)

    /// Parakeet's minimum input (0.3s at 16 kHz); shorter clips are zero-padded.
    private static let minSamples = 4800

    init() {
        (uttStream, uttCont) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        buffer.onUtterance = { [weak self] samples, start, end in
            self?.uttCont.yield(Utterance(samples: samples, start: start, end: end))
        }
        buffer.onStatus = { [weak self] speaking, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.updateListening(speaking: speaking) }
            }
        }
    }

    // MARK: Load
    func load() async throws {
        status = .loading
        try await asr.prepare(modelName: "")                    // Parakeet v2 batch models (shared)
        let diarModels = try await SortformerModels.loadFromHuggingFace(
            config: .fastV2_1, computeUnits: .all)
        diar.initialize(models: diarModels)
    }

    // MARK: Start
    func start() async throws {
        status = .running
        activity = .listening
        pump = Task { [weak self, uttStream] in
            for await u in uttStream {
                if Task.isCancelled { break }
                guard let self else { break }
                await self.transcribe(u)
            }
        }
    }

    // MARK: Feed audio (off the main thread)
    nonisolated func feed(_ frame: [Float]) {
        guard !frame.isEmpty, !stopping.withLock({ $0 }) else { return }
        buffer.feed(frame)                                      // → utterances (pause-delimited)
        // Diarize continuously. No stopping-guard inside: a frame accepted here
        // must reach the diarizer so finalizeSession() at stop covers the tail.
        diarQueue.async { [weak self] in
            guard let self else { return }
            if let update = try? self.diar.process(samples: frame, sourceSampleRate: nil) {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.ingestDiar(update) } }
            }
        }
    }

    private func updateListening(speaking: Bool) {
        guard status == .running, activity != .transcribing else { return }
        activity = .listening
    }

    private func ingestDiar(_ update: DiarizerTimelineUpdate) {
        func map(_ s: DiarizerSegment) -> AlignSpeakerSegment {
            AlignSpeakerSegment(speakerIndex: s.speakerIndex,
                                start: Double(s.startTime), end: Double(s.endTime),
                                isFinalized: s.isFinalized)
        }
        diarSegments.append(contentsOf: update.finalizedSegments.map(map))
        tentativeSegs = update.tentativeSegments.map(map)
    }

    /// Batch-transcribe one utterance, then split it across speaker turns (so a
    /// back-to-back Speaker 1 → Speaker 2 exchange with no pause still becomes two
    /// bubbles), and append the resulting messages in order.
    private func transcribe(_ u: Utterance) async {
        activity = .transcribing
        // Zero-pad clips below Parakeet's 0.3s floor so a short final word isn't
        // rejected by the model's minimum-length guard.
        let clip = u.samples.count < Self.minSamples
            ? u.samples + [Float](repeating: 0, count: Self.minSamples - u.samples.count)
            : u.samples
        let clipTokens = (try? await asr.transcribeTokens(samples: clip)) ?? []
        // Clip-local timings → absolute audio-clock time (aligns with diarizer segs).
        let tokens = clipTokens.map {
            AlignToken(text: $0.text, start: u.start + $0.start, end: u.start + $0.end)
        }
        let segs = diarSegments + tentativeSegs
        for var line in SpeakerAttribution.split(tokens: tokens, segments: segs) {
            line.text = TranscriptPostProcessor.restoreQuestions(line.text)
            if !line.text.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
        }
        // Stay on "Transcribing…" through finish()'s drain; only relax while live.
        activity = (status == .running) ? .listening : .transcribing
    }

    // MARK: Finish
    func finish() async -> [SpeakerLine] {
        status = .finishing
        activity = .transcribing
        stopping.withLock { $0 = true }         // stop accepting NEW frames (queued diar still runs)
        // Finalize the diarizer FIRST (serial queue → runs after all queued
        // process() calls) and ingest its tail, so the last utterance is
        // attributed from finalized speaker segments — not stale/absent ones.
        let tail: DiarizerTimelineUpdate? = await withCheckedContinuation { c in
            diarQueue.async { c.resume(returning: try? self.diar.finalizeSession()) }
        }
        if let tail { ingestDiar(tail) }
        buffer.flush()                          // close the in-progress utterance (yields it)
        uttCont.finish()                        // end the stream after buffered utterances
        await drainPump()                       // transcribe every remaining utterance, in order
        status = .saved
        activity = .idle
        return lines
    }

    /// Await the pump, but cap the wait so a wedged CoreML call can't hang Stop.
    private func drainPump() async {
        guard let pump else { return }
        let watchdog = Task { try? await Task.sleep(nanoseconds: 60_000_000_000); pump.cancel() }
        await pump.value
        watchdog.cancel()
        self.pump = nil
    }

    func teardown() async { /* the Parakeet model is shared; nothing to release here */ }
}
