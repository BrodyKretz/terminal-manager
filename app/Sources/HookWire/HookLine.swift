import Foundation

/// One hook call as the helper forwards it. `appSession` is TERMINAL_MANAGER_SESSION from the hook's
/// environment: the app session that started this Claude process. Immutable once made.
public struct HookMessage: @unchecked Sendable {
    public let event: String
    public let isInteractive: Bool
    public let claudePID: Int32
    public let appSession: String?
    public let input: [String: Any]
    public let isAmbiguous: Bool
    public let hasInexactNumber: Bool

    public init(event: String, isInteractive: Bool, claudePID: Int32, appSession: String?, input: [String: Any], isAmbiguous: Bool = false, hasInexactNumber: Bool = false) {
        self.event = event
        self.isInteractive = isInteractive
        self.claudePID = claudePID
        self.appSession = appSession
        self.input = input
        self.isAmbiguous = isAmbiguous
        self.hasInexactNumber = hasInexactNumber
    }
}

/// `terminal-manager-hook --socket PATH --server PATH EVENT`, as hooks.json runs it. The helper talks to a
/// listener only when the kernel says it runs the `--server` executable as the same user.
public struct HookArguments: Equatable {
    public var socketPath: String
    public var serverPath: String
    public var event: String

    public init(socketPath: String, serverPath: String, event: String) {
        self.socketPath = socketPath
        self.serverPath = serverPath
        self.event = event
    }

    public static func parse(_ arguments: [String]) -> HookArguments? {
        var socketPath: String?
        var serverPath: String?
        var event: String?
        var remaining = ArraySlice(arguments.dropFirst())
        while let argument = remaining.popFirst() {
            switch argument {
            case "--socket":
                guard socketPath == nil, let value = remaining.popFirst() else { return nil }
                socketPath = value
            case "--server":
                guard serverPath == nil, let value = remaining.popFirst() else { return nil }
                serverPath = value
            default:
                guard event == nil, HookLine.isEventName(argument) else { return nil }
                event = argument
            }
        }
        guard let socketPath, socketPath.hasPrefix("/"), let serverPath, serverPath.hasPrefix("/"), let event else { return nil }
        return HookArguments(socketPath: socketPath, serverPath: serverPath, event: event)
    }
}

/// The line protocol between the hook helper and the app: one JSON line from the helper, and for a held
/// PermissionRequest one line back, `{"output": {...}}`, which the helper prints as the hook's answer.
public enum HookLine {
    public static let version = 1
    public static let maxInputBytes = 4 << 20
    public static let maxLineBytes = maxInputBytes + (64 << 10)
    public static let maxInputDepth = JSONDepth.limit
    static let maxMessageDepth = maxInputDepth + 1
    static let maxReplyDepth = maxInputDepth + 4
    public static let connectTimeout: TimeInterval = 0.3
    public static let sendTimeout: TimeInterval = 2
    public static let closeTimeout: TimeInterval = 0.25
    /// Claude Code gives the PermissionRequest hook 600 s; the helper stops waiting a little before.
    public static let holdTimeout: TimeInterval = 590
    public static let permissionRequest = "PermissionRequest"
    public static let entrypointVariable = "CLAUDE_CODE_ENTRYPOINT"
    public static let interactiveEntrypoint = "cli"
    public static let sessionVariable = "TERMINAL_MANAGER_SESSION"
    public static let maxEventNameLength = 64
    public static let maxAppSessionLength = 64
    /// Large tool output is never forwarded; the app reads replies from the transcript.
    public static let strippedKeys: Set<String> = ["tool_response", "error", "session_crons"]
    public static let countedKeys: Set<String> = ["background_tasks"]
    /// Long free text (a pasted prompt, the last reply) is cut to this many characters.
    public static let maxTextLength = 4000
    public static let clippedKeys: Set<String> = ["prompt", "last_assistant_message"]

    /// Claude Code's own CLI entry point, run by a process that owns a tty: `claude -p` and the SDK say
    /// `sdk-cli` and must never be held.
    public static func isInteractive(entrypoint: String?, hasTTY: Bool) -> Bool {
        entrypoint == interactiveEntrypoint && hasTTY
    }

    /// A subagent's PermissionRequest runs before any dialog shows, so holding one would leave the terminal
    /// with nothing to answer.
    public static func isFromSubagent(_ input: [String: Any]) -> Bool {
        switch input["agent_id"] {
        case nil, is NSNull: return false
        case let text as String: return !text.isEmpty
        default: return true
        }
    }

