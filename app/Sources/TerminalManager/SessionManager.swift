import Foundation
import HookWire

enum SessionError: String, Error {
    case notFound = "not-found"
    case badRequest = "bad-request"
    case notReady = "not-ready"
    case tmuxFailed = "tmux-failed"
    case noClaude = "no-claude"
    case folderFailed = "folder-failed"
    case answerInTerminal = "answer-in-terminal"
    case alreadyAnswered = "already-answered"
}

/// The sessions, on the main actor: sessions.json, tmux, the hooks, the feed. Everything the page and
/// the menu bar show comes from here; tmux calls run in order on one background queue.
@MainActor
final class SessionManager {
    static let pollInterval: TimeInterval = 1
    static let defaultCols = 160
    static let defaultRows = 45

    let paths: AppPaths
    let tmux: TmuxCommands
    let home: String
    let hooks: HookCenter
    private(set) var file: SessionsFile
    private(set) var settings: AppSettings
    private(set) var feed: FeedLog
    private(set) var runtime: [String: SessionRuntime] = [:]
    private(set) var login: LoginEnvironment?
    private(set) var isPluginReady = false
    private let tmuxQueue = DispatchQueue(label: "terminal-manager.tmux", qos: .userInitiated)
    private let pollQueue = DispatchQueue(label: "terminal-manager.poll", qos: .utility)
    private var pollTimer: Timer?
    private var isPolling = false
    private var pollCount = 0
    private var saveScheduled = false
    private var feedSaveScheduled = false
    private var changeScheduled = false

    /// The sessions changed (coalesced to one call per main-queue turn).
    var onChange: (() -> Void)?
    /// Feed events added or changed, and thinking markers removed.
    var onFeed: (([FeedEvent], [Int]) -> Void)?
    var onStatus: ((SessionRecord, SessionStatus, SessionStatus) -> Void)?
    var onToast: ((String) -> Void)?

    init(paths: AppPaths, tmuxPath: String = TmuxCommands.defaultPath, home: String = NSHomeDirectory()) {
        self.paths = paths
        self.home = home
        tmux = TmuxCommands(tmuxPath: tmuxPath, socketName: paths.tmuxSocketName, configPath: paths.tmuxConfig.path)
        hooks = HookCenter(socketPath: paths.socketPath)
        file = SessionsFile.load(from: paths.sessionsFile)
        settings = AppSettings.load(from: paths.settingsFile)
        feed = FeedLog.load(from: paths.feedFile)
        for record in file.sessions { runtime[record.id] = SessionRuntime() }
    }

    var sessions: [SessionRecord] { file.sessions }

    func record(_ id: String) -> SessionRecord? {
        file.sessions.first { $0.id == id }
    }

    // MARK: start

