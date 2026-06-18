import Foundation
import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import BarkCore

public enum PermissionKind: String, Sendable, CaseIterable {
    case microphone
    case accessibility    // synthesize key events / read focused element
    case inputMonitoring  // global CGEventTap hotkey
}

public enum PermissionState: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
}

/// Reads and requests the three TCC permissions Bark needs, and deep-links to
/// the right System Settings pane. Requests the minimum set, just-in-time
/// (least privilege — SEC-008 / T-011).
@MainActor
@Observable
public final class PermissionsCoordinator {
    public private(set) var microphone: PermissionState = .notDetermined
    public private(set) var accessibility: PermissionState = .notDetermined
    public private(set) var inputMonitoring: PermissionState = .notDetermined

    public init() {
        refresh()
    }

    public var allGranted: Bool {
        microphone == .granted && accessibility == .granted && inputMonitoring == .granted
    }

    public func refresh() {
        microphone = Self.micState()
        accessibility = AXIsProcessTrusted() ? .granted : .denied
        inputMonitoring = CGPreflightListenEventAccess() ? .granted : .denied
    }

    #if DEBUG
    /// Test seam: force permission states without touching real TCC.
    public func overrideForTesting(microphone: PermissionState? = nil,
                                   accessibility: PermissionState? = nil,
                                   inputMonitoring: PermissionState? = nil) {
        if let microphone { self.microphone = microphone }
        if let accessibility { self.accessibility = accessibility }
        if let inputMonitoring { self.inputMonitoring = inputMonitoring }
    }
    #endif

    public func state(of kind: PermissionKind) -> PermissionState {
        switch kind {
        case .microphone: return microphone
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        }
    }

    // MARK: Requests

    public func requestMicrophone() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphone = .granted
        case .notDetermined:
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            microphone = ok ? .granted : .denied
        default:
            microphone = .denied
        }
    }

    /// Prompts for Accessibility (shows the system prompt with the deep link).
    public func requestAccessibility() {
        // Literal value of kAXTrustedCheckOptionPrompt (avoids the non-Sendable global).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        accessibility = AXIsProcessTrusted() ? .granted : .denied
    }

    /// Triggers the Input Monitoring prompt (needed before a global event tap works).
    public func requestInputMonitoring() {
        if CGPreflightListenEventAccess() {
            inputMonitoring = .granted
        } else {
            _ = CGRequestListenEventAccess()
            inputMonitoring = CGPreflightListenEventAccess() ? .granted : .denied
        }
    }

    // MARK: System Settings deep links

    public func openSettings(for kind: PermissionKind) {
        let anchor: String
        switch kind {
        case .microphone:     anchor = "Privacy_Microphone"
        case .accessibility:  anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func micState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
}
