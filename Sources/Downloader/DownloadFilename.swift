import AppKit
import Foundation

enum DownloadConflictChoice {
    case cancel
    case replace
    case saveCopy
}

enum DownloadConflictPrompt {
    /// Blocks on the main thread — call only from `@MainActor` download flow.
    static func ask(videoTitle: String, existingFilename: String) -> DownloadConflictChoice {
        let alert = NSAlert()
        alert.messageText = "Already downloaded"
        alert.informativeText = """
            “\(existingFilename)” is already in your download folder.

            \(videoTitle)
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Save as Copy")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .saveCopy
        default: return .cancel
        }
    }
}
