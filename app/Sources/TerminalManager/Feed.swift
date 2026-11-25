import Foundation

/// One line of the activity feed, in the page's shape: `tool` (with `tool`, `args`), `say`, `think`,
/// `perm`, `ask` (with `answer` once answered), `done`, `cmd`, `exit` (with `code`), `you` (with `verb`)
/// and `life` (with `flag`).
struct FeedEvent: Codable, Equatable {
    var seq: Int
    var sid: String
    var sname: String
    var type: String
    var at: Int64
    var tool: String?
    var args: String?
    var text: String?
    var detail: String?
    var verb: String?
    var answer: String?
    var code: Int?
    var flag: String?

    var bridgeObject: [String: Any] {
        var object: [String: Any] = ["seq": seq, "sid": sid, "sname": sname, "type": type, "at": NSNumber(value: at)]
        if let tool { object["tool"] = tool }
        if let args { object["args"] = args }
        if let text { object["text"] = text }
        if let detail { object["detail"] = detail }
        if let verb { object["verb"] = verb }
        if let answer { object["answer"] = answer }
        if let code { object["code"] = code }
        if let flag { object["flag"] = flag }
        return object
    }
}

/// The feed's events, oldest first, at most `limit`. Thinking markers live only while their session works.
struct FeedLog: Codable, Equatable {
    static let limit = 900

    private(set) var events: [FeedEvent] = []
    private(set) var seq = 0

    @discardableResult
    mutating func append(sid: String, sname: String, type: String, at: Date = Date(), _ fill: (inout FeedEvent) -> Void = { _ in }) -> FeedEvent {
        seq += 1
        var event = FeedEvent(seq: seq, sid: sid, sname: sname, type: type, at: at.millis)
        fill(&event)
        events.append(event)
        if events.count > Self.limit { events.removeFirst(events.count - Self.limit) }
        return event
    }

    @discardableResult
    mutating func update(seq: Int, _ change: (inout FeedEvent) -> Void) -> FeedEvent? {
        guard let index = events.lastIndex(where: { $0.seq == seq }) else { return nil }
        change(&events[index])
        return events[index]
    }

    /// The session's thinking markers, removed; their seqs.
    mutating func removeThinking(sid: String) -> [Int] {
        let gone = events.filter { $0.sid == sid && $0.type == "think" }.map(\.seq)
        events.removeAll { $0.sid == sid && $0.type == "think" }
        return gone
    }

    mutating func rename(sid: String, to name: String) {
        for index in events.indices where events[index].sid == sid { events[index].sname = name }
    }

    func hasThinking(sid: String) -> Bool {
        events.contains { $0.sid == sid && $0.type == "think" }
    }

    static func load(from url: URL) -> FeedLog {
        guard let data = try? Data(contentsOf: url), var log = try? JSONDecoder().decode(FeedLog.self, from: data) else { return FeedLog() }
        log.events.removeAll { $0.type == "think" }
        return log
    }

    func save(to url: URL) throws {
        try AtomicFile.write(try JSONEncoder().encode(self), to: url.path)
    }
}

/// The verb and subject of a tool event as the feed shows them.
enum FeedText {
    static func toolArgs(tool: String, input: [String: Any], cwd: String?) -> String {
        ToolSubject.describe(tool: tool, input: input, cwd: cwd).map { ClaudeStatusReducer.clip($0, to: 200) } ?? ""
    }
}
