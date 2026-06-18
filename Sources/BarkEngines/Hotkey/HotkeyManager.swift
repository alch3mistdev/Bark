import Foundation
import CoreGraphics
import BarkCore

public enum HotkeyTrigger: Sendable, Equatable {
    /// Push-to-talk: hold a modifier (default: the fn / Globe key).
    case modifierHold(CGEventFlags)
    /// Tap a key to toggle dictation on/off.
    case keyToggle(CGKeyCode)
}

public struct HotkeyConfig: Sendable, Equatable {
    public var trigger: HotkeyTrigger
    public init(trigger: HotkeyTrigger = .modifierHold(.maskSecondaryFn)) {
        self.trigger = trigger
    }
}

/// Owns a global `CGEventTap` on a dedicated runloop thread. Push-to-talk and
/// toggle hotkeys fire `onStart`/`onStop`. The callback does the minimum work
/// and always re-enables the tap if macOS disables it under load (ARCH-002).
public final class HotkeyManager: @unchecked Sendable {
    public var onStart: (@Sendable () -> Void)?
    public var onStop: (@Sendable () -> Void)?

    private var config: HotkeyConfig
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    private var holding = false   // push-to-talk currently held
    private var toggled = false   // toggle currently on
    private let stateLock = NSLock()  // guards config/holding/toggled across UI ↔ tap thread

    public init(config: HotkeyConfig = .init()) {
        self.config = config
    }

    /// Reconfigure the trigger live (e.g. user rebinds the hotkey in Settings).
    public func update(_ config: HotkeyConfig) {
        stateLock.lock(); defer { stateLock.unlock() }
        self.config = config
        holding = false
        toggled = false
    }

    public func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in
            self?.installAndRun()
        }
        t.name = "com.bark.hotkey"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    public func stop() {
        if let runLoop { CFRunLoopStop(runLoop) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        runLoop = nil
        thread = nil
        holding = false
        toggled = false
    }

    // MARK: - Tap thread

    private func installAndRun() {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        // .defaultTap (not listenOnly) so we can CONSUME a matched toggle key —
        // otherwise the toggle keypress would also reach the focused app (Codex).
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: selfPtr
        ) else {
            BarkLog.hotkey.error("CGEvent.tapCreate failed — Input Monitoring not granted?")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        self.runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }

    // Called on the tap thread. Keep it tiny. Returns true to CONSUME the event.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        // Recover if the system disabled our tap (slow callback / heavy load).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        stateLock.lock(); defer { stateLock.unlock() }
        switch config.trigger {
        case .modifierHold(let flag):
            guard type == .flagsChanged else { return false }
            let on = event.flags.contains(flag)
            if on && !holding {
                holding = true
                onStart?()
            } else if !on && holding {
                holding = false
                onStop?()
            }
            return false  // never consume modifier events (system-wide)

        case .keyToggle(let key):
            guard type == .keyDown || type == .keyUp else { return false }
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            guard code == key else { return false }
            if type == .keyUp { return true }  // swallow the matching key-up too
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return true }
            toggled.toggle()
            if toggled { onStart?() } else { onStop?() }
            return true  // consume so the hotkey never reaches the focused app
        }
    }
}

// MARK: - Persisted-setting bridge

public extension HotkeyConfig {
    init(_ setting: HotkeySetting) {
        switch setting.kind {
        case .modifierHold:
            self.init(trigger: .modifierHold(CGEventFlags(rawValue: setting.modifierFlags)))
        case .keyToggle:
            self.init(trigger: .keyToggle(CGKeyCode(setting.keyCode)))
        }
    }
}

public extension HotkeySetting {
    init(_ config: HotkeyConfig) {
        switch config.trigger {
        case .modifierHold(let flags):
            self.init(kind: .modifierHold, keyCode: 0, modifierFlags: flags.rawValue)
        case .keyToggle(let key):
            self.init(kind: .keyToggle, keyCode: UInt16(key), modifierFlags: 0)
        }
    }
}

/// C-compatible tap callback — must be a non-capturing function.
private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
        if manager.handle(type: type, event: event) {
            return nil   // consume the matched hotkey
        }
    }
    return Unmanaged.passUnretained(event) // pass everything else through unchanged
}
