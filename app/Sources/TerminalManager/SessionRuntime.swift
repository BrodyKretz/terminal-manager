import Foundation

/// What the app knows about a session while it runs, beyond sessions.json: its pane, the claude process,
/// the transcript it follows, what this turn changed and what the page shows of it.
struct SessionRuntime {
    var pane: PaneInfo?
    var claudePID: pid_t?
    var follower: TranscriptFollower?
    var model: String?
    var turnFiles: [FileChange] = []
    var askSeq: Int?
    var lastDone: Int?
    var lastLine: String?
    var foreground: String?
    var lastHookAt: Date?
    /// When tmux was last asked to start or respawn it: a poll taken before that may not show it yet.
    var launchedAt: Date?
    /// Consecutive registry reads that found the session at its prompt while it looked busy.
    var idleReads = 0
    var interacted = false
    var shownCwd: String?
}

/// The page's view of a session (the prototype's session shape).
enum SessionView {
    static func object(_ record: SessionRecord, _ runtime: SessionRuntime, held: HeldAsk?, home: String) -> [String: Any] {
        var object: [String: Any] = [
            "id": record.id,
            "kind": record.kind.rawValue,
            "name": record.name,
            "dir": DisplayPath.tilde(record.dir, home: home),
            "path": record.dir,
            "cwd": DisplayPath.tilde(runtime.shownCwd ?? record.dir, home: home),
            "status": record.status.rawValue,
            "statusAt": NSNumber(value: record.statusAt.millis),
            "startedAt": NSNumber(value: record.created.millis),
            "summary": record.summary,
            "failed": record.hasError,
            "muted": record.muted,
            "host": "app",
            "files": record.files.map(\.bridgeObject),
            "interacted": runtime.interacted,
            "canResume": record.kind == .claude && record.claudeSessionID != nil && record.hasConversation,
        ]
        if let mode = record.mode { object["mode"] = mode.label }
        if let context = record.context { object["context"] = context }
        if let exitCode = record.exitCode { object["exitCode"] = exitCode }
        if let reply = record.lastReply { object["lastReply"] = reply }
        if let line = runtime.lastLine { object["lastLine"] = line }
        if let command = runtime.foreground { object["command"] = command }
        if let seq = runtime.askSeq { object["askSeq"] = seq }
        if let seq = runtime.lastDone { object["lastDone"] = seq }
        if record.status == .needsYou {
            if let held {
                object["ask"] = askObject(held)
            } else {
                object["ask"] = [
                    "type": "permission", "text": "Claude is waiting for you in the terminal", "heading": "Claude is waiting for you", "detail": "",
                    "options": [String](), "answerable": false, "compact": false, "reason": "Answer this one in the terminal",
                ]
            }
        }
        return object
    }

    static func askObject(_ held: HeldAsk) -> [String: Any] {
        [
            "id": held.id,
            "type": held.ask.kind.rawValue,
            "text": held.ask.text,
            "heading": held.ask.heading,
            "detail": held.ask.detail,
            "options": held.ask.isAnswerable ? held.ask.options : [String](),
            "tool": held.ask.tool,
            "answerable": held.ask.isAnswerable,
            "compact": held.ask.fitsCompact,
            "reason": held.ask.terminalReason ?? "",
        ]
    }
}

/// When a session that needs you earns a macOS banner: only for needs-you, only while the window is not
/// key, and never with banners off, Do not disturb on or the session's bell muted.
enum BannerRule {
    static func shouldBanner(to status: SessionStatus, isWindowKey: Bool, notificationsEnabled: Bool, doNotDisturb: Bool, isMuted: Bool) -> Bool {
        status == .needsYou && !isWindowKey && notificationsEnabled && !doNotDisturb && !isMuted
    }
}

/// The shell's foreground job, from `ps -t <tty> -o pgid=,tpgid=,args=`: the process group the terminal
/// gives the keyboard to, when it is not the shell itself.
enum ForegroundJob {
    static func parse(_ output: String, shellPID: pid_t) -> String? {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]), let group = Int32(fields[1]), let terminalGroup = Int32(fields[2]) else { continue }
            if group == terminalGroup, pid == group, pid != shellPID { return String(fields[3]) }
        }
        return nil
    }

    static func isShell(_ command: String) -> Bool {
        ["zsh", "-zsh", "bash", "-bash", "sh", "login"].contains(command)
    }
}
