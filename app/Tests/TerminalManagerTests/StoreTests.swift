import XCTest
@testable import TerminalManager

final class StoreTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testSessionsFileRoundTrip() throws {
        var file = SessionsFile()
        var claude = SessionRecord(id: "abc123", kind: .claude, name: "api-server", dir: "/w/api-server", created: Date(timeIntervalSince1970: 1_800_000_000))
        claude.mode = .manual
        claude.claudeSessionID = "0f8e-uuid"
        claude.status = .ready
        claude.statusAt = Date(timeIntervalSince1970: 1_800_000_050.25)
        claude.muted = true
        claude.hasConversation = true
        claude.context = 42
        var shell = SessionRecord(id: "def456", kind: .shell, name: "zsh", dir: "/w", created: Date(timeIntervalSince1970: 1_800_000_100))
        shell.statusAt = shell.created
        file.sessions = [claude, shell]
        file.closed = [ClosedSession(id: "old1", name: "notes", dir: "/w/notes", mode: .auto, claudeSessionID: "u", closedAt: Date(timeIntervalSince1970: 1_800_000_200), lastLine: "Done.")]
        let url = folder.appendingPathComponent("sessions.json")
        try file.save(to: url)
        XCTAssertEqual(SessionsFile.load(from: url), file)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testOnlyAConversationNobodyEndedResumesAtLaunch() {
        var record = SessionRecord(id: "a", kind: .claude, name: "api", dir: "/w", created: Date())
        record.claudeSessionID = "u"
        XCTAssertFalse(record.resumesAtLaunch, "no turn yet, nothing to resume")
        record.hasConversation = true
        XCTAssertTrue(record.resumesAtLaunch)
        record.endReason = "other"
        XCTAssertTrue(record.resumesAtLaunch, "a killed tmux server or a reboot")
        record.endReason = "prompt_input_exit"
        XCTAssertFalse(record.resumesAtLaunch, "/exit on purpose: offered, not forced")
        record.endReason = nil
        record.kind = .shell
        XCTAssertFalse(record.resumesAtLaunch)
    }

    func testAnOlderRecordStillLoads() throws {
        let json = #"{"version":1,"sessions":[{"id":"a1","kind":"shell","name":"zsh","dir":"/w","created":"2026-11-01T10:00:00Z"}],"closed":[]}"#
        let url = folder.appendingPathComponent("sessions.json")
        try Data(json.utf8).write(to: url)
        let loaded = SessionsFile.load(from: url)
        XCTAssertEqual(loaded.sessions.first?.status, .idle)
        XCTAssertEqual(loaded.sessions.first?.tmuxName, "tm-a1")
        XCTAssertFalse(loaded.sessions.first?.muted ?? true)
    }

    func testABrokenFileIsKeptAside() throws {
        let url = folder.appendingPathComponent("sessions.json")
        try Data("{not json".utf8).write(to: url)
        XCTAssertEqual(SessionsFile.load(from: url).sessions, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".bad"))
    }

    func testSettingsAndRecentFolders() throws {
        var settings = AppSettings()
        XCTAssertTrue(settings.notificationsEnabled)
        settings.noteUsed("/w/a")
        settings.noteUsed("/w/b")
        settings.noteUsed("/w/a")
        XCTAssertEqual(settings.recentDirs, ["/w/a", "/w/b"])
        let url = folder.appendingPathComponent("settings.json")
        try settings.save(to: url)
        XCTAssertEqual(AppSettings.load(from: url), settings)
    }

    func testFolderSuggestionsPutUsedFirstThenNewest() {
        let old = Date(timeIntervalSince1970: 1), new = Date(timeIntervalSince1970: 2)
        let order = FolderSuggestions.order(recent: ["/w/c"], folders: [("/w/a", old), ("/w/b", new), ("/w/c", old)])
        XCTAssertEqual(order, ["/w/c", "/w/b", "/w/a"])
    }

    func testFeedLogKeepsALimitAndDropsThinking() throws {
        var log = FeedLog()
        for index in 0..<(FeedLog.limit + 5) { log.append(sid: "a", sname: "api", type: "tool") { $0.args = "\(index)" } }
        XCTAssertEqual(log.events.count, FeedLog.limit)
        let think = log.append(sid: "a", sname: "api", type: "think")
        XCTAssertTrue(log.hasThinking(sid: "a"))
        XCTAssertEqual(log.removeThinking(sid: "a"), [think.seq])
        log.update(seq: log.events.last!.seq) { $0.answer = "Allowed once" }
        XCTAssertEqual(log.events.last?.answer, "Allowed once")
        let url = folder.appendingPathComponent("feed.json")
        try log.save(to: url)
        XCTAssertEqual(FeedLog.load(from: url).events.count, FeedLog.limit - 1)
    }

    func testLoginAgentPlist() {
        let plist = LoginItem.agentPlist(bundlePath: "/Users/x/Applications/Terminal Manager.app")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/usr/bin/open", "-a", "/Users/x/Applications/Terminal Manager.app"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertFalse(LoginItem.availability(bundleURL: URL(fileURLWithPath: "/w/build/debug/terminal-manager"), home: "/Users/x").isAvailable)
        XCTAssertFalse(LoginItem.availability(bundleURL: URL(fileURLWithPath: "/w/build/Terminal Manager.app"), home: "/Users/x").isAvailable)
        XCTAssertTrue(LoginItem.availability(bundleURL: URL(fileURLWithPath: "/Users/x/Applications/Terminal Manager.app"), home: "/Users/x").isAvailable)
    }

    func testPluginHooksRunTheHelperForEveryEvent() throws {
        let hooks = ClaudePlugin.hooksObject(socketPath: "/h/run/hooks.sock", serverPath: "/A/Terminal Manager.app/Contents/MacOS/terminal-manager")["hooks"] as? [String: Any]
        XCTAssertEqual(Set(hooks?.keys.map { $0 } ?? []), Set(ClaudePlugin.events.map(\.name)))
        let permission = try XCTUnwrap((hooks?["PermissionRequest"] as? [[String: Any]])?.first)
        let command = try XCTUnwrap((permission["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(command["timeout"] as? Int, 600)
        XCTAssertEqual(command["command"] as? String, #""${CLAUDE_PLUGIN_ROOT}/bin/terminal-manager-hook" --socket "/h/run/hooks.sock" --server "/A/Terminal Manager.app/Contents/MacOS/terminal-manager" PermissionRequest"#)
    }
}
