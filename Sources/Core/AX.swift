import ApplicationServices

/// Thin Swift wrapper over AXUIElement. Every accessor degrades to nil/[]/false
/// when permission is missing or the attribute doesn't exist — callers never crash.
struct AXElement {
    let raw: AXUIElement

    static func systemWide() -> AXElement {
        AXElement(raw: AXUIElementCreateSystemWide())
    }

    static func application(pid: pid_t) -> AXElement {
        AXElement(raw: AXUIElementCreateApplication(pid))
    }

    func copyValue(_ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(raw, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value
    }

    private func elementArray(_ attribute: String) -> [AXElement] {
        guard let value = copyValue(attribute),
              CFGetTypeID(value) == CFArrayGetTypeID(),
              let array = value as? [AnyObject] else { return [] }
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return AXElement(raw: item as! AXUIElement)
        }
    }

    var role: String? { copyValue(kAXRoleAttribute) as? String }
    var subrole: String? { copyValue(kAXSubroleAttribute) as? String }
    var title: String? { copyValue(kAXTitleAttribute) as? String }
    var identifier: String? { copyValue("AXIdentifier") as? String }
    var children: [AXElement] { elementArray(kAXChildrenAttribute) }
    var windows: [AXElement] { elementArray(kAXWindowsAttribute) }

    var focusedWindow: AXElement? {
        guard let value = copyValue(kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(raw: value as! AXUIElement)
    }

    var position: CGPoint? {
        guard let value = copyValue(kAXPositionAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    var size: CGSize? {
        guard let value = copyValue(kAXSizeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return size
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(raw, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    func setSize(_ size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(raw, kAXSizeAttribute as CFString, value) == .success
    }

    func actionNames() -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(raw, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    func actionDescription(_ action: String) -> String? {
        var description: CFString?
        guard AXUIElementCopyActionDescription(raw, action as CFString, &description) == .success else { return nil }
        return description as String?
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(raw, action as CFString) == .success
    }
}
