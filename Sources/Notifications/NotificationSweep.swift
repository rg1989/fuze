import Foundation

/// Matches localized AX action descriptions against "clear-ish" phrases.
/// Exact full-string compare, case- and diacritic-insensitive, after trimming
/// whitespace. English defaults; after a macOS update changes the strings,
/// re-dump with AXDump and extend these lists (+ one matcher test per phrase).
enum SweepMatch {
    /// Descriptions meaning "remove this entire app group in one shot".
    static let clearAllPhrases: [String] = ["clear all"]
    /// Descriptions meaning "dismiss this single banner/alert".
    static let closePhrases: [String] = ["close", "clear"]

    static func isClearAll(_ description: String?, extraPhrases: [String] = []) -> Bool {
        matches(description, against: clearAllPhrases + extraPhrases)
    }

    static func isClose(_ description: String?, extraPhrases: [String] = []) -> Bool {
        matches(description, against: closePhrases + extraPhrases)
    }

    private static func matches(_ description: String?, against phrases: [String]) -> Bool {
        guard let description else { return false }
        let normalized = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return phrases.contains { phrase in
            normalized.compare(phrase,
                               options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }
}

/// One performable clear action found during a sweep.
struct SweepPlanItem<Node: AXTreeNode> {
    let node: Node
    let actionName: String
    /// true → "Clear All" (whole app group); false → "Close"/"Clear" (one item).
    let isClearAll: Bool
}

/// Pure sweep algorithm over an abstract AX tree. No Accessibility calls
/// in this file — the live adapter is NotificationClearer.
enum NotificationSweep {
    static let defaultMaxDepth = 12

    /// Walks the tree breadth-first, visiting nodes at depth 0...maxDepth
    /// (root is depth 0), collecting every performable clear action.
    static func collect<Node: AXTreeNode>(root: Node, maxDepth: Int = defaultMaxDepth) -> [SweepPlanItem<Node>] {
        var items: [SweepPlanItem<Node>] = []
        var queue: [(node: Node, depth: Int)] = [(root, 0)]
        var index = 0
        while index < queue.count {
            let (node, depth) = queue[index]
            index += 1
            for action in node.nodeActions() {
                if SweepMatch.isClearAll(action.description) {
                    items.append(SweepPlanItem(node: node, actionName: action.name, isClearAll: true))
                } else if SweepMatch.isClose(action.description) {
                    items.append(SweepPlanItem(node: node, actionName: action.name, isClearAll: false))
                }
            }
            if depth < maxDepth {
                for child in node.childNodes {
                    queue.append((child, depth + 1))
                }
            }
        }
        return items
    }

    /// Strategy: if any "Clear All" items exist, perform ONLY those (they nuke
    /// whole app groups; firing Closes too races the reflowing UI). Otherwise
    /// perform all "Close" items. Returns the number that reported success.
    @discardableResult
    static func performSweep<Node: AXTreeNode>(root: Node, maxDepth: Int = defaultMaxDepth) -> Int {
        let items = collect(root: root, maxDepth: maxDepth)
        let clearAllItems = items.filter(\.isClearAll)
        let toPerform = clearAllItems.isEmpty ? items : clearAllItems
        var performed = 0
        for item in toPerform where item.node.performNodeAction(named: item.actionName) {
            performed += 1
        }
        return performed
    }
}
