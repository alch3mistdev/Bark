import os

/// Centralized loggers. Subsystem is the bundle id; categories map to subsystems.
/// Never log transcript or audio content (privacy — see security threat model T-008).
public enum BarkLog {
    public static let subsystem = "com.bark.app"
    public static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let stt = Logger(subsystem: subsystem, category: "stt")
    public static let inject = Logger(subsystem: subsystem, category: "inject")
    public static let cleanup = Logger(subsystem: subsystem, category: "cleanup")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
}
