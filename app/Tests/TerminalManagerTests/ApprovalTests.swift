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
        XCTAssertEqual(ask.detail, "hello.txt\nhi")
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
    func fit(_ tool: String, _ input: [String: Any], cwd: String? = "/w/demo", exact: Bool = true) -> AskDisplay.Fit {
        AskDisplay.permission(tool: tool, input: input, cwd: cwd, isInputExact: exact)
    }

    func testAShortCommandIsShownWholeEverywhere() {
        let result = fit("Bash", ["command": "npm test"])
        XCTAssertTrue(result.isAnswerable)
        XCTAssertTrue(result.fitsCompact)
        XCTAssertEqual(result.detail, "npm test")
    }

    func testEveryOtherKeyIsShownAsJSONBelow() {
        let result = fit("Bash", ["command": "ls", "description": "List", "timeout": 5])
        XCTAssertEqual(result.detail, "ls\n{\"description\":\"List\",\"timeout\":5}")
        XCTAssertTrue(result.isAnswerable)
        let edit = fit("Edit", ["file_path": "/w/demo/a.py", "old_string": "x = 1", "new_string": "x = 2", "replace_all": true])
        XCTAssertEqual(edit.detail, "a.py\n- x = 1\n+ x = 2\n{\"replace_all\":true}")
        let unknown = fit("WebFetch", ["url": "https://example.com", "prompt": "summary"])
        XCTAssertEqual(unknown.detail, "{\"prompt\":\"summary\",\"url\":\"https://example.com\"}")
    }

    func testAFileWithItsFinalNewlineStillFits() {
        let write = fit("Write", ["file_path": "/w/demo/hello.txt", "content": "hi\n"])
        XCTAssertTrue(write.isAnswerable)
        XCTAssertEqual(write.detail, "hello.txt\nhi")
        XCTAssertFalse(fit("Write", ["file_path": "/w/demo/hello.txt", "content": "hi\n\n\n"]).isAnswerable)
        let read = fit("Read", ["file_path": "/w/demo/src/a.ts", "limit": 40])
        XCTAssertEqual(read.detail, "src/a.ts\n{\"limit\":40}")
    }

    func testAMultiLineCommandThatFitsKeepsItsLines() {
        let command = "cd build &&\nmake install"
        let result = fit("Bash", ["command": command])
        XCTAssertEqual(result.detail, command)
        XCTAssertTrue(result.isAnswerable)
    }

    func testTooWideOrTooTallGoesToTheTerminal() {
        XCTAssertFalse(fit("Bash", ["command": String(repeating: "a", count: AskDisplay.fullColumns + 1)]).isAnswerable)
        XCTAssertFalse(fit("Bash", ["command": Array(repeating: "echo", count: AskDisplay.fullLines + 1).joined(separator: "\n")]).isAnswerable)
        let wideForCompact = fit("Bash", ["command": String(repeating: "a", count: AskDisplay.compactColumns + 1)])
        XCTAssertTrue(wideForCompact.isAnswerable)
        XCTAssertFalse(wideForCompact.fitsCompact, "only the wide card gets buttons")
        XCTAssertFalse(fit("Bash", ["command": String(repeating: "\t", count: 13) + "x"]).isAnswerable, "a tab counts as eight columns")
        XCTAssertFalse(fit("Write", ["file_path": "/w/demo/f", "content": String(repeating: "line\n", count: 20)]).isAnswerable)
    }

    func testLongBlankRunsGoToTheTerminal() {
        XCTAssertFalse(fit("Bash", ["command": "echo safe\n\n\nrm -rf ~"]).isAnswerable, "lines pushed out of view")
        XCTAssertFalse(fit("Bash", ["command": "echo safe" + String(repeating: " ", count: 8) + "; rm x"]).isAnswerable, "text pushed sideways")
        XCTAssertFalse(fit("Bash", ["command": "\nls"]).isAnswerable)
        XCTAssertTrue(fit("Bash", ["command": "a\n\nb"]).isAnswerable, "one blank line is fine")
    }

    func testBashIsPlainASCIIOnly() {
        for sneaky in ["echo safe\u{202E}fr- mr", "ls\u{200B}", "printf '\u{1B}[2J'", "a\u{2066}b", "x\r rm -rf ~", "echo caf\u{E9}", "echo \u{3164}", "echo\u{00A0}hi"] {
            XCTAssertFalse(fit("Bash", ["command": sneaky]).isAnswerable, sneaky.debugDescription)
        }
        XCTAssertTrue(fit("Bash", ["command": "printf 'a\tb'"]).isAnswerable)
    }

    func testOtherToolsAllowLettersAndDigitsButNothingInvisible() {
        XCTAssertTrue(fit("Write", ["file_path": "/w/demo/notes.md", "content": "café 5 東京 ½"]).isAnswerable)
        let rejected: [String] = [
            "a\u{0301}", "x\u{200D}y", "\u{FEFF}hi", "a\u{2028}b", "a\u{2029}b", "\u{115F}", "\u{1160}", "\u{3164}", "\u{FFA0}", "\u{2800}",
            "a\u{00A0}b", "a\u{2003}b", "a\u{034F}b", "\u{1B}[31m", "a\u{7F}", "\u{E000}", "a\u{20DD}", "\u{1F600}",
        ]
        for text in rejected {
            XCTAssertFalse(fit("Write", ["file_path": "/w/demo/f", "content": text]).isAnswerable, text.debugDescription)
        }
        XCTAssertFalse(fit("Bash", ["command": "ls", "description": "List\u{202E}"]).isAnswerable, "every string of the input is checked")
        XCTAssertFalse(fit("WebFetch", ["url\u{200B}": "https://example.com"]).isAnswerable, "keys too")
    }

    func testInexactNumbersGoToTheTerminal() {
        XCTAssertFalse(fit("Bash", ["command": "ls"], exact: false).isAnswerable)
    }

    func testTheCardCarriesTheRule() throws {
        let ask = try XCTUnwrap(AskRequest.parse(["tool_name": "Bash", "tool_input": ["command": "rm -rf build\u{202E}"]]))
        XCTAssertFalse(ask.isAnswerable)
        XCTAssertEqual(ask.detail, "", "nothing half-shown")
        XCTAssertNotNil(ask.terminalReason)
        XCTAssertNil(HookAnswer.output(for: ask, answer: .option(0)), "no Allow for what the card cannot show")
        let question = try XCTUnwrap(AskRequest.parse(["tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "Tabs?", "options": [["label": "Yes\u{200B}"]]]]]]))
        XCTAssertFalse(question.isAnswerable)
        XCTAssertEqual(question.options, [])
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
