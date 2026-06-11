import Foundation

/// What kind of capture a file is. Drives both the filename and the
/// post-capture behavior (editor vs trimmer, png-vs-file-url clipboard).
enum CaptureKind {
    case screenshot
    case recording
}

/// Timestamped capture filenames — the ONE place these strings are built.
/// Pure: Date and TimeZone are injected; never call Date() in here.
enum CaptureNames {
    static func fileName(kind: CaptureKind, date: Date, timeZone: TimeZone = .current,
                         fileExtension: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: date)
        switch kind {
        case .screenshot: return "Fuse Shot \(stamp).\(fileExtension ?? "png")"
        case .recording: return "Fuse Recording \(stamp).\(fileExtension ?? "mov")"
        }
    }
}
