import Foundation
import HookWire

/// One hook line, read on the socket's queue into the fields the app uses.
struct HookEvent: @unchecked Sendable {
    var event: String
    var appSession: String?
    var claudePID: pid_t
    var claudeSessionID: String?
    var cwd: String?
    var transcriptPath: String?
    var permissionMode: String?
    var tool: String?
    var toolInput: [String: Any] = [:]
    var prompt: String?
    var lastReply: String?
    var source: String?
    var reason: String?
    var notificationType: String?
    var stopHookActive = false
    var isAgent = false
    /// A held PermissionRequest's card; nil for every other line, or when its input cannot be read.
    var ask: AskRequest?
    var connection: HookServer.ConnectionID?

    init(event: String, appSession: String?, claudePID: pid_t, input: [String: Any], hasInexactNumber: Bool = false, connection: HookServer.ConnectionID? = nil) {
        self.event = event
        self.appSession = appSession
        self.claudePID = claudePID
        self.connection = connection
        claudeSessionID = BridgeValue.string(input["session_id"])
        cwd = BridgeValue.string(input["cwd"])
        transcriptPath = BridgeValue.string(input["transcript_path"])
        permissionMode = BridgeValue.string(input["permission_mode"])
        tool = BridgeValue.string(input["tool_name"])
        toolInput = input["tool_input"] as? [String: Any] ?? [:]
        prompt = BridgeValue.string(input["prompt"])
        lastReply = BridgeValue.string(input["last_assistant_message"])
        source = BridgeValue.string(input["source"])
        reason = BridgeValue.string(input["reason"])
        notificationType = BridgeValue.string(input["notification_type"])
        stopHookActive = BridgeValue.bool(input["stop_hook_active"]) ?? false
        isAgent = HookLine.isFromSubagent(input)
        if event == HookLine.permissionRequest {
            ask = AskRequest.parse(input, isInputExact: !hasInexactNumber)
        }
    }

    init(_ received: ReceivedHook) {
        let message = received.message
        self.init(
            event: message.event, appSession: message.appSession, claudePID: message.claudePID, input: message.input,
            hasInexactNumber: message.hasInexactNumber, connection: received.connection
        )
    }
}

/// Which app session a hook belongs to: TERMINAL_MANAGER_SESSION first (the helper forwards it), then
/// Claude's session id, then the claude pid, then the folder when exactly one Claude session runs there.
enum HookRouter {
    struct Candidate: Equatable {
        var id: String
        var claudeSessionID: String?
        var claudePID: pid_t?
        var dir: String
    }

    static func route(appSession: String?, claudeSessionID: String?, claudePID: pid_t, cwd: String?, candidates: [Candidate]) -> String? {
        if let appSession, candidates.contains(where: { $0.id == appSession }) { return appSession }
        if let claudeSessionID, let match = candidates.first(where: { $0.claudeSessionID == claudeSessionID }) { return match.id }
        if claudePID > 1, let match = candidates.first(where: { $0.claudePID == claudePID }) { return match.id }
        if let cwd {
            let inFolder = candidates.filter { $0.dir == cwd }
            if inFolder.count == 1 { return inFolder[0].id }
        }
        return nil
    }
}

/// A request the helper waits on until the app answers it or releases it (closes without a word, which
/// leaves the terminal's own dialog in charge).
struct HeldAsk {
    static let lifetime: TimeInterval = 580

    let id: String
    let sessionID: String
    let connection: HookServer.ConnectionID
    let ask: AskRequest
    let createdAt: Date
    var feedSeq: Int?
}

