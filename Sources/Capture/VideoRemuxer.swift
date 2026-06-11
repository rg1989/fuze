import AVFoundation

/// Container conversion for finished recordings. screencapture always writes
/// QuickTime (.mov); when the user prefers MP4 we remux with the passthrough
/// preset — same H.264/AAC streams, new container, no re-encode, fast.
enum VideoRemuxer {
    /// Calls back on the main queue with the resulting URL — the original
    /// file when no conversion is needed or the remux fails (never lose the
    /// recording over a container preference).
    static func remuxIfNeeded(_ url: URL, to format: String,
                              completion: @escaping (URL) -> Void) {
        guard format == "mp4", url.pathExtension.lowercased() != "mp4" else {
            completion(url)
            return
        }
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetPassthrough) else {
            completion(url)
            return
        }
        let out = url.deletingPathExtension().appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: out)
        export.outputURL = out
        export.outputFileType = .mp4
        export.exportAsynchronously {
            DispatchQueue.main.async {
                if export.status == .completed {
                    try? FileManager.default.removeItem(at: url)
                    completion(out)
                } else {
                    Log.capture.error("mp4 remux failed (\(String(describing: export.error), privacy: .public)); keeping .mov")
                    completion(url)
                }
            }
        }
    }
}
