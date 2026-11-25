import XCTest
import HookWire
@testable import TerminalManager

final class HookWireTests: XCTestCase {
    func testArgumentsParse() {
        let parsed = HookArguments.parse(["hook", "--socket", "/tmp/a.sock", "--server", "/Apps/tm", "PreToolUse"])
        XCTAssertEqual(parsed, HookArguments(socketPath: "/tmp/a.sock", serverPath: "/Apps/tm", event: "PreToolUse"))
        XCTAssertNil(HookArguments.parse(["hook", "--socket", "relative.sock", "--server", "/Apps/tm", "Stop"]))
        XCTAssertNil(HookArguments.parse(["hook", "--socket", "/a", "--server", "/b", "Not-An-Event"]))
        XCTAssertNil(HookArguments.parse(["hook", "--socket", "/a", "--server", "/b"]))
    }

    func testMessageRoundTripCarriesTheAppSession() throws {
        let message = HookMessage(event: "PermissionRequest", isInteractive: true, claudePID: 4242, appSession: "ab12cd34ef", input: ["tool_name": "Bash", "tool_input": ["command": "ls"]])
        let line = try XCTUnwrap(HookLine.messageLine(message))
        XCTAssertEqual(line.last, 0x0A)
        let parsed = try XCTUnwrap(HookLine.parseMessage(line))
        XCTAssertEqual(parsed.event, "PermissionRequest")
        XCTAssertEqual(parsed.appSession, "ab12cd34ef")
        XCTAssertEqual(parsed.claudePID, 4242)
        XCTAssertTrue(HookLine.holds(parsed))
    }

    func testABadAppSessionIsRefused() throws {
        let message = HookMessage(event: "Stop", isInteractive: true, claudePID: 1, appSession: "../../etc", input: [:])
        let line = try XCTUnwrap(HookLine.messageLine(message))
        XCTAssertNil(HookLine.parseMessage(line))
    }

    func testOnlyAnInteractiveMainPermissionRequestHolds() {
        XCTAssertTrue(HookLine.holds(event: "PermissionRequest", isInteractive: true, input: [:]))
        XCTAssertFalse(HookLine.holds(event: "PermissionRequest", isInteractive: false, input: [:]))
        XCTAssertFalse(HookLine.holds(event: "PermissionRequest", isInteractive: true, input: ["agent_id": "x1"]))
        XCTAssertFalse(HookLine.holds(event: "PreToolUse", isInteractive: true, input: [:]))
        XCTAssertTrue(HookLine.isInteractive(entrypoint: "cli", hasTTY: true))
        XCTAssertFalse(HookLine.isInteractive(entrypoint: "sdk-cli", hasTTY: true))
    }

    func testStrippingDropsToolOutputAndClipsLongText() {
        let long = String(repeating: "x", count: HookLine.maxTextLength + 10)
        let stripped = HookLine.strippedInput(["tool_response": "big", "prompt": long, "session_id": "s"])
        XCTAssertNil(stripped["tool_response"])
        XCTAssertEqual((stripped["prompt"] as? String)?.count, HookLine.maxTextLength + 1)
        XCTAssertEqual(stripped["session_id"] as? String, "s")
    }

    func testAmbiguousJSONIsNeverHeld() throws {
        let data = Data(#"{"tool_name":"Bash","tool_name":"Edit"}"#.utf8)
        let read = try XCTUnwrap(HookLine.readInput(data))
        XCTAssertTrue(read.scan.isAmbiguous)
        let message = HookMessage(event: "PermissionRequest", isInteractive: true, claudePID: 2, appSession: nil, input: read.input, isAmbiguous: true)
        XCTAssertFalse(HookLine.holds(message))
    }

    func testListenerMustBeTheSameUserAndBinary() {
        XCTAssertTrue(HookLine.isExpectedListener(peerUID: 501, ownUID: 501, peerPath: "/a/tm", serverPath: "/a/tm"))
        XCTAssertFalse(HookLine.isExpectedListener(peerUID: 0, ownUID: 501, peerPath: "/a/tm", serverPath: "/a/tm"))
        XCTAssertFalse(HookLine.isExpectedListener(peerUID: 501, ownUID: 501, peerPath: "/other", serverPath: "/a/tm"))
        XCTAssertFalse(HookLine.isExpectedListener(peerUID: nil, ownUID: 501, peerPath: "/a/tm", serverPath: "/a/tm"))
    }
}

final class HookRoutingTests: XCTestCase {
    let candidates = [
        HookRouter.Candidate(id: "one", claudeSessionID: "uuid-1", claudePID: 100, dir: "/w/api"),
        HookRouter.Candidate(id: "two", claudeSessionID: "uuid-2", claudePID: 200, dir: "/w/web"),
        HookRouter.Candidate(id: "three", claudeSessionID: nil, claudePID: nil, dir: "/w/web"),
    ]

    func testTheAppSessionVariableWins() {
        XCTAssertEqual(HookRouter.route(appSession: "two", claudeSessionID: "uuid-1", claudePID: 100, cwd: "/w/api", candidates: candidates), "two")
    }

    func testFallsBackToSessionIDThenPIDThenAUniqueFolder() {
        XCTAssertEqual(HookRouter.route(appSession: nil, claudeSessionID: "uuid-1", claudePID: 0, cwd: nil, candidates: candidates), "one")
        XCTAssertEqual(HookRouter.route(appSession: "gone", claudeSessionID: "other", claudePID: 200, cwd: nil, candidates: candidates), "two")
        XCTAssertEqual(HookRouter.route(appSession: nil, claudeSessionID: nil, claudePID: 0, cwd: "/w/api", candidates: candidates), "one")
        XCTAssertNil(HookRouter.route(appSession: nil, claudeSessionID: nil, claudePID: 0, cwd: "/w/web", candidates: candidates), "two sessions share the folder")
        XCTAssertNil(HookRouter.route(appSession: nil, claudeSessionID: "x", claudePID: 999, cwd: "/elsewhere", candidates: candidates))
    }

    func testHookEventReadsTheFieldsTheAppUses() {
        let event = HookEvent(event: "PermissionRequest", appSession: "one", claudePID: 100, input: [
            "session_id": "uuid-1", "cwd": "/w/api", "transcript_path": "/t.jsonl", "permission_mode": "default",
            "tool_name": "Bash", "tool_input": ["command": "npm test"],
        ], connection: 7)
        XCTAssertEqual(event.claudeSessionID, "uuid-1")
        XCTAssertEqual(event.transcriptPath, "/t.jsonl")
        XCTAssertEqual(event.permissionMode.flatMap(PermissionMode.init(hookValue:)), .manual)
        XCTAssertEqual(event.ask?.text, "Allow Bash: npm test?")
        XCTAssertEqual(event.connection, 7)
    }
}
