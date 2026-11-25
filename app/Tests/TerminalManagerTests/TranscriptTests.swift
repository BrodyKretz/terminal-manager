import XCTest
@testable import TerminalManager

final class TranscriptTests: XCTestCase {
    func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    func testRepliesAndContextFromAssistantLines() {
        let lines = [
            line(["type": "user", "message": ["role": "user", "content": "create hello.txt"]]),
            line(["type": "assistant", "message": ["model": "claude-x", "content": [["type": "thinking", "thinking": "hm"], ["type": "text", "text": "I'll create it."]],
                                                    "usage": ["input_tokens": 10, "cache_read_input_tokens": 20_000, "cache_creation_input_tokens": 1000, "output_tokens": 50]]]),
            line(["type": "assistant", "isSidechain": true, "message": ["content": [["type": "text", "text": "subagent text"]]]]),
            line(["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Write", "input": [:]]]]]),
            line(["type": "assistant", "isApiErrorMessage": true, "message": ["content": "API Error"]]),
        ].joined(separator: "\n") + "\n"
        let update = TranscriptParser.update(fromLines: Data(lines.utf8))
        XCTAssertEqual(update.replies, ["I'll create it."])
        XCTAssertEqual(update.contextTokens, 21_060)
        XCTAssertEqual(update.model, "claude-x")
        XCTAssertEqual(TranscriptParser.contextPercent(tokens: 21_060, model: "claude-x"), 11)
        XCTAssertEqual(TranscriptParser.contextPercent(tokens: 500_000, model: nil), 50)
    }

    func testTheFollowerReadsOnlyCompleteNewLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tm-transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((line(["type": "assistant", "message": ["content": "old"]]) + "\n").utf8).write(to: url)
        var follower = TranscriptFollower.atEnd(of: url.path)
        XCTAssertEqual(follower.readNew().replies, [])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let next = line(["type": "assistant", "message": ["content": "new reply"]])
        try handle.write(contentsOf: Data((next + "\n" + #"{"type":"assist"#).utf8))
        XCTAssertEqual(follower.readNew().replies, ["new reply"])
        try handle.write(contentsOf: Data((#"ant","message":{"content":"tail"}}"# + "\n").utf8))
        try handle.close()
        XCTAssertEqual(follower.readNew().replies, ["tail"])
    }

    func testGitNumstatAndToolChanges() {
        XCTAssertEqual(GitChanges.parseNumstat("3\t1\tsrc/a.ts\n-\t-\timg.png\n"), [FileChange(path: "src/a.ts", add: 3, del: 1), FileChange(path: "img.png", add: 0, del: 0, isBinary: true)])
        XCTAssertEqual(GitChanges.toolChange(tool: "Write", input: ["file_path": "/w/a/hello.txt", "content": "hi\n"], cwd: "/w/a"), FileChange(path: "hello.txt", add: 1, del: 0))
        XCTAssertEqual(GitChanges.toolChange(tool: "Edit", input: ["file_path": "/w/a/x.py", "old_string": "a\nb", "new_string": "c"], cwd: "/w/a"), FileChange(path: "x.py", add: 1, del: 2))
        var files: [FileChange] = []
        GitChanges.merge(FileChange(path: "x", add: 1, del: 0), into: &files)
        GitChanges.merge(FileChange(path: "x", add: 2, del: 1), into: &files)
        XCTAssertEqual(files, [FileChange(path: "x", add: 3, del: 1)])
    }
}
