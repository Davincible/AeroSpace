import Foundation

/// Performance logger for AeroSpace operations
/// Logs to /tmp/aerospace_perf.log with support for slow operation warnings
public enum PerfLog {
    private static let logPath = "/tmp/aerospace_perf.log"

    /// Whether performance logging is enabled
    nonisolated(unsafe) public static var isEnabled = true

    /// Threshold in ms above which operations are considered slow
    public static let slowThresholds: [String: Double] = [
        "FOCUS": 5.0,
        "LAYOUT": 10.0,
        "SESSION": 16.0,  // Target 60fps = 16.67ms per frame
        "AX": 10.0,
        "CMD": 20.0,
        "MOVE": 5.0,
    ]

    /// Default threshold for unknown categories
    public static let defaultSlowThreshold: Double = 20.0

    /// Log a performance measurement
    public static func log(_ category: String, _ operation: String, _ elapsedMs: Double) {
        guard isEnabled else { return }

        let threshold = slowThresholds[category] ?? defaultSlowThreshold
        let isSlow = elapsedMs > threshold
        let marker = isSlow ? " [SLOW]" : ""

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let message = "[\(timestamp)] [\(category)] \(operation): \(String(format: "%.3f", elapsedMs))ms\(marker)\n"

        appendToLog(message)
    }

    /// Log a warning message
    public static func warn(_ category: String, _ message: String) {
        guard isEnabled else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] [\(category)] [WARN] \(message)\n"

        appendToLog(logMessage)
    }

    /// Log an info message (for tracking operation flow)
    public static func info(_ category: String, _ message: String) {
        guard isEnabled else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] [\(category)] \(message)\n"

        appendToLog(logMessage)
    }

    private static func appendToLog(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logPath) {
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }

    /// Measure and log an operation
    @discardableResult
    @inline(__always)
    public static func measure<T>(_ category: String, _ operation: String, _ block: () throws -> T) rethrows -> T {
        guard isEnabled else { return try block() }
        let start = CFAbsoluteTimeGetCurrent()
        let result = try block()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        log(category, operation, elapsed)
        return result
    }

    /// Measure and log an async operation
    @discardableResult
    @inline(__always)
    public static func measureAsync<T>(_ category: String, _ operation: String, _ block: () async throws -> T) async rethrows -> T {
        guard isEnabled else { return try await block() }
        let start = CFAbsoluteTimeGetCurrent()
        let result = try await block()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        log(category, operation, elapsed)
        return result
    }

    /// Measure with additional context info
    @discardableResult
    @inline(__always)
    public static func measure<T>(_ category: String, _ operation: String, context: String, _ block: () throws -> T) rethrows -> T {
        guard isEnabled else { return try block() }
        let start = CFAbsoluteTimeGetCurrent()
        let result = try block()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        log(category, "\(operation) [\(context)]", elapsed)
        return result
    }

    /// Measure async with additional context info
    @discardableResult
    @inline(__always)
    public static func measureAsync<T>(_ category: String, _ operation: String, context: String, _ block: () async throws -> T) async rethrows -> T {
        guard isEnabled else { return try await block() }
        let start = CFAbsoluteTimeGetCurrent()
        let result = try await block()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        log(category, "\(operation) [\(context)]", elapsed)
        return result
    }

    /// Clear the log file
    public static func clear() {
        try? FileManager.default.removeItem(atPath: logPath)
    }

    /// Get recent slow operations summary
    public static func getSlowOperationsSummary() -> String {
        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            return "No log file found"
        }

        let slowLines = content.components(separatedBy: "\n")
            .filter { $0.contains("[SLOW]") }
            .suffix(20)

        if slowLines.isEmpty {
            return "No slow operations recorded"
        }

        return slowLines.joined(separator: "\n")
    }
}

// MARK: - Operation Tracker for complex multi-step operations

public final class PerfTracker {
    private let category: String
    private let operation: String
    private let start: CFAbsoluteTime
    private var steps: [(name: String, elapsed: Double)] = []
    private var lastStepTime: CFAbsoluteTime

    public init(_ category: String, _ operation: String) {
        self.category = category
        self.operation = operation
        self.start = CFAbsoluteTimeGetCurrent()
        self.lastStepTime = start
    }

    /// Mark a step in the operation
    public func step(_ name: String) {
        let now = CFAbsoluteTimeGetCurrent()
        let stepElapsed = (now - lastStepTime) * 1000
        steps.append((name, stepElapsed))
        lastStepTime = now
    }

    /// Finish tracking and log results
    public func finish() {
        let totalElapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        if steps.isEmpty {
            PerfLog.log(category, operation, totalElapsed)
        } else {
            let stepsStr = steps.map { "\($0.name)=\(String(format: "%.1f", $0.elapsed))ms" }.joined(separator: ", ")
            PerfLog.log(category, "\(operation) {\(stepsStr)}", totalElapsed)
        }
    }

    deinit {
        // Auto-finish if not explicitly called
        if steps.isEmpty {
            finish()
        }
    }
}
