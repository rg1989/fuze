import AVFoundation

/// Trim export for finished recordings: passthrough preset (same streams,
/// no re-encode, fast — same approach as VideoRemuxer), output container
/// matched to the destination's extension.
enum VideoExporter {
    static func fileType(forPathExtension ext: String) -> AVFileType {
        ext.lowercased() == "mp4" ? .mp4 : .mov
    }

    /// Exports `range` of the movie at `source` to `destination`
    /// (overwriting it). Calls back on the main queue with success.
    static func exportTrimmed(source: URL, range: CMTimeRange, to destination: URL,
                              completion: @escaping (Bool) -> Void) {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            completion(false)
            return
        }
        try? FileManager.default.removeItem(at: destination)
        session.outputURL = destination
        session.outputFileType = fileType(forPathExtension: destination.pathExtension)
        session.timeRange = range
        session.exportAsynchronously {
            DispatchQueue.main.async {
                if session.status != .completed {
                    Log.capture.error("trim export failed: \(String(describing: session.error), privacy: .public)")
                }
                completion(session.status == .completed)
            }
        }
    }

    /// Trims the movie at `url` IN PLACE: exports the range to a hidden
    /// sibling temp file, then atomically replaces `url`. The export can't
    /// write onto the file it is reading, hence the two-step.
    static func trimInPlace(url: URL, range: CMTimeRange,
                            completion: @escaping (Bool) -> Void) {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".fuse-trim-\(UUID().uuidString).\(url.pathExtension)")
        exportTrimmed(source: url, range: range, to: tmp) { ok in
            guard ok else {
                completion(false)
                return
            }
            do {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
                completion(true)
            } catch {
                Log.capture.error("trim replace failed: \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: tmp)
                completion(false)
            }
        }
    }
}
