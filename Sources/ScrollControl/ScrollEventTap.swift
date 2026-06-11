import AppKit

/// C-compatible tap callback (CGEventTapCallBack). Must not capture context, hence
/// a top-level function; `userInfo` points (unretained) at the owning controller.
private func scrollTapCallback(proxy: CGEventTapProxy,
                               type: CGEventType,
                               event: CGEvent,
                               userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<ScrollEventTapController>.fromOpaque(userInfo).takeUnretainedValue()
    return controller.handle(type: type, event: event)
}

/// Owns a session-wide modifying CGEventTap on scroll-wheel events and
/// rewrites their delta fields according to the user's scroll settings.
/// Lifetime: constructed and retained by AppDelegate; the tap holds only an
/// UNRETAINED pointer to this object — never create a temporary instance.
/// Threading: the run-loop source lives on the MAIN run loop, so
/// `handle(type:event:)` always runs on the main thread; `cachedSettings` is
/// also only written on the main queue — no locking needed.
final class ScrollEventTapController {
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionRetryTimer: Timer?
    private var settingsObserver: NSObjectProtocol?

    /// Snapshot read on the event-tap hot path. NEVER read UserDefaults inside
    /// the callback — the didChangeNotification observer refreshes this instead.
    private var cachedSettings = ScrollSettings.current()

    // MARK: - Public lifecycle

    func start() {
        ScrollSettings.registerDefaults()
        cachedSettings = ScrollSettings.current()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.settingsDidChange()
        }

        if cachedSettings.enabled {
            installTapWhenPermitted()
        }
    }

    func stop() {
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        removeTap()
    }

    // MARK: - Tap lifecycle

    private func installTapWhenPermitted() {
        guard machPort == nil else { return }
        guard PermissionsService.hasAccessibility else {
            Log.scroll.info("Accessibility not granted yet; retrying scroll tap every 5 s")
            schedulePermissionRetry()
            return
        }
        installTap()
    }

    private func installTap() {
        guard machPort == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            // Happens when permission was revoked between check and create, or
            // when this macOS build additionally wants Input Monitoring.
            Log.scroll.error("CGEvent.tapCreate returned nil; retrying every 5 s")
            schedulePermissionRetry()
            return
        }
        machPort = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        Log.scroll.info("Scroll event tap installed")
    }

    private func removeTap() {
        if let machPort {
            CGEvent.tapEnable(tap: machPort, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        machPort = nil
        Log.scroll.info("Scroll event tap removed")
    }

    private func schedulePermissionRetry() {
        guard permissionRetryTimer == nil else { return }
        permissionRetryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard PermissionsService.hasAccessibility else { return }
            self.permissionRetryTimer?.invalidate()
            self.permissionRetryTimer = nil
            if self.cachedSettings.enabled {
                self.installTap()
            }
        }
    }

    // MARK: - Settings changes (main queue)

    private func settingsDidChange() {
        let fresh = ScrollSettings.current()
        guard fresh != cachedSettings else { return }   // fires for ANY defaults change; bail cheaply
        cachedSettings = fresh
        if fresh.enabled {
            installTapWhenPermitted()
        } else {
            removeTap()
        }
    }

    // MARK: - Hot path

    /// Called for every scroll-wheel event in the login session.
    /// HOT PATH RULES: integer field reads, value-type math, integer field
    /// writes. No heap allocation, no logging, no UserDefaults access.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The OS disables taps it deems too slow. Re-enabling here is
        // MANDATORY or scroll reversal silently stops (master plan §10).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let machPort {
                CGEvent.tapEnable(tap: machPort, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .scrollWheel else {
            return Unmanaged.passUnretained(event)
        }

        // Trackpads and Magic Mice report continuous scrolls; classic wheels
        // do not. Momentum events (scrollWheelEventMomentumPhase != 0) are
        // also continuous and intentionally take the SAME path — special-
        // casing them causes direction snaps mid-glide.
        let source: ScrollSource =
            event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 ? .continuous : .lineBased

        let deltas = ScrollDeltas(
            deltaAxis1: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            deltaAxis2: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            pointDeltaAxis1: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            pointDeltaAxis2: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
            fixedPtDeltaAxis1: event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1),
            fixedPtDeltaAxis2: event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2))

        guard let t = ScrollTransformer.transform(deltas, source: source, settings: cachedSettings) else {
            return Unmanaged.passUnretained(event)
        }

        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: t.deltaAxis1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: t.deltaAxis2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: t.pointDeltaAxis1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: t.pointDeltaAxis2)
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: t.fixedPtDeltaAxis1)
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: t.fixedPtDeltaAxis2)
        return Unmanaged.passUnretained(event)
    }
}
