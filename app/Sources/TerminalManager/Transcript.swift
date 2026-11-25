import Foundation
import HookWire

/// What new lines of a session's transcript JSONL hold for the feed: Claude's text replies of the main
/// conversation and the context the last reply used.
struct TranscriptUpdate: Equatable {
    var replies: [String] = []
    /// Tokens of context the last assistant message used: input plus both cache counts plus output.
    var contextTokens: Int?
    var model: String?
}

enum TranscriptParser {
    static let maxReply = 1200
    static let defaultWindow = 200_000
    static let largeWindow = 1_000_000

    static func update(fromLines data: Data) -> TranscriptUpdate {
        var update = TranscriptUpdate()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard line.range(of: Data("\"assistant\"".utf8)) != nil,
                  let object = JSONDepth.parse(Data(line)) as? [String: Any] else { continue }
            apply(object, to: &update)
        }
        return update
    }

    static func apply(_ object: [String: Any], to update: inout TranscriptUpdate) {
        guard BridgeValue.string(object["type"]) == "assistant", BridgeValue.bool(object["isSidechain"]) != true,
              let message = object["message"] as? [String: Any] else { return }
        if let usage = message["usage"] as? [String: Any] {
            let keys = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
            let total = keys.compactMap { BridgeValue.int(usage[$0]) }.reduce(0, +)
            if total > 0 { update.contextTokens = total }
        }
        if let model = BridgeValue.string(message["model"]) { update.model = model }
        guard BridgeValue.bool(object["isApiErrorMessage"]) != true else { return }
        var texts: [String] = []
        switch message["content"] {
        case let text as String:
            texts = [text]
        case let blocks as [Any]:
            texts = blocks.compactMap { raw in
                guard let block = raw as? [String: Any], BridgeValue.string(block["type"]) == "text" else { return nil }
                return BridgeValue.string(block["text"])
            }
        default:
            break
        }
        let text = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        update.replies.append(text.count > maxReply ? String(text.prefix(maxReply - 1)) + "…" : text)
    }

    /// The context meter's percent: a 1M window when the model says so or the tokens already passed 200k.
    static func contextPercent(tokens: Int, model: String?) -> Int {
        let window = (model?.contains("[1m]") == true || tokens > defaultWindow) ? largeWindow : defaultWindow
        return min(100, max(0, Int((Double(tokens) / Double(window) * 100).rounded())))
    }
}

/// Follows one transcript file from an offset: only complete lines are read, a partial last line waits
/// for the next look, and a file that shrank (replaced) starts over from its end.
struct TranscriptFollower {
    static let maxRead = 4 << 20

    var path: String
    var offset: UInt64

    /// A follower that starts at the file's current end: what was there before is not news.
    static func atEnd(of path: String) -> TranscriptFollower {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
        return TranscriptFollower(path: path, offset: size)
    }

    mutating func readNew() -> TranscriptUpdate {
        guard let handle = FileHandle(forReadingAtPath: path) else { return TranscriptUpdate() }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return TranscriptUpdate() }
        if size < offset { offset = size }
        guard size > offset else { return TranscriptUpdate() }
        let start = size - offset > UInt64(Self.maxRead) ? size - UInt64(Self.maxRead) : offset
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: Int(size - start)) else { return TranscriptUpdate() }
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return TranscriptUpdate() }
        let complete = data[data.startIndex...lastNewline]
        offset = start + UInt64(complete.count)
        return TranscriptParser.update(fromLines: Data(complete))
    }
}
