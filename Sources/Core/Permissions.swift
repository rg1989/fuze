import ApplicationServices
import AVFoundation
import AppKit
import IOKit.hid

enum SettingsPane: CaseIterable {
    case accessibility
    case inputMonitoring
    case microphone
    case screenRecording

    var urlString: String {
        switch self {
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .microphone:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .screenRecording:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
    }
}

enum PermissionsService {
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func promptForInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Screen Recording (TCC kTCCServiceScreenCapture). Non-prompting check;
    /// promptForScreenRecording() triggers the one-shot system dialog.
    /// Both come from CoreGraphics (umbrella'd by ApplicationServices).
    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func promptForScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings(pane: SettingsPane) {
        guard let url = URL(string: pane.urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
