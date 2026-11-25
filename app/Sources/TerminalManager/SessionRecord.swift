import Foundation

enum SessionKind: String, Codable {
    case claude
    case shell
}

/// The page's statuses. Claude sessions: idle, working, needs_you, ready, reviewed, exited. Terminals:
/// idle (at the prompt), process (a foreground command runs), exited.
enum SessionStatus: String, Codable {
    case idle
    case working
    case needsYou = "needs_you"
    case ready
    case reviewed
    case process
    case exited
}

/// One app session as sessions.json keeps it: what the user made, plus the last known Claude state so a
/// relaunch shows the same status and a gone process can be resumed with its conversation.
struct SessionRecord: Codable, Equatable {
    var id: String
    var kind: SessionKind
    var name: String
    var dir: String
    var created: Date
    var muted: Bool = false
    var pinned: Bool = false
    var mode: PermissionMode?
    /// Claude Code's own session id: set with `--session-id` at create, updated from hooks (a /clear starts a new one).
    var claudeSessionID: String?
    var transcriptPath: String?
    var status: SessionStatus = .idle
    var statusAt: Date = Date()
    var summary: String = ""
    var hasError: Bool = false
    var lastReply: String?
    var context: Int?
    var exitCode: Int?
    /// The Claude process has run at least one turn: an exited one is worth resuming.
    var hasConversation: Bool = false

    var tmuxName: String { "tm-\(id)" }

    static func newID() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(10))
    }
}

/// A deleted Claude session kept for Recently closed: enough to resume it.
struct ClosedSession: Codable, Equatable {
    var id: String
    var name: String
    var dir: String
    var mode: PermissionMode?
    var claudeSessionID: String
    var closedAt: Date
    var lastLine: String
}

/// sessions.json: the sessions in list order and the recently closed ones, newest first.
struct SessionsFile: Codable, Equatable {
    static let maxClosed = 20

    var version = 1
    var sessions: [SessionRecord] = []
    var closed: [ClosedSession] = []

    static func load(from url: URL) -> SessionsFile {
        guard let data = try? Data(contentsOf: url) else { return SessionsFile() }
        do {
            return try decoder.decode(SessionsFile.self, from: data)
        } catch {
            Log.error("sessions.json could not be read (\(error)); starting with no sessions and keeping the file as sessions.json.bad")
            try? FileManager.default.removeItem(at: url.appendingPathExtension("bad"))
            try? FileManager.default.copyItem(at: url, to: url.appendingPathExtension("bad"))
            return SessionsFile()
        }
    }

    func save(to url: URL) throws {
        try AtomicFile.write(try Self.encoder.encode(self), to: url.path)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFormatter.string(from: date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = isoFormatter.date(from: text) ?? plainFormatter.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date: \(text)"))
        }
        return decoder
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter = ISO8601DateFormatter()
}

extension SessionRecord {
    /// Fields added later decode with their defaults, so an older file still loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(SessionKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        dir = try container.decode(String.self, forKey: .dir)
        created = try container.decode(Date.self, forKey: .created)
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        mode = try container.decodeIfPresent(PermissionMode.self, forKey: .mode)
        claudeSessionID = try container.decodeIfPresent(String.self, forKey: .claudeSessionID)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        status = try container.decodeIfPresent(SessionStatus.self, forKey: .status) ?? .idle
        statusAt = try container.decodeIfPresent(Date.self, forKey: .statusAt) ?? created
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        hasError = try container.decodeIfPresent(Bool.self, forKey: .hasError) ?? false
        lastReply = try container.decodeIfPresent(String.self, forKey: .lastReply)
        context = try container.decodeIfPresent(Int.self, forKey: .context)
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        hasConversation = try container.decodeIfPresent(Bool.self, forKey: .hasConversation) ?? false
    }
}
