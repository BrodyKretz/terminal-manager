import XCTest
@testable import TerminalManager

final class TmuxCommandTests: XCTestCase {
    let tmux = TmuxCommands(tmuxPath: "/opt/homebrew/bin/tmux", socketName: "terminal-manager", configPath: "/s/tmux.conf")

    func testEveryCallUsesThePrivateServer() {
        XCTAssertEqual(Array(tmux.listPanes().prefix(5)), ["/opt/homebrew/bin/tmux", "-L", "terminal-manager", "-f", "/s/tmux.conf"])
        XCTAssertEqual(tmux.killSession("tm-abc"), tmux.base + ["kill-session", "-t", "=tm-abc"])
        XCTAssertEqual(tmux.sendKeys("tm-abc", keys: ["Escape"]), tmux.base + ["send-keys", "-t", "=tm-abc:", "Escape"])
        XCTAssertEqual(tmux.pasteBuffer("b", into: "tm-abc"), tmux.base + ["paste-buffer", "-p", "-d", "-b", "b", "-t", "=tm-abc:"])
    }

    func testNewSessionPassesTheCommandAsArguments() {
        let arguments = tmux.newSession(name: "tm-abc", dir: "/w/my app", cols: 160, rows: 45, command: ["/usr/bin/env", "-i", "A=1", "/bin/zsh", "-l"])
        XCTAssertEqual(arguments, tmux.base + ["new-session", "-d", "-s", "tm-abc", "-c", "/w/my app", "-x", "160", "-y", "45", "/usr/bin/env", "-i", "A=1", "/bin/zsh", "-l"])
        XCTAssertEqual(tmux.respawn(name: "tm-abc", dir: "/w", command: ["x"]), tmux.base + ["respawn-pane", "-k", "-t", "=tm-abc:", "-c", "/w", "x"])
    }

    func testAttachForcesUTF8() {
        XCTAssertEqual(tmux.attach("tm-abc"), ["/opt/homebrew/bin/tmux", "-u", "-L", "terminal-manager", "-f", "/s/tmux.conf", "attach-session", "-t", "=tm-abc"])
    }

    func testConfigKeepsExitedPanesAndHasNoStatusLine() {
        for line in ["set -g status off", "set -sg escape-time 0", "set -g remain-on-exit on", "set -g history-limit 50000", "set -g default-terminal \"xterm-256color\""] {
            XCTAssertTrue(TmuxCommands.configText.contains(line), line)
        }
    }

    func testPaneListing() {
        let panes = PaneInfo.parse("tm-a\t0\t\tzsh\t/w/a\t123\t/dev/ttys004\ntm-b\t1\t3\tenv\t/w/b\t456\t/dev/ttys005\nbroken line\n")
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes[0], PaneInfo(sessionName: "tm-a", isDead: false, deadStatus: nil, currentCommand: "zsh", currentPath: "/w/a", pid: 123, tty: "/dev/ttys004"))
        XCTAssertTrue(panes[1].isDead)
        XCTAssertEqual(panes[1].deadStatus, 3)
    }

    func testForegroundJob() {
        let ps = "  500   500   600 -zsh\n  600   600   600 npm run dev\n  601   600   600 node server.js\n"
        XCTAssertEqual(ForegroundJob.parse(ps, shellPID: 500), "npm run dev")
        XCTAssertNil(ForegroundJob.parse("  500   500   500 -zsh\n", shellPID: 500))
    }
}

final class SessionLaunchTests: XCTestCase {
    let login = [
        "PATH": "/Users/x/.local/bin:/usr/bin", "HOME": "/Users/x", "ANTHROPIC_MODEL": "keep-me",
        "CLAUDE_CODE_PLUGIN_DIRS": "/Users/x/.other-tool/claude-plugin", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli",
        "TMUX": "/tmp/tmux-501/default,1,0", "TERM_PROGRAM": "Apple_Terminal", "VSCODE_PID": "9",
    ]