    public static func holds(event: String, isInteractive: Bool, input: [String: Any]) -> Bool {
        event == permissionRequest && isInteractive && !isFromSubagent(input)
    }

    /// Never for input two parsers may read differently: what the card shows might not be what runs.
    public static func holds(_ message: HookMessage) -> Bool {
        !message.isAmbiguous && holds(event: message.event, isInteractive: message.isInteractive, input: message.input)
    }

    public static func isEventName(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= maxEventNameLength
            && text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }
    }

    /// An app session id as the app makes them: letters, digits and dashes, at most 64.
    public static func isAppSessionID(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= maxAppSessionLength
            && text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    public static func parseInput(_ data: Data) -> [String: Any]? {
        readInput(data)?.input
    }

    public static func readInput(_ data: Data, repairsLoneSurrogates: Bool = false) -> (input: [String: Any], scan: JSONScan)? {
        guard !data.isEmpty, data.count <= maxInputBytes else { return nil }
        let scan = JSONScan.scan(data, limit: maxInputDepth)
        guard scan.isWithinDepth else { return nil }
        var text = data
        if scan.hasLoneSurrogate {
            guard repairsLoneSurrogates else { return nil }
            text = JSONScan.replacingLoneSurrogates(in: data, at: scan.loneSurrogateOffsets)
        }
        guard let input = (try? JSONSerialization.jsonObject(with: text)) as? [String: Any] else { return nil }
        return (input, scan)
    }

    public static func isExpectedListener(peerUID: uid_t?, ownUID: uid_t, peerPath: String?, serverPath: String) -> Bool {
        guard let peerUID, peerUID == ownUID, let peerPath else { return false }
        return peerPath == serverPath
    }

    public static func strippedInput(_ input: [String: Any]) -> [String: Any] {
        var stripped = input.filter { !strippedKeys.contains($0.key) }
        for key in countedKeys where stripped[key] != nil {
            stripped[key] = (stripped[key] as? [Any]).map { entries in entries.compactMap { $0 is [String: Any] ? [String: Any]() : nil } }
        }
        for key in clippedKeys {
            if let text = stripped[key] as? String, text.count > maxTextLength {
                stripped[key] = String(text.prefix(maxTextLength)) + "…"
            }
        }
        return stripped
    }

    public static func messageLine(_ message: HookMessage) -> Data? {
        line([
            "v": version,
            "event": message.event,
            "interactive": message.isInteractive,
            "claudePid": Int(message.claudePID),
            "appSession": message.appSession ?? NSNull(),
            "ambiguous": message.isAmbiguous,
            "inexactNumbers": message.hasInexactNumber,
            "input": message.input,
        ])
    }

    public static func parseMessage(_ line: Data) -> HookMessage? {
        guard let object = parseObject(line, depthLimit: maxMessageDepth), integer(object["v"]) == version,
              let event = object["event"] as? String, isEventName(event),
              let isInteractive = boolean(object["interactive"]),
              let pid = integer(object["claudePid"]), pid >= 0, pid <= Int(Int32.max),
              let isAmbiguous = boolean(object["ambiguous"]), let hasInexactNumber = boolean(object["inexactNumbers"]),
              let input = object["input"] as? [String: Any] else { return nil }
        let appSession: String?
        switch object["appSession"] {
        case nil, is NSNull: appSession = nil
        case let text as String:
            guard isAppSessionID(text) else { return nil }
            appSession = text
        default: return nil
        }
        return HookMessage(
            event: event, isInteractive: isInteractive, claudePID: Int32(pid), appSession: appSession, input: input,
            isAmbiguous: isAmbiguous, hasInexactNumber: hasInexactNumber
        )
    }

    public static func replyLine(output: [String: Any]) -> Data? {
        line(["output": output])
    }

    public static func output(fromReply line: Data) -> [String: Any]? {
        parseObject(line, depthLimit: maxReplyDepth)?["output"] as? [String: Any]
    }

    public static func printable(_ output: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(output),
              var data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        data.append(0x0A)
        return data
    }

    private static func line(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              data.count < maxLineBytes else { return nil }
        data.append(0x0A)
        return data
    }

    private static func parseObject(_ line: Data, depthLimit: Int) -> [String: Any]? {
        var body = line
        if body.last == 0x0A { body.removeLast() }
        guard !body.isEmpty, body.count <= maxLineBytes else { return nil }
        return JSONDepth.parse(body, limit: depthLimit) as? [String: Any]
    }

    /// JSONSerialization turns booleans and numbers into NSNumber alike; these tell them apart.
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) <= 9_007_199_254_740_991 else { return nil }
        return Int(double)
    }
}
