import Foundation
import os

/// In-app debug logger for TestFlight testing without Xcode console access.
/// Logs are stored in memory and persisted to disk so they can be viewed
/// directly on-device via the Debug Log screen in Settings.
final class DebugLogger: ObservableObject {
    static let shared = DebugLogger()

    enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"
    }

    struct LogEntry: Identifiable, Codable {
        let id: UUID
        let timestamp: Date
        let level: String
        let category: String
        let message: String

        var formattedTimestamp: String {
            Self.formatter.string(from: timestamp)
        }

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()
    }

    @Published private(set) var entries: [LogEntry] = []

    private let maxEntries = 500
    private let queue = DispatchQueue(label: "com.scanview3d.logger", qos: .utility)
    private let osLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ScanView3D", category: "App")

    private var logFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("debug_log.json")
    }

    private init() {
        loadFromDisk()
    }

    // MARK: - Public API

    func info(_ message: String, category: String = "General") {
        log(message, level: .info, category: category)
    }

    func warn(_ message: String, category: String = "General") {
        log(message, level: .warning, category: category)
    }

    func error(_ message: String, category: String = "General") {
        log(message, level: .error, category: category)
    }

    func debug(_ message: String, category: String = "General") {
        log(message, level: .debug, category: category)
    }

    func clear() {
        DispatchQueue.main.async {
            self.entries.removeAll()
        }
        queue.async {
            try? FileManager.default.removeItem(at: self.logFileURL)
        }
    }

    /// Export logs as a shareable text string.
    func exportText() -> String {
        let header = "ScanView 3D Debug Log\nExported: \(Date())\nEntries: \(entries.count)\n\n"
        let lines = entries.map { entry in
            "[\(entry.formattedTimestamp)] [\(entry.level)] [\(entry.category)] \(entry.message)"
        }
        return header + lines.joined(separator: "\n")
    }

    // MARK: - Private

    private func log(_ message: String, level: Level, category: String) {
        let entry = LogEntry(
            id: UUID(),
            timestamp: Date(),
            level: level.rawValue,
            category: category,
            message: message
        )

        // Also log to os_log for Console.app access over USB
        switch level {
        case .info:    osLog.info("[\(category)] \(message)")
        case .warning: osLog.warning("[\(category)] \(message)")
        case .error:   osLog.error("[\(category)] \(message)")
        case .debug:   osLog.debug("[\(category)] \(message)")
        }

        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }

        queue.async {
            self.saveToDisk()
        }
    }

    private func saveToDisk() {
        let snapshot = DispatchQueue.main.sync { entries }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: logFileURL, options: .atomic)
        } catch {
            osLog.error("Failed to save debug log: \(error.localizedDescription)")
        }
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: logFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: logFileURL)
            let loaded = try JSONDecoder().decode([LogEntry].self, from: data)
            entries = loaded.suffix(maxEntries).map { $0 }
        } catch {
            osLog.error("Failed to load debug log: \(error.localizedDescription)")
        }
    }
}
