import XCTest
@testable import TerminalManager

final class ApprovalTests: XCTestCase {
    func testAPermissionCardAndItsAnswers() throws {
        let ask = try XCTUnwrap(AskRequest.parse([
            "tool_name": "Write", "cwd": "/w/demo", "tool_input": ["file_path": "/w/demo/hello.txt", "content": "hi"],
            "permission_suggestions": [["type": "setMode", "mode": "acceptEdits", "destination": "session"]],
        ]))
        XCTAssertEqual(ask.kind, .permission)
        XCTAssertEqual(ask.text, "Allow Write: hello.txt?")
        XCTAssertEqual(ask.options, ["Allow once", "Always allow", "Deny"])
        XCTAssertEqual(ask.summary, "Wants to write hello.txt")
        let allow = try XCTUnwrap(HookAnswer.output(for: ask, answer: .option(0)))
        XCTAssertEqual(allow.stamp, "Allowed once")
        let decision = (allow.output["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "allow")
        let always = try XCTUnwrap(HookAnswer.output(for: ask, answer: .option(1)))
        let updated = ((always.output["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])?["updatedPermissions"] as? [[String: Any]]
        XCTAssertEqual(updated?.first?["mode"] as? String, "acceptEdits")
        let deny = try XCTUnwrap(HookAnswer.output(for: ask, answer: .option(2)))
        XCTAssertEqual(deny.stamp, "Denied")
        XCTAssertNil(HookAnswer.output(for: ask, answer: .option(3)))
        XCTAssertNil(HookAnswer.output(for: ask, answer: .text("yes")))
    }

    func testAlwaysNeedsASuggestionToEcho() throws {
        let ask = try XCTUnwrap(AskRequest.parse(["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]]))
        XCTAssertEqual(ask.options, ["Allow once", "Deny"])
        XCTAssertEqual(ask.text, "Allow Bash: rm -rf build?")
        let rule: [String: Any] = ["type": "addRules", "behavior": "allow", "destination": "localSettings", "rules": [["toolName": "Bash", "ruleContent": "npm test:*"]]]
        XCTAssertNotNil(AskRequest.alwaysEntry([rule]))
        XCTAssertNil(AskRequest.alwaysEntry([rule, rule]))
    }

    func testAQuestionIsAnsweredWithItsOwnInputEchoed() throws {
        let input: [String: Any] = ["questions": [["question": "Tabs or one form?", "header": "Layout", "multiSelect": false, "options": [["label": "Tabs"], ["label": "One form"]]]]]
        let ask = try XCTUnwrap(AskRequest.parse(["tool_name": "AskUserQuestion", "tool_input": input]))
        XCTAssertEqual(ask.kind, .question)
        XCTAssertEqual(ask.options, ["Tabs", "One form", "Type an answer"])
        let picked = try XCTUnwrap(HookAnswer.output(for: ask, answer: .option(1)))
        let decision = (picked.output["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        let answers = (decision?["updatedInput"] as? [String: Any])?["answers"] as? [String: String]
        XCTAssertEqual(answers, ["Tabs or one form?": "One form"])
        XCTAssertEqual(try XCTUnwrap(HookAnswer.output(for: ask, answer: .text(" my own "))).stamp, "Answered: my own")
    }

    func testSeveralQuestionsAreLeftToTheTerminal() throws {
        let one: [String: Any] = ["question": "A?", "options": [["label": "x"]]]
        let ask = try XCTUnwrap(AskRequest.parse(["tool_name": "AskUserQuestion", "tool_input": ["questions": [one, one]]]))
        XCTAssertFalse(ask.isAnswerable)
        XCTAssertEqual(ask.options, [])
        XCTAssertNil(HookAnswer.output(for: ask, answer: .option(0)))
        let inexact = try XCTUnwrap(AskRequest.parse(["tool_name": "Bash", "tool_input": ["command": "ls"]], isInputExact: false))
        XCTAssertNil(HookAnswer.output(for: inexact, answer: .option(0)))
    }
}