/// The hook socket on the main actor: lines go to `onEvent` (already routed by the caller), held requests
/// wait here until answered, released or dropped. Nothing a client sends is ever taken as an answer.
@MainActor
final class HookCenter {
    let socketPath: String
    var onEvent: ((HookEvent) -> Void)?
    /// A held request went away without an answer from the app: answered in the terminal, released or expired.
    var onHeldGone: ((HeldAsk, _ reason: String) -> Void)?
    private(set) var held: [HeldAsk] = []
    private var server: HookServer?
    private var timer: Timer?

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() throws {
        guard server == nil else { return }
        let server = HookServer(
            socketPath: socketPath,
            onMessage: { [weak self] received in
                guard received.isFromClaude else {
                    Log.warn("hooks: ignored a \(received.message.event) line whose sender is not a child of pid \(received.message.claudePID)")
                    return
                }
                let event = HookEvent(received)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onEvent?(event) } }
            },
            onDropped: { [weak self] connection in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.dropped(connection) } }
            }
        )
        try server.start()
        self.server = server
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.expire() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        server?.stop()
        server = nil
        held = []
    }

    func hold(_ ask: AskRequest, connection: HookServer.ConnectionID, sessionID: String) -> HeldAsk {
        let item = HeldAsk(id: UUID().uuidString, sessionID: sessionID, connection: connection, ask: ask, createdAt: Date(), feedSeq: nil)
        held.append(item)
        Log.info("hooks: holding \(ask.tool) for session \(sessionID)")
        return item
    }

    func setFeedSeq(_ seq: Int, for id: String) {
        if let index = held.firstIndex(where: { $0.id == id }) { held[index].feedSeq = seq }
    }

    /// The oldest held request of a session: the first one Claude Code asked.
    func oldest(for sessionID: String) -> HeldAsk? {
        held.first { $0.sessionID == sessionID }
    }

    func hasHeld(_ sessionID: String) -> Bool {
        held.contains { $0.sessionID == sessionID }
    }

    /// Closes a connection that will not be held (no session to show it on, unreadable input).
    func pass(_ connection: HookServer.ConnectionID) {
        server?.release(connection)
    }

    /// Writes the answer through the waiting helper. `completion` hears whether the helper still had it.
    func answer(_ id: String, output: [String: Any], completion: @escaping @MainActor (Bool) -> Void) {
        guard let index = held.firstIndex(where: { $0.id == id }), let server, let line = HookLine.replyLine(output: output) else {
            completion(false)
            return
        }
        let item = held.remove(at: index)
        server.reply(item.connection, with: line) { isDelivered in
            MainActor.assumeIsolated {
                Log.info("hooks: \(item.ask.tool) for session \(item.sessionID) \(isDelivered ? "answered from the app" : "was already answered in the terminal")")
                completion(isDelivered)
            }
        }
    }

    /// Every held request of a session goes back to its terminal (the turn moved on without them).
    func release(sessionID: String, because reason: String) {
        for item in held where item.sessionID == sessionID { release(item, because: reason) }
    }

    /// A finished tool means its prompt was answered in the terminal: the matching held request goes.
    func toolFinished(sessionID: String, tool: String, input: [String: Any]) {
        guard let item = held.first(where: { item in
            item.sessionID == sessionID && item.ask.tool == tool
                && (item.ask.kind == .question
                    ? JSONEquality.isEqual(item.ask.toolInput["questions"], input["questions"])
                    : JSONEquality.isEqual(item.ask.toolInput, input))
        }) else { return }
        release(item, because: "answered in the terminal")
    }

    private func release(_ item: HeldAsk, because reason: String) {
        held.removeAll { $0.id == item.id }
        server?.release(item.connection)
        Log.info("hooks: released \(item.ask.tool) for session \(item.sessionID): \(reason)")
        onHeldGone?(item, reason)
    }

    private func dropped(_ connection: HookServer.ConnectionID) {
        guard let item = held.first(where: { $0.connection == connection }) else { return }
        held.removeAll { $0.id == item.id }
        Log.info("hooks: \(item.ask.tool) for session \(item.sessionID) was answered in the terminal")
        onHeldGone?(item, "answered in the terminal")
    }

    private func expire() {
        let now = Date()
        for item in held where now.timeIntervalSince(item.createdAt) >= HeldAsk.lifetime {
            release(item, because: "it expired")
        }
    }
}
