import Foundation

/// Every tmux call the app makes, as argument lists for one private server (`tmux -L <socket> -f <config>`).
/// Pure, so the tests check exactly what runs.
struct TmuxCommands: Equatable {
    static let defaultPath = "/opt/homebrew/bin/tmux"
    static let paneFormat = "#{session_name}\t#{pane_dead}\t#{pane_dead_status}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_pid}\t#{pane_tty}"

    var tmuxPath: String
    var socketName: String
    var configPath: String

    var base: [String] { [tmuxPath, "-L", socketName, "-f", configPath] }

    /// The exact session (`=` keeps tmux from matching a prefix of another name) and its active pane.
    static func sessionTarget(_ name: String) -> String { "=\(name)" }
    static func paneTarget(_ name: String) -> String { "=\(name):" }

    func newSession(name: String, dir: String, cols: Int, rows: Int, command: [String]) -> [String] {
        base + ["new-session", "-d", "-s", name, "-c", dir, "-x", String(cols), "-y", String(rows)] + command
    }

    /// Kills whatever runs in the pane and starts `command` in its place, in `dir`.
    func respawn(name: String, dir: String, command: [String]) -> [String] {
        base + ["respawn-pane", "-k", "-t", Self.paneTarget(name), "-c", dir] + command
    }

    func killSession(_ name: String) -> [String] {
        base + ["kill-session", "-t", Self.sessionTarget(name)]
    }

    func listPanes() -> [String] {
        base + ["list-panes", "-a", "-F", Self.paneFormat]
    }

    func listSessions() -> [String] {
        base + ["list-sessions", "-F", "#{session_name}"]
    }

    func attach(_ name: String) -> [String] {
        [tmuxPath, "-u", "-L", socketName, "-f", configPath, "attach-session", "-t", Self.sessionTarget(name)]
    }

    /// Key names as tmux reads them (`Enter`, `Escape`, `C-c`), never literal text.
    func sendKeys(_ name: String, keys: [String]) -> [String] {
        base + ["send-keys", "-t", Self.paneTarget(name)] + keys
    }

    /// Text from stdin into a named buffer, then pasted with bracketed paste when the program asked for
    /// it (`-p`) and the buffer deleted (`-d`).
    func loadBuffer(_ buffer: String) -> [String] {
        base + ["load-buffer", "-b", buffer, "-"]
    }

    func pasteBuffer(_ buffer: String, into name: String) -> [String] {
        base + ["paste-buffer", "-p", "-d", "-b", buffer, "-t", Self.paneTarget(name)]
    }

    func capturePane(_ name: String, lines: Int) -> [String] {
        base + ["capture-pane", "-p", "-J", "-t", Self.paneTarget(name), "-S", String(-lines)]
    }

    /// The app's own config: no status line, no escape delay, a long history, mouse on (wheel scrolls
    /// the history in copy mode), and exited programs stay visible with their exit code.
    static let configText = """
    set -g status off
    set -sg escape-time 0
    set -g history-limit 50000
    set -g default-terminal "xterm-256color"
    set -ga terminal-features ",xterm-256color:RGB"
    set -g remain-on-exit on
    set -g mouse on
    set -g focus-events on
    set -g window-size latest
    set -g aggressive-resize on
    set -g set-titles off
    set -g allow-rename off
    set -g automatic-rename off
    set -g bell-action none
    set -g visual-bell off
    set -g exit-empty off

    """
}

/// One pane of `list-panes -a`, parsed.
struct PaneInfo: Equatable {
    var sessionName: String
    var isDead: Bool
    var deadStatus: Int?
    var currentCommand: String
    var currentPath: String
    var pid: Int32
    var tty: String

    static func parse(_ output: String) -> [PaneInfo] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7, let pid = Int32(fields[5]) else { return nil }
            return PaneInfo(
                sessionName: fields[0], isDead: fields[1] == "1", deadStatus: Int(fields[2]),
                currentCommand: fields[3], currentPath: fields[4], pid: pid, tty: fields[6]
            )
        }
    }
}

struct ProcessResult {
    var status: Int32
    var output: String
    var errorOutput: String
    var isSuccess: Bool { status == 0 }
}

enum ProcessRunner {
    /// Runs `arguments` (the first is the executable) and waits; never through a shell.
    @discardableResult
    static func run(_ arguments: [String], input: Data? = nil, environment: [String: String]? = nil, timeout: TimeInterval = 10) -> ProcessResult {
        guard let executable = arguments.first else { return ProcessResult(status: -1, output: "", errorOutput: "no command") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        if let environment { process.environment = environment }
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, output: "", errorOutput: "\(error)")
        }
        if let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(5_000) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        group.wait()
        return ProcessResult(
            status: process.terminationStatus,
            output: String(decoding: outData, as: UTF8.self),
            errorOutput: String(decoding: errData, as: UTF8.self)
        )
    }
}
