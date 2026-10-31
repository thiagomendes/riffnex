import Foundation
import OSLog

public enum RXLog {
    public static let subsystem = "com.thiagomendes.riffnex"

    public struct Entry: Identifiable, Sendable {
        public let id = UUID()
        public let date: Date
        public let category: String
        public let level: String
        public let message: String
    }

    /// Reads this process's recent log entries for our subsystem. There is no Xcode console in the
    /// xtool workflow, so the app shows its own logs in Diagnostics.
    public static func recentEntries(lastSeconds: TimeInterval = 900, limit: Int = 300) throws -> [Entry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(timeIntervalSinceEnd: -lastSeconds)
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        let entries = try store.getEntries(at: position, matching: predicate)
        var result: [Entry] = []
        for case let entry as OSLogEntryLog in entries {
            let level = switch entry.level {
            case .debug: "debug"
            case .info: "info"
            case .notice: "notice"
            case .error: "error"
            case .fault: "fault"
            default: "—"
            }
            result.append(Entry(date: entry.date, category: entry.category, level: level, message: entry.composedMessage))
        }
        return Array(result.suffix(limit))
    }
}
