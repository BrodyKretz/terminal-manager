import XCTest
@testable import TerminalManager

final class StatusReducerTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1000)
    let later = Date(timeIntervalSince1970: 2000)

    func activity(_ status: SessionStatus) -> ClaudeActivity {
        ClaudeActivity(status: status, statusAt: start, summary: "", hasError: false)
    }

    func testAFullTurn() {
        var a = ClaudeActivity.fresh(at: start)
        a = ClaudeStatusReducer.reduce(a, .promptSubmitted("create hello.txt"), now: later)
        XCTAssertEqual(a.status, .working)
        XCTAssertEqual(a.summary, "create hello.txt")
        XCTAssertEqual(a.statusAt, later)
        a = ClaudeStatusReducer.reduce(a, .toolStarted(summary: "Writing hello.txt"), now: later)
        XCTAssertEqual(a.status, .working)
        a = ClaudeStatusReducer.reduce(a, .permissionRequested(summary: "Wants to write hello.txt"), now: later)
        XCTAssertEqual(a.status, .needsYou)
        a = ClaudeStatusReducer.reduce(a, .answered, now: later)
        XCTAssertEqual(a.status, .working)
        a = ClaudeStatusReducer.reduce(a, .toolEnded(hasPendingAsk: false), now: later)
        XCTAssertEqual(a.status, .working)
        a = ClaudeStatusReducer.reduce(a, .stopped(lastReply: "Created hello.txt.", stopHookActive: false), now: later)
        XCTAssertEqual(a.status, .ready)
        XCTAssertEqual(a.summary, "Done: Created hello.txt.")
    }

    func testViewingDoesNotClearReadyButLooksGoodDoes() {
        let ready = activity(.ready)
        XCTAssertEqual(ClaudeStatusReducer.reduce(ready, .reviewed, now: later).status, .reviewed)
        XCTAssertEqual(ClaudeStatusReducer.reduce(activity(.working), .reviewed, now: later).status, .working)
    }

    func testAParallelToolDoesNotClearANeededAnswer() {
        XCTAssertEqual(ClaudeStatusReducer.reduce(activity(.needsYou), .toolStarted(summary: "x"), now: later).status, .needsYou)
        XCTAssertEqual(ClaudeStatusReducer.reduce(activity(.needsYou), .toolEnded(hasPendingAsk: true), now: later).status, .needsYou)
        XCTAssertEqual(ClaudeStatusReducer.reduce(activity(.needsYou), .toolEnded(hasPendingAsk: false), now: later).status, .working)
    }

    func testStopFailureIsReadyWithAnError() {
        let a = ClaudeStatusReducer.reduce(activity(.working), .stopFailed, now: later)
        XCTAssertEqual(a.status, .ready)
        XCTAssertTrue(a.hasError)
    }

    func testAStopHookThatBlocksChangesNothing() {
        XCTAssertEqual(ClaudeStatusReducer.reduce(activity(.working), .stopped(lastReply: nil, stopHookActive: true), now: later).status, .working)
    }

    func testSessionEndAndExit() {
        XCTAssertEqual(ClaudeStatusReducer.reduce(activity(.ready), .sessionEnded(reason: "prompt_input_exit"), now: later).status, .exited)
        XCTAssertEqual(ClaudeStatusReducer.reduce(activity(.ready), .sessionEnded(reason: "clear"), now: later).status, .ready)
        XCTAssertEqual(ClaudeStatusReducer.reduce(activity(.working), .processExited, now: later).status, .exited)
    }

    func testANotificationPromptNeedsYouOnlyFromWorkOrIdle() {
        XCTAssertEqual(ClaudeStatusReducer.reduce(activity(.working), .permissionPrompt, now: later).status, .needsYou)
        XCTAssertEqual(ClaudeStatusReducer.reduce(activity(.ready), .permissionPrompt, now: later).status, .ready)
    }

    func testAnInterruptEndsTheTurn() {
        let a = ClaudeStatusReducer.reduce(activity(.working), .wentIdle, now: later)
        XCTAssertEqual(a.status, .ready)
        XCTAssertEqual(a.summary, "Interrupted")
        XCTAssertEqual(ClaudeStatusReducer.reduce(activity(.reviewed), .wentIdle, now: later).status, .reviewed)
    }

    func testStatusTimeMovesOnlyWithTheStatus() {
        let a = ClaudeStatusReducer.reduce(activity(.working), .toolStarted(summary: "Reading"), now: later)
        XCTAssertEqual(a.statusAt, start)
        XCTAssertEqual(a.summary, "Reading")
    }

    func testResumeAndClear() {
        XCTAssertEqual(ClaudeStatusReducer.reduce(activity(.exited), .sessionStarted(source: "resume"), now: later).summary, "Resumed, waiting for a message")
        XCTAssertEqual(ClaudeStatusReducer.reduce(activity(.ready), .sessionStarted(source: "clear"), now: later).status, .idle)
        XCTAssertEqual(ClaudeStatusReducer.reduce(activity(.working), .sessionStarted(source: "compact"), now: later).status, .working)
    }

    func testBannerRule() {
        XCTAssertTrue(BannerRule.shouldBanner(to: .needsYou, isWindowKey: false, notificationsEnabled: true, doNotDisturb: false, isMuted: false))
        XCTAssertFalse(BannerRule.shouldBanner(to: .needsYou, isWindowKey: true, notificationsEnabled: true, doNotDisturb: false, isMuted: false))
        XCTAssertFalse(BannerRule.shouldBanner(to: .ready, isWindowKey: false, notificationsEnabled: true, doNotDisturb: false, isMuted: false))
        XCTAssertFalse(BannerRule.shouldBanner(to: .needsYou, isWindowKey: false, notificationsEnabled: false, doNotDisturb: false, isMuted: false))
        XCTAssertFalse(BannerRule.shouldBanner(to: .needsYou, isWindowKey: false, notificationsEnabled: true, doNotDisturb: true, isMuted: false))
        XCTAssertFalse(BannerRule.shouldBanner(to: .needsYou, isWindowKey: false, notificationsEnabled: true, doNotDisturb: false, isMuted: true))
    }

    func testStatusIcon() {
        XCTAssertEqual(StatusIconState.from(needsYou: 1, ready: 3), .needsYou)
        XCTAssertEqual(StatusIconState.from(needsYou: 0, ready: 1), .ready)
        XCTAssertEqual(StatusIconState.from(needsYou: 0, ready: 0), .idle)
        XCTAssertTrue(StatusIcon.image(for: .idle).isTemplate)
        XCTAssertFalse(StatusIcon.image(for: .needsYou).isTemplate)
        XCTAssertFalse(StatusIcon.image(for: .ready).isTemplate)
    }
}
