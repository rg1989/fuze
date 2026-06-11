import Foundation

/// Abstraction over an accessibility-tree node so the sweep algorithm can be
/// unit-tested against in-memory mock trees, with no live Accessibility API.
protocol AXTreeNode {
    var childNodes: [Self] { get }
    var nodeRole: String? { get }
    var nodeSubrole: String? { get }
    /// (actionName, localizedDescription) pairs, e.g. ("Name:close", "Close").
    /// Action NAMES are opaque, version-dependent identifiers; the localized
    /// DESCRIPTIONS ("Clear All", "Close") are what we match against.
    func nodeActions() -> [(name: String, description: String?)]
    @discardableResult
    func performNodeAction(named name: String) -> Bool
}

/// Live conformance: AXElement is the Phase 1 wrapper over AXUIElement
/// (Sources/Core/AX.swift). All accessors degrade to nil/[]/false without
/// Accessibility permission, so this never crashes.
extension AXElement: AXTreeNode {
    var childNodes: [AXElement] { children }
    var nodeRole: String? { role }
    var nodeSubrole: String? { subrole }

    func nodeActions() -> [(name: String, description: String?)] {
        actionNames().map { ($0, actionDescription($0)) }
    }

    func performNodeAction(named name: String) -> Bool {
        perform(name)
    }
}