    func testClaudeGetsOnlyTheAppsPlugin() {
        let env = SessionLaunch.environment(login: login, appSession: "abc123", pluginFolder: "/Users/x/.terminal-manager/claude-plugin")
        XCTAssertEqual(env["CLAUDE_CODE_PLUGIN_DIRS"], "/Users/x/.terminal-manager/claude-plugin")
        XCTAssertEqual(env["TERMINAL_MANAGER_SESSION"], "abc123")
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["ANTHROPIC_MODEL"], "keep-me")
        XCTAssertEqual(env["PATH"], "/Users/x/.local/bin:/usr/bin")
        for dropped in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "TMUX", "TERM_PROGRAM", "VSCODE_PID"] { XCTAssertNil(env[dropped], dropped) }
    }

    func testShellsGetNoPluginVariableAtAll() {
        let env = SessionLaunch.environment(login: login, appSession: "abc123", pluginFolder: nil)
        XCTAssertNil(env["CLAUDE_CODE_PLUGIN_DIRS"])
    }

    func testTheCommandNeverGoesThroughZsh() {
        let env = SessionLaunch.environment(login: login, appSession: "abc123", pluginFolder: "/p")
        let program = SessionLaunch.claudeArguments(claudePath: "/Users/x/.local/bin/claude", mode: .manual, claudeSessionID: "u-1", isResume: false, prompt: "create a file hello.txt containing hi", pluginFolder: "/p")
        let command = SessionLaunch.command(environment: env, program: program)
        XCTAssertEqual(Array(command.prefix(2)), ["/usr/bin/env", "-i"])
        XCTAssertEqual(Array(command.suffix(8)), ["/Users/x/.local/bin/claude", "--permission-mode", "manual", "--plugin-dir", "/p", "--session-id", "u-1", "create a file hello.txt containing hi"])
        XCTAssertFalse(command.contains("/bin/zsh"))
        XCTAssertTrue(command.contains("CLAUDE_CODE_PLUGIN_DIRS=/p"))
        XCTAssertFalse(command.contains { $0.contains(".other-tool") })
    }

    func testResumeUsesTheStoredSessionIDAndNoPrompt() {
        let program = SessionLaunch.claudeArguments(claudePath: "/c", mode: .auto, claudeSessionID: "u-9", isResume: true, prompt: "ignored")
        XCTAssertEqual(program, ["/c", "--permission-mode", "auto", "--resume", "u-9"])
    }

    func testModesMapToTheCLIValues() {
        XCTAssertEqual(PermissionMode.allCases.map(\.rawValue), ["auto", "manual", "acceptEdits", "plan"])
        XCTAssertEqual(PermissionMode.default, .auto)
        XCTAssertEqual(PermissionMode(label: "Ask before edits"), .manual)
        XCTAssertEqual(PermissionMode(hookValue: "default"), .manual)
        XCTAssertEqual(PermissionMode(hookValue: "acceptEdits"), .acceptEdits)
    }

    func testLoginEnvironmentParsing() {
        let output = "conda says hi\n\n__TM_CLAUDE__/Users/x/.local/bin/claude\n__TM_ENV_BEGIN__PATH=/a:/b\0HOME=/Users/x\0MULTI=one\ntwo\0__TM_ENV_END__"
        let parsed = LoginEnvironment.parse(output)
        XCTAssertEqual(parsed.claudePath, "/Users/x/.local/bin/claude")
        XCTAssertEqual(parsed.variables["PATH"], "/a:/b")
        XCTAssertEqual(parsed.variables["MULTI"], "one\ntwo")
        XCTAssertNil(LoginEnvironment.parse("__TM_CLAUDE__\n").claudePath)
    }

    func testPaths() {
        XCTAssertEqual(DisplayPath.absolute("~/work/api", home: "/Users/x"), "/Users/x/work/api")
        XCTAssertEqual(DisplayPath.absolute("api", home: "/Users/x"), "/Users/x/work/api")
        XCTAssertEqual(DisplayPath.absolute("/tmp/a/../b/", home: "/Users/x"), "/tmp/b")
        XCTAssertNil(DisplayPath.absolute("  ", home: "/Users/x"))
        XCTAssertEqual(DisplayPath.tilde("/Users/x/work/api", home: "/Users/x"), "~/work/api")
        XCTAssertEqual(DisplayPath.tilde("/opt", home: "/Users/x"), "/opt")
    }

    func testLaunchOptions() throws {
        let parsed = try LaunchOptions.parse(["tm", "--support-dir", "/s", "--tmux-socket", "tm-test", "--offscreen", "-psn_0_123"], isDebugBuild: true).get()
        XCTAssertEqual(parsed.supportDir?.path, "/s")
        XCTAssertEqual(parsed.paths().tmuxSocketName, "tm-test")
        XCTAssertFalse(parsed.isAccountRun)
        XCTAssertEqual(LaunchOptions.parse(["tm", "--snapshot", "/x.png"], isDebugBuild: false), .failure(.debugOnly("--snapshot")))
        XCTAssertEqual(LaunchOptions.parse(["tm", "--bogus"], isDebugBuild: true), .failure(.unknown("--bogus")))
        XCTAssertTrue(try LaunchOptions.parse(["tm"], isDebugBuild: true).get().isAccountRun)
    }
}
