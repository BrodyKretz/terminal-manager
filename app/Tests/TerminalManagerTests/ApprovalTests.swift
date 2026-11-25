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

final class AskSafetyTests: XCTestCase {
    func testAMultiLineCommandIsShownWholeOnTheCard() throws {
        let command = "cd build &&\nmake install\n# then clean\nrm -rf tmp"
        let ask = try XCTUnwrap(AskRequest.parse(["tool_name": "Bash", "tool_input": ["command": command]]))
        XCTAssertEqual(ask.detail, command)
        XCTAssertTrue(ask.isAnswerable)
        XCTAssertEqual(ask.heading, "Allow Bash?")
        XCTAssertEqual(ask.text, "Allow Bash: cd build && make install # then clean rm -rf tmp?", "the feed's one line")
    }

    func testAWriteShowsThePathAndAllOfItsContent() throws {
        let content = String(repeating: "line\n", count: 120)
        let ask = try XCTUnwrap(AskRequest.parse(["tool_name": "Write", "tool_input": ["file_path": "/w/a.txt", "content": content]]))
        XCTAssertEqual(ask.detail, "/w/a.txt\n\n" + content)
        XCTAssertTrue(ask.isAnswerable)
    }

    func testHiddenCharactersSendTheCardToTheTerminal() throws {
        for sneaky in ["echo safe\u{202E}fr- mr", "ls\u{200B}", "printf '\u{1B}[2J'", "a\u{2066}b", "x\r rm -rf ~"] {
            let ask = try XCTUnwrap(AskRequest.parse(["tool_name": "Bash", "tool_input": ["command": sneaky]]))
            XCTAssertFalse(ask.isAnswerable, sneaky.debugDescription)
            XCTAssertNotNil(ask.terminalReason)
            XCTAssertFalse(ask.detail.unicodeScalars.contains(where: AskRequest.isHidden), "hidden characters are spelled out")
            XCTAssertNil(HookAnswer.output(for: ask, answer: .option(0)), "no Allow for what the card cannot show")
        }
        XCTAssertEqual(AskRequest.visible("a\u{202E}b"), "a\\u{202E}b")
        XCTAssertTrue(try XCTUnwrap(AskRequest.parse(["tool_name": "Bash", "tool_input": ["command": "printf 'a\tb'\n"]])).isAnswerable, "tabs and newlines are fine")
    }

    func testInputTooLongToShowIsAnsweredInTheTerminal() throws {
        let long = String(repeating: "x", count: AskRequest.maxDetailCharacters + 1)
        let ask = try XCTUnwrap(AskRequest.parse(["tool_name": "Bash", "tool_input": ["command": long]]))
        XCTAssertFalse(ask.isAnswerable)
        let manyLines = String(repeating: "a\n", count: AskRequest.maxDetailLines + 1)
        XCTAssertFalse(try XCTUnwrap(AskRequest.parse(["tool_name": "Write", "tool_input": ["file_path": "/f", "content": manyLines]])).isAnswerable)
    }

    func testAQuestionWithHiddenCharactersIsNotAnswerable() throws {
        let input: [String: Any] = ["questions": [["question": "Pick\u{202E} one", "options": [["label": "A"]]]]]
        XCTAssertFalse(try XCTUnwrap(AskRequest.parse(["tool_name": "AskUserQuestion", "tool_input": input])).isAnswerable)
    }

    func testAnAnswerGoesOnlyToTheAskTheCardShowed() throws {
        let ask = try XCTUnwrap(AskRequest.parse(["tool_name": "Bash", "tool_input": ["command": "ls"]]))
        let first = HeldAsk(id: "ask-1", sessionID: "s1", connection: 1, ask: ask, createdAt: Date(), feedSeq: nil)
        let second = HeldAsk(id: "ask-2", sessionID: "s1", connection: 2, ask: ask, createdAt: Date(), feedSeq: nil)
        let other = HeldAsk(id: "ask-3", sessionID: "s2", connection: 3, ask: ask, createdAt: Date(), feedSeq: nil)
        XCTAssertEqual(try SessionManager.heldAsk("ask-2", session: "s1", in: [first, second, other]).get().id, "ask-2")
        XCTAssertEqual(try SessionManager.heldAsk("ask-1", session: "s1", in: [first, second]).get().id, "ask-1")
        if case .failure(let error) = SessionManager.heldAsk("ask-1", session: "s1", in: [second]) {
            XCTAssertEqual(error, .alreadyAnswered, "the shown ask went; the next one is never answered in its place")
        } else {
            XCTFail("an ask that is gone must not be answered")
        }
        if case .success = SessionManager.heldAsk("ask-3", session: "s1", in: [first, other]) { XCTFail("another session's ask") }
    }
}
