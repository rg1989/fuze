import Foundation

/// The four ways out of the post-capture review window. Pure data — the
/// side effects (trash, clipboard, trim export) live in CaptureController.
enum ReviewAction: String, CaseIterable {
    case delete, deleteAndCopy, save, saveAndCopy

    /// Does the capture file stay in the user's captures folder?
    var keepsFile: Bool {
        switch self {
        case .save, .saveAndCopy: return true
        case .delete, .deleteAndCopy: return false
        }
    }

    /// Does the capture land on the system clipboard?
    var copiesToClipboard: Bool {
        switch self {
        case .deleteAndCopy, .saveAndCopy: return true
        case .delete, .save: return false
        }
    }

    var title: String {
        switch self {
        case .delete: return "Delete"
        case .deleteAndCopy: return "Delete & Copy"
        case .save: return "Save"
        case .saveAndCopy: return "Save & Copy"
        }
    }
}

/// The two review-window keys with single/double-press semantics.
enum ReviewKey {
    case escape, `return`
}

/// Pure key → action mapping. Single press = the common case WITH copy;
/// a quick double press is the quieter variant without touching the
/// clipboard. (Esc = delete & copy, Esc Esc = delete; Return = save & copy,
/// Return Return = save.)
enum ReviewKeyMap {
    static func action(for key: ReviewKey, isDouble: Bool) -> ReviewAction {
        switch (key, isDouble) {
        case (.return, false): return .saveAndCopy
        case (.return, true): return .save
        case (.escape, false): return .deleteAndCopy
        case (.escape, true): return .delete
        }
    }
}
