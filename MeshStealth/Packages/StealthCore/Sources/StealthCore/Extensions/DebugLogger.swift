import Foundation

/// Debug logging utility that only outputs in DEBUG builds.
/// Keeps release builds clean while allowing comprehensive logging during development.
public enum DebugLogger {

    /// Log a debug message with optional category.
    /// - Parameters:
    ///   - message: The message to log
    ///   - category: Category tag for filtering (e.g., "MESH", "CRYPTO", "WALLET")
    public static func log(_ message: String, category: String = "DEBUG") {
        #if DEBUG
        print("[\(category)] \(message)")
        #endif
    }

    /// Log an error message.
    /// - Parameters:
    ///   - message: The error message
    ///   - error: Optional Error object
    ///   - category: Category tag
    public static func error(_ message: String, error: Error? = nil, category: String = "ERROR") {
        #if DEBUG
        if let error = error {
            print("[\(category)] \(message): \(error.localizedDescription)")
        } else {
            print("[\(category)] \(message)")
        }
        #endif
    }

    /// Log with a specific subsystem for os_log-style categorization.
    /// - Parameters:
    ///   - message: The message to log
    ///   - subsystem: Subsystem identifier (e.g., "BLE", "Stealth", "Settlement")
    ///   - type: Log type (info, debug, error, warning)
    public static func log(_ message: String, subsystem: String, type: LogType) {
        #if DEBUG
        let prefix: String
        switch type {
        case .info:
            prefix = "INFO"
        case .debug:
            prefix = "DEBUG"
        case .error:
            prefix = "ERROR"
        case .warning:
            prefix = "WARN"
        }
        print("[\(subsystem):\(prefix)] \(message)")
        #endif
    }

    public enum LogType {
        case info
        case debug
        case error
        case warning
    }
}
