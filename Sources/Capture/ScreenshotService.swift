import AppKit

/// Drives the system's interactive screenshot engine:
/// `screencapture -i -o <tmp>.png`. The child process inherits Fuse's TCC
/// identity, so the Screen Recording permission prompt (first use) and the
/// grant are attributed to Fuse.
final class ScreenshotService {
    private var process: Process?

    var isRunning: Bool { process != nil }

    /// Calls back on the main queue with the temp PNG, or nil when the user
    /// cancelled with Esc (screencapture exits without writing the file).
    func captureInteractive(completion: @escaping (URL?) -> Void) {
        guard process == nil else { return }   // one interactive session at a time
        let format = UserDefaults.standard.string(forKey: "capture.imageFormat") ?? "png"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuse-shot-\(UUID().uuidString).\(format)")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-i", "-o", "-t", format, tmp.path]
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.process = nil
                let size = (try? FileManager.default
                    .attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.intValue ?? 0
                completion(size > 0 ? tmp : nil)   // missing/empty = Esc
            }
        }
        do {
            try proc.run()
            process = proc
        } catch {
            Log.capture.error("screencapture -i failed to launch: \(error.localizedDescription, privacy: .public)")
            completion(nil)
        }
    }
}