    /// Writes the tmux config and the plugin, starts the hook socket, reads the login environment, then
    /// reconciles with tmux: sessions come back as they were, and a Claude session whose tmux session is
    /// gone is resumed with its conversation.
    func start(executable: URL?, version: String) {
        do {
            try paths.prepare()
            try AtomicFile.write(Data(TmuxCommands.configText.utf8), to: paths.tmuxConfig.path, mode: 0o644)
        } catch {
            Log.error("could not prepare the app's folders: \(error)")
        }
        installPlugin(executable: executable, version: version)
        hooks.onEvent = { [weak self] event in self?.handleHook(event) }
        hooks.onHeldGone = { [weak self] item, reason in self?.heldGone(item, reason: reason) }
        if let problem = ClaudePlugin.socketPathProblem(paths.socketPath) {
            Log.error(problem)
        } else {
            do {
                try hooks.start()
            } catch {
                Log.error("the hook socket did not start: \(error); statuses come only from tmux")
            }
        }
        tmuxQueue.async { [weak self] in
            let environment = LoginEnvironment.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.login = environment
                    Log.info("login environment read: claude at \(environment.claudePath ?? "(not found)"), \(environment.variables.count) variables")
                    self.reconcile()
                }
            }
        }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        hooks.stop()
        saveNow()
    }

    private func installPlugin(executable: URL?, version: String) {
        guard let helper = ClaudePlugin.helperNextTo(executable: executable), let serverPath = executable?.resolvingSymlinksInPath().path else {
            Log.error("the hook helper is not next to the app's binary; Claude statuses come only from tmux")
            return
        }
        do {
            let written = try ClaudePlugin.install(in: paths.pluginFolder, helper: helper, socketPath: paths.socketPath, serverPath: serverPath, version: version)
            isPluginReady = true
            if !written.isEmpty { Log.info("plugin: wrote \(written.joined(separator: ", "))") }
        } catch {
            Log.error("could not write the Claude Code plugin: \(error)")
        }
    }

    private func reconcile() {
        let listing = tmuxQueue.syncResult { ProcessRunner.run(self.tmux.listSessions()) }
        let alive = Set(listing.isSuccess ? listing.output.split(separator: "\n").map(String.init) : [])
        for record in file.sessions where !alive.contains(record.tmuxName) {
            switch record.kind {
            case .claude:
                if record.claudeSessionID != nil, record.status != .exited {
                    Log.info("session \(record.id): its tmux session is gone; resuming the conversation")
                    launchClaude(record, isNew: false, prompt: nil)
                    update(record.id) { $0.status = .idle; $0.statusAt = Date(); $0.summary = "Resumed, waiting for a message"; $0.exitCode = nil }
                    note(record.id, type: "life") { $0.text = "Resumed after the terminal went away" }
                } else {
                    update(record.id) { $0.status = .exited; $0.summary = "Claude exited" }
                }
            case .shell:
                update(record.id) { $0.status = .exited; $0.summary = "The terminal went away"; $0.exitCode = nil }
            }
        }
        let known = Set(file.sessions.map(\.tmuxName))
        for name in alive where name.hasPrefix("tm-") && !known.contains(name) {
            let id = String(name.dropFirst(3))
            guard HookLine.isAppSessionID(id) else { continue }
            Log.info("adopting tmux session \(name) that sessions.json did not list")
            var record = SessionRecord(id: id, kind: .shell, name: "recovered", dir: home, created: Date())
            record.summary = ""
            file.sessions.append(record)
            runtime[id] = SessionRuntime()
        }
        scheduleSave()
        changed()
        poll()
    }

    // MARK: ops

    func create(kind: SessionKind, dir typed: String, prompt: String?, mode: PermissionMode, completion: @escaping (Result<String, SessionError>) -> Void) {
        guard let dir = DisplayPath.absolute(typed, home: home) else { return completion(.failure(.badRequest)) }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory) {
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            } catch {
                return completion(.failure(.folderFailed))
            }
        } else if !isDirectory.boolValue {
            return completion(.failure(.folderFailed))
        }
        guard login != nil else { return completion(.failure(.notReady)) }
        if kind == .claude, login?.claudePath == nil { return completion(.failure(.noClaude)) }
        var record = SessionRecord(id: SessionRecord.newID(), kind: kind, name: uniqueName((dir as NSString).lastPathComponent), dir: dir, created: Date())
        if kind == .shell { record.name = uniqueName("zsh") }
        if kind == .claude {
            record.mode = mode
            record.claudeSessionID = UUID().uuidString.lowercased()
            record.summary = "Waiting for your first message"
        }
        file.sessions.append(record)
        runtime[record.id] = SessionRuntime()
        settings.noteUsed(dir)
        saveSettings()
        if kind == .claude {
            launchClaude(record, isNew: true, prompt: prompt)
            note(record.id, type: "life") { $0.text = "Created a Claude session"; $0.detail = DisplayPath.tilde(dir, home: self.home) }
        } else {
            launchShell(record, respawn: false)
            note(record.id, type: "life") { $0.text = "Opened a terminal"; $0.detail = DisplayPath.tilde(dir, home: self.home) }
        }
        scheduleSave()
        changed()
        completion(.success(record.id))
    }

    func delete(_ id: String) -> Result<Void, SessionError> {
        guard let record = record(id) else { return .failure(.notFound) }
        hooks.release(sessionID: id, because: "its session was deleted")
        let kill = tmux.killSession(record.tmuxName)
        tmuxQueue.async { ProcessRunner.run(kill) }
        if record.kind == .claude, let claudeID = record.claudeSessionID, record.hasConversation {
            file.closed.insert(ClosedSession(
                id: record.id, name: record.name, dir: record.dir, mode: record.mode, claudeSessionID: claudeID,
                closedAt: Date(), lastLine: record.lastReply.map { ClaudeStatusReducer.clip(ClaudeStatusReducer.oneLine($0), to: 120) } ?? record.summary
            ), at: 0)
            if file.closed.count > SessionsFile.maxClosed { file.closed.removeLast(file.closed.count - SessionsFile.maxClosed) }
        }
        note(id, type: "life") { $0.text = "Deleted"; $0.flag = "needs" }
        file.sessions.removeAll { $0.id == id }
        runtime[id] = nil
        scheduleSave()
        changed()
        return .success(())
    }

    /// A closed Claude session back in the list, its conversation resumed in the same folder and mode.
    func resumeClosed(_ id: String) -> Result<String, SessionError> {
        guard let closed = file.closed.first(where: { $0.id == id }) else { return .failure(.notFound) }
        guard login?.claudePath != nil else { return .failure(.noClaude) }
        file.closed.removeAll { $0.id == id }
        var record = SessionRecord(id: SessionRecord.newID(), kind: .claude, name: uniqueName(closed.name), dir: closed.dir, created: Date())
        record.mode = closed.mode ?? .default
        record.claudeSessionID = closed.claudeSessionID
        record.hasConversation = true
        record.summary = "Resumed, waiting for a message"
        file.sessions.append(record)
        runtime[record.id] = SessionRuntime()
        launchClaude(record, isNew: false, prompt: nil)
        note(record.id, type: "life") { $0.text = "Resumed from Recently closed" }
        scheduleSave()
        changed()
        return .success(record.id)
    }

    func restart(_ id: String) -> Result<Void, SessionError> {
        guard let record = record(id) else { return .failure(.notFound) }
        hooks.release(sessionID: id, because: "its session was restarted")
        switch record.kind {
        case .claude:
            guard login?.claudePath != nil else { return .failure(.noClaude) }
            launchClaude(record, isNew: false, prompt: nil, respawn: true)
            update(id) { $0.exitCode = nil }
            applyClaude(id, .restarted)
        case .shell:
            launchShell(record, respawn: true)
            update(id) { $0.status = .idle; $0.statusAt = Date(); $0.exitCode = nil; $0.summary = "" }
        }
        runtime[id]?.files = []
        note(id, type: "life") { $0.text = "Restarted" }
        changed()
        return .success(())
    }

    /// Esc for a Claude session (interrupts its turn), ⌃C for a terminal's foreground job.
    func stopSession(_ id: String) -> Result<Void, SessionError> {
        guard let record = record(id) else { return .failure(.notFound) }
        let keys = record.kind == .claude ? ["Escape"] : ["C-c"]
        let command = tmux.sendKeys(record.tmuxName, keys: keys)
        tmuxQueue.async { ProcessRunner.run(command) }
        if record.kind == .shell, let job = runtime[id]?.foreground { note(id, type: "life") { $0.text = "Stopped \(job)" } }
        return .success(())
    }

    /// The composer's text typed into the session as a paste, then Enter, so it behaves like typing in the TUI.
    func send(_ id: String, text: String) -> Result<Void, SessionError> {
        guard let record = record(id) else { return .failure(.notFound) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100_000 else { return .failure(.badRequest) }
        let buffer = "tm-send-\(record.id)"
        let load = tmux.loadBuffer(buffer)
        let paste = tmux.pasteBuffer(buffer, into: record.tmuxName)
        let enter = tmux.sendKeys(record.tmuxName, keys: ["Enter"])
        tmuxQueue.async {
            guard ProcessRunner.run(load, input: Data(trimmed.utf8)).isSuccess else { return }
            ProcessRunner.run(paste)
            // Claude Code takes an Enter that lands in the same read as the paste as part of the paste.
            usleep(150_000)
            ProcessRunner.run(enter)
        }
        runtime[id]?.interacted = true
        if record.kind == .claude, record.status == .ready || record.status == .reviewed { update(id) { $0.hasError = false } }
        return .success(())
    }

    func answer(_ id: String, answer: AskAnswer, completion: @escaping (Result<Void, SessionError>) -> Void) {
        guard record(id) != nil else { return completion(.failure(.notFound)) }
        guard let held = hooks.oldest(for: id) else { return completion(.failure(.answerInTerminal)) }
        guard let built = HookAnswer.output(for: held.ask, answer: answer) else { return completion(.failure(.badRequest)) }
        hooks.answer(held.id, output: built.output) { [weak self] isDelivered in
            guard let self else { return }
            guard isDelivered else {
                self.stampAsk(held, with: "Answered in the terminal")
                self.afterAsk(id)
                return completion(.failure(.alreadyAnswered))
            }
            self.stampAsk(held, with: built.stamp)
            self.runtime[id]?.interacted = true
            self.note(id, type: "you") {
                $0.verb = held.ask.kind == .permission ? "chose" : "answered"
                $0.text = built.stamp.hasPrefix("Answered: ") ? String(built.stamp.dropFirst(10)) : built.stamp
            }
            self.afterAsk(id)
            completion(.success(()))
        }
    }

    func review(_ id: String) -> Result<Void, SessionError> {
        guard record(id)?.status == .ready else { return .failure(.badRequest) }
        applyClaude(id, .reviewed)
        note(id, type: "you") { $0.verb = "marked the turn reviewed"; $0.text = "" }
        return .success(())
    }

    func rename(_ id: String, to name: String) -> Result<Void, SessionError> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let record = record(id), !trimmed.isEmpty, trimmed.count <= 80 else { return .failure(.badRequest) }
        guard trimmed != record.name else { return .success(()) }
        update(id) { $0.name = trimmed }
        feed.rename(sid: id, to: trimmed)
        note(id, type: "life") { $0.text = "Renamed from \(record.name)" }
        changed()
        return .success(())
    }

    func setMuted(_ id: String, _ muted: Bool) -> Result<Void, SessionError> {
        guard record(id) != nil else { return .failure(.notFound) }
        update(id) { $0.muted = muted }
        changed()
        return .success(())
    }

    /// The mode a Claude session gets at its next restart (Restart keeps the conversation).
    func setMode(_ id: String, _ mode: PermissionMode) -> Result<Void, SessionError> {
        guard record(id)?.kind == .claude else { return .failure(.badRequest) }
        update(id) { $0.mode = mode }
        note(id, type: "life") { $0.text = "Permission mode set to \(mode.label) (applies at the next restart)" }
        changed()
        return .success(())
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        settings.notificationsEnabled = enabled
        saveSettings()
        changed()
    }

    func setDoNotDisturb(_ on: Bool) {
        settings.doNotDisturb = on
        saveSettings()
        changed()
    }

    func markOpenAtLoginSetUp() {
        settings.hasSetUpOpenAtLogin = true
        saveSettings()
    }

    var folderSuggestions: [String] {
        let existing = settings.recentDirs.filter { FileManager.default.fileExists(atPath: $0) }
        return FolderSuggestions.list(recent: existing, workFolder: home + "/work")
    }

    var closedSessions: [ClosedSession] { file.closed }

    // MARK: launching

    private func claudeCommand(_ record: SessionRecord, isNew: Bool, prompt: String?) -> [String]? {
        guard let login, let claudePath = login.claudePath, let claudeID = record.claudeSessionID else { return nil }
        let environment = SessionLaunch.environment(login: login.variables, appSession: record.id, pluginFolder: isPluginReady ? paths.pluginFolder.path : nil)
        let program = SessionLaunch.claudeArguments(claudePath: claudePath, mode: record.mode ?? .default, claudeSessionID: claudeID, isResume: !isNew, prompt: prompt)
        return SessionLaunch.command(environment: environment, program: program)
    }

    private func launchClaude(_ record: SessionRecord, isNew: Bool, prompt: String?, respawn: Bool = false) {
        var launching = record
        // A conversation that never got a turn has no transcript to resume: it starts again under a new id.
        if !isNew, !record.hasConversation {
            launching.claudeSessionID = UUID().uuidString.lowercased()
            update(record.id) { $0.claudeSessionID = launching.claudeSessionID }
        }
        guard let command = claudeCommand(launching, isNew: isNew || !record.hasConversation, prompt: prompt) else {
            onToast?("Claude Code was not found on this Mac's login PATH")
            return
        }
        let arguments = respawn
            ? tmux.respawn(name: record.tmuxName, dir: record.dir, command: command)
            : tmux.newSession(name: record.tmuxName, dir: record.dir, cols: Self.defaultCols, rows: Self.defaultRows, command: command)
        let fallback = tmux.newSession(name: record.tmuxName, dir: record.dir, cols: Self.defaultCols, rows: Self.defaultRows, command: command)
        runTmux(arguments, fallback: respawn ? fallback : nil, for: record.id)
        runtime[record.id]?.follower = nil
        runtime[record.id]?.claudePID = nil
    }

    private func launchShell(_ record: SessionRecord, respawn: Bool) {
        let environment = SessionLaunch.environment(login: login?.variables ?? [:], appSession: record.id, pluginFolder: nil)
        let command = SessionLaunch.command(environment: environment, program: SessionLaunch.shellArguments())
        let create = tmux.newSession(name: record.tmuxName, dir: record.dir, cols: Self.defaultCols, rows: Self.defaultRows, command: command)
        runTmux(respawn ? tmux.respawn(name: record.tmuxName, dir: record.dir, command: command) : create, fallback: respawn ? create : nil, for: record.id)
    }

    /// Runs in order with every other tmux call; a respawn whose session is gone creates it instead.
    private func runTmux(_ arguments: [String], fallback: [String]?, for id: String) {
        tmuxQueue.async { [weak self] in
            var result = ProcessRunner.run(arguments)
            if !result.isSuccess, let fallback { result = ProcessRunner.run(fallback) }
            guard !result.isSuccess else { return }
            let message = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Log.error("tmux failed for session \(id): \(message)")
                    self?.onToast?("tmux could not start the session: \(message)")
                }
            }
        }
    }

    /// A tmux attach for the page's terminal; nil when the session is unknown.
    func attachArguments(_ id: String) -> (arguments: [String], environment: [String: String])? {
        guard let record = record(id) else { return nil }
        let environment = [
            "TERM": "xterm-256color", "LANG": "en_US.UTF-8", "LC_CTYPE": "en_US.UTF-8", "HOME": home,
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "USER": NSUserName(), "COLORTERM": "truecolor",
        ]
        return (tmux.attach(record.tmuxName), environment)
    }

    /// Waits for every tmux call queued so far (the page attaches only once its session exists).
    func afterQueuedTmux(_ work: @escaping @MainActor () -> Void) {
        tmuxQueue.async {
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }
    }

    // MARK: hooks

    private func handleHook(_ event: HookEvent) {
        let candidates = file.sessions.filter { $0.kind == .claude }.map {
            HookRouter.Candidate(id: $0.id, claudeSessionID: $0.claudeSessionID, claudePID: runtime[$0.id]?.claudePID, dir: $0.dir)
        }
        guard let id = HookRouter.route(appSession: event.appSession, claudeSessionID: event.claudeSessionID, claudePID: event.claudePID, cwd: event.cwd, candidates: candidates),
              let record = record(id) else {
            if let connection = event.connection { hooks.pass(connection) }
            return
        }
        runtime[id]?.claudePID = event.claudePID
        runtime[id]?.lastHookAt = Date()
        runtime[id]?.idleReads = 0
        if let claudeID = event.claudeSessionID, claudeID != record.claudeSessionID, !event.isAgent {
            update(id) { $0.claudeSessionID = claudeID }
        }
        if let path = event.transcriptPath, runtime[id]?.follower?.path != path, !event.isAgent {
            update(id) { $0.transcriptPath = path }
            runtime[id]?.follower = TranscriptFollower(path: path, offset: event.event == "SessionStart" ? 0 : TranscriptFollower.atEnd(of: path).offset)
        }
        if let raw = event.permissionMode, let mode = PermissionMode(hookValue: raw), !event.isAgent, mode != record.mode {
            update(id) { $0.mode = mode }
        }
        let cwd = event.cwd ?? record.dir
        switch event.event {
        case "SessionStart":
            applyClaude(id, .sessionStarted(source: event.source))
        case "UserPromptSubmit":
            hooks.release(sessionID: id, because: "a new prompt came in")
            update(id) { $0.hasConversation = true; $0.hasError = false }
            runtime[id]?.turnFiles = []
            runtime[id]?.files = []
            applyClaude(id, .promptSubmitted(event.prompt))
            note(id, type: "you") { $0.verb = "sent"; $0.text = event.prompt.map { ClaudeStatusReducer.clip(ClaudeStatusReducer.oneLine($0), to: 300) } ?? "" }
        case "PreToolUse":
            guard let tool = event.tool, !event.isAgent else { break }
            if tool == AskRequest.questionTool {
                if !hooks.hasHeld(id) { applyClaude(id, .questionAsked) }
                break
            }
            let subject = ToolSubject.describe(tool: tool, input: event.toolInput, cwd: cwd)
            applyClaude(id, .toolStarted(summary: ToolSubject.doingSummary(tool: tool, subject: subject)))
            if tool != "TodoWrite" {
                note(id, type: "tool") { $0.tool = tool; $0.args = FeedText.toolArgs(tool: tool, input: event.toolInput, cwd: cwd) }
            }
        case HookLine.permissionRequest:
            permissionRequested(event, id: id)
        case "PermissionDenied":
            note(id, type: "life") { $0.text = "Auto mode blocked \(event.tool ?? "a tool")"; $0.flag = "needs" }
        case "PostToolUse", "PostToolUseFailure":
            if let tool = event.tool {
                hooks.toolFinished(sessionID: id, tool: tool, input: event.toolInput)
                if !event.isAgent, let change = GitChanges.toolChange(tool: tool, input: event.toolInput, cwd: cwd) {
                    GitChanges.merge(change, into: &runtime[id, default: SessionRuntime()].turnFiles)
                }
            }
            if !event.isAgent { applyClaude(id, .toolEnded(hasPendingAsk: hooks.hasHeld(id))) }
        case "Notification":
            if event.notificationType == "permission_prompt", !hooks.hasHeld(id) { applyClaude(id, .permissionPrompt) }
        case "Stop":
            guard !event.isAgent else { break }
            hooks.release(sessionID: id, because: "the turn ended")
            readTranscript(id)
            if let reply = event.lastReply, !reply.isEmpty { update(id) { $0.lastReply = reply } }
            applyClaude(id, .stopped(lastReply: event.lastReply ?? self.record(id)?.lastReply, stopHookActive: event.stopHookActive))
            if !event.stopHookActive { turnEnded(id, dir: record.dir) }
        case "StopFailure":
            hooks.release(sessionID: id, because: "the turn failed")
            applyClaude(id, .stopFailed)
            note(id, type: "life") { $0.text = "Failed: the API returned an error"; $0.flag = "needs" }
            turnEnded(id, dir: record.dir)
        case "SessionEnd":
            hooks.release(sessionID: id, because: "its session ended")
            if event.reason != "clear" { note(id, type: "life") { $0.text = "Claude exited" } }
            applyClaude(id, .sessionEnded(reason: event.reason))
        default:
            break
        }
        readTranscript(id)
        changed()
    }

    private func permissionRequested(_ event: HookEvent, id: String) {
        guard let ask = event.ask else {
            if let connection = event.connection { hooks.pass(connection) }
            applyClaude(id, .permissionPrompt)
            return
        }
        var item: HeldAsk?
        if let connection = event.connection, !event.isAgent {
            item = hooks.hold(ask, connection: connection, sessionID: id)
        }
        let seq = note(id, type: ask.kind == .permission ? "perm" : "ask") { $0.text = ask.text }
        if let item, let seq { hooks.setFeedSeq(seq, for: item.id) }
        if hooks.oldest(for: id)?.id == item?.id { runtime[id]?.askSeq = seq }
        applyClaude(id, ask.kind == .permission ? .permissionRequested(summary: ask.summary) : .questionAsked)
    }

    private func heldGone(_ item: HeldAsk, reason: String) {
        stampAsk(item, with: reason == "answered in the terminal" ? "Answered in the terminal" : nil)
        afterAsk(item.sessionID)
        changed()
    }

    private func stampAsk(_ item: HeldAsk, with stamp: String?) {
        guard let seq = item.feedSeq, let stamp, let event = feed.update(seq: seq, { $0.answer = stamp }) else { return }
        onFeed?([event], [])
        scheduleFeedSave()
    }

    /// After an ask went: the next held one shows, or the session works on.
    private func afterAsk(_ id: String) {
        if let next = hooks.oldest(for: id) {
            runtime[id]?.askSeq = next.feedSeq
        } else {
            runtime[id]?.askSeq = nil
            applyClaude(id, .answered)
        }
        changed()
    }

    private func turnEnded(_ id: String, dir: String) {
        let seq = note(id, type: "done")
        runtime[id]?.lastDone = seq
        let touched = runtime[id]?.turnFiles ?? []
        pollQueue.async { [weak self] in
            let changes = GitChanges.changes(in: dir)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.runtime[id] != nil else { return }
                    self.runtime[id]?.files = changes ?? touched
                    self.changed()
                }
            }
        }
    }

    private func readTranscript(_ id: String) {
        guard var follower = runtime[id]?.follower else { return }
        let update = follower.readNew()
        runtime[id]?.follower = follower
        if let model = update.model { runtime[id]?.model = model }
        for reply in update.replies {
            note(id, type: "say") { $0.text = reply }
            self.update(id) { $0.lastReply = reply }
        }
        if let tokens = update.contextTokens {
            let percent = TranscriptParser.contextPercent(tokens: tokens, model: runtime[id]?.model)
            self.update(id) { $0.context = percent }
        }
    }

    // MARK: status

    private func applyClaude(_ id: String, _ signal: ClaudeSignal) {
        guard let record = record(id), record.kind == .claude else { return }
        let before = ClaudeActivity(status: record.status, statusAt: record.statusAt, summary: record.summary, hasError: record.hasError)
        let after = ClaudeStatusReducer.reduce(before, signal, now: Date())
        guard after != before else { return }
        update(id) {
            $0.status = after.status
            $0.statusAt = after.statusAt
            $0.summary = after.summary
            $0.hasError = after.hasError
        }
        if after.status != before.status { statusMoved(id, from: before.status, to: after.status) }
    }

    private func setShellStatus(_ id: String, _ status: SessionStatus, summary: String, exitCode: Int? = nil) {
        guard let record = record(id), record.status != status || record.exitCode != exitCode else { return }
        let from = record.status
        update(id) {
            $0.status = status
            $0.summary = summary
            $0.exitCode = exitCode
            if from != status { $0.statusAt = Date() }
        }
        if from != status { statusMoved(id, from: from, to: status) }
    }

    private func statusMoved(_ id: String, from: SessionStatus, to: SessionStatus) {
        if from == .working {
            let gone = feed.removeThinking(sid: id)
            if !gone.isEmpty { onFeed?([], gone) }
        }
        if to == .working, !feed.hasThinking(sid: id) { note(id, type: "think") }
        if let record = record(id) { onStatus?(record, from, to) }
    }

    // MARK: polling

    private func poll() {
        guard login != nil, !isPolling else { return }
        isPolling = true
        pollCount += 1
        let listPanes = tmux.listPanes()
        let shells = file.sessions.filter { $0.kind == .shell }.map(\.tmuxName)
        let wantsLines = pollCount % 2 == 0
        let capture = { (name: String) in self.tmux.capturePane(name, lines: 30) }
        let busyClaude = file.sessions.filter { $0.kind == .claude && ($0.status == .working || $0.status == .needsYou) }
            .compactMap { record -> (String, pid_t)? in self.runtime[record.id]?.claudePID.map { (record.id, $0) } }
        pollQueue.async { [weak self] in
            let result = ProcessRunner.run(listPanes, timeout: 5)
            let panes = result.isSuccess ? PaneInfo.parse(result.output) : []
            var lines: [String: String] = [:]
            var foreground: [String: String] = [:]
            for pane in panes where shells.contains(pane.sessionName) {
                if wantsLines {
                    let text = ProcessRunner.run(capture(pane.sessionName), timeout: 3).output
                    if let last = text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        lines[pane.sessionName] = String(last)
                    }
                }
                if !pane.isDead, !ForegroundJob.isShell(pane.currentCommand) {
                    let tty = (pane.tty as NSString).lastPathComponent
                    let ps = ProcessRunner.run(["/bin/ps", "-t", tty, "-o", "pid=,pgid=,tpgid=,args="], timeout: 3)
                    foreground[pane.sessionName] = ForegroundJob.parse(ps.output, shellPID: pane.pid) ?? pane.currentCommand
                }
            }
            let registry = busyClaude.map { ($0.0, ClaudeRegistry.status(pid: $0.1)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isPolling = false
                    if result.isSuccess || result.errorOutput.contains("no server running") || result.errorOutput.contains("error connecting") {
                        self.applyPanes(panes, lines: lines, foreground: foreground)
                    }
                    self.applyRegistry(registry)
                }
            }
        }
    }

    private func applyPanes(_ panes: [PaneInfo], lines: [String: String], foreground: [String: String]) {
        let byName = Dictionary(panes.map { ($0.sessionName, $0) }, uniquingKeysWith: { first, _ in first })
        for record in file.sessions {
            let id = record.id
            guard let pane = byName[record.tmuxName] else {
                if record.status != .exited {
                    if record.kind == .claude { applyClaude(id, .processExited) } else { setShellStatus(id, .exited, summary: "The terminal went away") }
                }
                continue
            }
            let previous = runtime[id]?.pane
            runtime[id]?.pane = pane
            runtime[id]?.shownCwd = pane.currentPath.isEmpty ? nil : pane.currentPath
            if let line = lines[record.tmuxName] { runtime[id]?.lastLine = line }
            switch record.kind {
            case .claude:
                if !pane.isDead, runtime[id]?.claudePID == nil { runtime[id]?.claudePID = pane.pid }
                if pane.isDead, record.status != .exited {
                    hooks.release(sessionID: id, because: "its process exited")
                    update(id) { $0.exitCode = pane.deadStatus }
                    applyClaude(id, .processExited)
                    note(id, type: "life") { $0.text = "Claude exited"; $0.detail = pane.deadStatus.map { "code \($0)" } }
                }
            case .shell:
                if pane.isDead {
                    if record.status != .exited {
                        setShellStatus(id, .exited, summary: "code \(pane.deadStatus ?? 0)", exitCode: pane.deadStatus ?? 0)
                        note(id, type: "exit") { $0.code = pane.deadStatus ?? 0 }
                    }
                    runtime[id]?.foreground = nil
                } else if let job = foreground[record.tmuxName] {
                    if runtime[id]?.foreground != job {
                        runtime[id]?.foreground = job
                        note(id, type: "cmd") { $0.text = job }
                    }
                    setShellStatus(id, .process, summary: job)
                } else {
                    if let job = runtime[id]?.foreground, previous != nil { note(id, type: "life") { $0.text = "Finished \(job)" } }
                    runtime[id]?.foreground = nil
                    setShellStatus(id, .idle, summary: "")
                }
            }
        }
        changed()
    }

    /// An interrupt (Esc in the terminal or from Stop) fires no hook: the registry showing the session at
    /// its prompt for two reads in a row, 3 s after the last hook, ends the turn.
    private func applyRegistry(_ statuses: [(String, String?)]) {
        for (id, status) in statuses {
            guard let record = record(id), record.status == .working || record.status == .needsYou, !hooks.hasHeld(id) else { continue }
            let sinceHook = runtime[id]?.lastHookAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if status == "idle", sinceHook > 3 {
                runtime[id]?.idleReads += 1
                if (runtime[id]?.idleReads ?? 0) >= 2 {
                    runtime[id]?.idleReads = 0
                    applyClaude(id, .wentIdle)
                    note(id, type: "life") { $0.text = "Interrupted"; $0.flag = "needs" }
                    changed()
                }
            } else {
                runtime[id]?.idleReads = 0
            }
        }
    }

    // MARK: records and saving

    private func update(_ id: String, _ change: (inout SessionRecord) -> Void) {
        guard let index = file.sessions.firstIndex(where: { $0.id == id }) else { return }
        let before = file.sessions[index]
        change(&file.sessions[index])
        if file.sessions[index] != before { scheduleSave() }
    }

    @discardableResult
    private func note(_ id: String, type: String, _ fill: (inout FeedEvent) -> Void = { _ in }) -> Int? {
        guard let record = record(id) else { return nil }
        let event = feed.append(sid: id, sname: record.name, type: type, fill)
        onFeed?([event], [])
        if type != "think" { scheduleFeedSave() }
        return event.seq
    }

    private func uniqueName(_ name: String) -> String {
        var candidate = name.isEmpty ? "session" : name
        var counter = 2
        while file.sessions.contains(where: { $0.name == candidate }) {
            candidate = "\(name) \(counter)"
            counter += 1
        }
        return candidate
    }

    private func changed() {
        guard !changeScheduled else { return }
        changeScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.changeScheduled = false
                self.onChange?()
            }
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.saveScheduled = false
                self?.saveSessions()
            }
        }
    }

    private func scheduleFeedSave() {
        guard !feedSaveScheduled else { return }
        feedSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                self?.feedSaveScheduled = false
                self?.saveFeed()
            }
        }
    }

    private func saveSessions() {
        do { try file.save(to: paths.sessionsFile) } catch { Log.error("could not save sessions.json: \(error)") }
    }

    private func saveFeed() {
        do { try feed.save(to: paths.feedFile) } catch { Log.error("could not save feed.json: \(error)") }
    }

    private func saveSettings() {
        do { try settings.save(to: paths.settingsFile) } catch { Log.error("could not save settings.json: \(error)") }
    }

    func saveNow() {
        saveSessions()
        saveFeed()
        saveSettings()
    }

    // MARK: what the page and the menu show

    func bridgeSessions() -> [[String: Any]] {
        file.sessions.map { SessionView.object($0, runtime[$0.id] ?? SessionRuntime(), held: hooks.oldest(for: $0.id), home: home) }
    }

    func bridgeClosed() -> [[String: Any]] {
        file.closed.map {
            ["id": $0.id, "kind": "claude", "name": $0.name, "dir": DisplayPath.tilde($0.dir, home: home), "closedAt": NSNumber(value: $0.closedAt.millis), "lastLine": $0.lastLine]
        }
    }

    var needsYouCount: Int { file.sessions.filter { $0.status == .needsYou }.count }
    var readyCount: Int { file.sessions.filter { $0.status == .ready }.count }
}

/// Claude Code's own registry, `~/.claude/sessions/<pid>.json`, read only: its `status` is busy, waiting or idle.
enum ClaudeRegistry {
    static func status(pid: pid_t, configFolder: String = NSHomeDirectory() + "/.claude") -> String? {
        guard pid > 1, let data = try? Data(contentsOf: URL(fileURLWithPath: "\(configFolder)/sessions/\(pid).json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return BridgeValue.string(object["status"])
    }
}

extension DispatchQueue {
    /// Runs `work` on this queue and waits for it (never from this queue itself).
    func syncResult<T>(_ work: () -> T) -> T {
        sync(execute: work)
    }
}
