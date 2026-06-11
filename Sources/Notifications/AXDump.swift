import AppKit

/// Debug/recalibration tool for the notification-clearing feature.
/// Produces an indented text dump of an AX tree: role/subrole/identifier
/// plus every action as "name (localized description)".
enum AXDump {
    static func dumpTree(_ element: AXElement, maxDepth: Int = 12) -> String {
        var lines: [String] = []
        appendNode(element, depth: 0, maxDepth: maxDepth, into: &lines)
        return lines.joined(separator: "\n")
    }

    private static func appendNode(_ element: AXElement, depth: Int, maxDepth: Int,
                                   into lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        let role = element.role ?? "?"
        let subrole = element.subrole.map { "/\($0)" } ?? ""
        let identifier = element.identifier.map { " id=\($0)" } ?? ""
        var line = "\(indent)\(role)\(subrole)\(identifier)"
        let actionNames = element.actionNames()
        if !actionNames.isEmpty {
            let described = actionNames.map { name in
                "\(name) (\(element.actionDescription(name) ?? "-"))"
            }
            line += "  actions: [" + described.joined(separator: ", ") + "]"
        }
        lines.append(line)
        guard depth < maxDepth else { return }
        for child in element.children {
            appendNode(child, depth: depth + 1, maxDepth: maxDepth, into: &lines)
        }
    }

    /// Dumps the Notification Center AX tree to ~/Desktop/fuse-nc-dump.txt.
    /// Returns the file path, or nil when the NC process is not running or
    /// the file cannot be written. Call off the main thread.
    static func dumpNotificationCenter() -> String? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == NotificationClearer.notificationCenterBundleID
        }) else {
            Log.notifications.error("AXDump: Notification Center process not found")
            return nil
        }
        let root = AXElement.application(pid: app.processIdentifier)
        var text = "Fuse Notification Center AX dump — \(Date())\n"
        text += "pid \(app.processIdentifier), bundle \(NotificationClearer.notificationCenterBundleID)\n"
        text += "\nAPPLICATION ELEMENT (depth 1)\n"
        text += dumpTree(root, maxDepth: 1)
        for (index, window) in root.windows.enumerated() {
            text += "\n\nWINDOW \(index)\n"
            text += dumpTree(window, maxDepth: 12)
        }
        if root.windows.isEmpty {
            text += "\n\n(no windows — post a test notification first, then re-dump)\n"
        }
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/fuse-nc-dump.txt")
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            Log.notifications.error("AXDump: writing dump failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        Log.notifications.info("AXDump: wrote \(path, privacy: .public)")
        return path
    }
}
