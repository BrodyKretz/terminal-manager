import Foundation

enum Log {
    static func info(_ message: String) { write("info", message) }
    static func warn(_ message: String) { write("warn", message) }
    static func error(_ message: String) { write("error", message) }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func write(_ level: String, _ message: String) {
        FileHandle.standardError.write(Data("\(formatter.string(from: Date())) [\(level)] \(message)\n".utf8))
    }
}
