import Foundation

/// What a login shell knows that the app (started by launchd) does not: the PATH, where `claude` lives
/// and the rest of the login environment. Read once at launch through `zsh -lic` with an emptied
/// environment, so nothing of the process that started the app leaks into sessions.
struct LoginEnvironment: Equatable {
    var claudePath: String?
    var variables: [String: String]

    static let beginMarker = "__TM_ENV_BEGIN__"
    static let endMarker = "__TM_ENV_END__"
    static let claudeMarker = "__TM_CLAUDE__"

    static func read(home: String = NSHomeDirectory(), user: String = NSUserName()) -> LoginEnvironment {
        let script = "printf '\\n\(claudeMarker)%s\\n' \"$(command -v claude)\"; printf '\(beginMarker)'; env -0; printf '\(endMarker)'"
        let seed = ["HOME": home, "USER": user, "LOGNAME": user, "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color"]
        let result = ProcessRunner.run(["/usr/bin/env", "-i"] + seed.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } + ["/bin/zsh", "-lic", script], timeout: 20)
        var parsed = parse(result.output)
        if parsed.variables["PATH"] == nil {
            Log.warn("the login shell gave no environment (status \(result.status)); sessions get a default PATH")
            parsed.variables = seed
            parsed.variables["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        if parsed.claudePath == nil {
            let fallback = "\(home)/.local/bin/claude"
            if FileManager.default.isExecutableFile(atPath: fallback) { parsed.claudePath = fallback }
        }
        return parsed
    }

    static func parse(_ output: String) -> LoginEnvironment {
        var claudePath: String?
        if let range = output.range(of: claudeMarker) {
            let rest = output[range.upperBound...]
            let line = rest.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("/") { claudePath = line }
        }
        var variables: [String: String] = [:]
        if let begin = output.range(of: beginMarker), let end = output.range(of: endMarker, range: begin.upperBound..<output.endIndex) {
            for entry in output[begin.upperBound..<end.lowerBound].split(separator: "\0") {
                guard let equals = entry.firstIndex(of: "=") else { continue }
                let key = String(entry[..<equals])
                guard !key.isEmpty, !key.contains("\n") else { continue }
                variables[key] = String(entry[entry.index(after: equals)...])
            }
        }
        return LoginEnvironment(claudePath: claudePath, variables: variables)
    }
}

/// How each session's process is started inside tmux: an explicit argv run through `/usr/bin/env -i`,
/// never through zsh, so the only plugin a Claude session loads is the app's own (a shell profile may add another
/// one to CLAUDE_CODE_PLUGIN_DIRS in every zsh).
enum SessionLaunch {
    static let pluginDirsVariable = "CLAUDE_CODE_PLUGIN_DIRS"
    static let sessionVariable = "TERMINAL_MANAGER_SESSION"
    static let shellPath = "/bin/zsh"

    /// Left out of every session: what belongs to the terminal or Claude process that started the app.
    static let droppedVariables: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CLAUDE_CODE_EXECPATH", "CLAUDE_PROJECT_DIR",
        "TMUX", "TMUX_PANE", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "ITERM_SESSION_ID", "ITERM_PROFILE",
        "LC_TERMINAL", "LC_TERMINAL_VERSION", "COLORTERM", "COLUMNS", "LINES", "SHLVL", "PWD", "OLDPWD", "_",
        "__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "VSCODE_INJECTION", "VSCODE_GIT_IPC_HANDLE",
        pluginDirsVariable, sessionVariable,
    ]

    static func environment(login: [String: String], appSession: String, pluginFolder: String?) -> [String: String] {
        var variables = login.filter { !droppedVariables.contains($0.key) && !$0.key.hasPrefix("VSCODE_") && !$0.key.hasPrefix("CLAUDE_CODE_SESSION") }
        variables["TERM"] = "xterm-256color"
        variables["COLORTERM"] = "truecolor"
        if variables["LANG"] == nil { variables["LANG"] = "en_US.UTF-8" }
        variables[sessionVariable] = appSession
        if let pluginFolder { variables[pluginDirsVariable] = pluginFolder }
        return variables
    }

    /// `claude --permission-mode <mode>` plus either `--session-id <uuid>` (new) or `--resume <uuid>`, and
    /// the first prompt as the last argument.
    static func claudeArguments(claudePath: String, mode: PermissionMode, claudeSessionID: String, isResume: Bool, prompt: String?) -> [String] {
        var arguments = [claudePath, "--permission-mode", mode.rawValue]
        arguments += isResume ? ["--resume", claudeSessionID] : ["--session-id", claudeSessionID]
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isResume {
            arguments.append(prompt)
        }
        return arguments
    }

    static func shellArguments() -> [String] {
        [shellPath, "-l"]
    }

    /// The argv tmux runs: `/usr/bin/env -i K=V … program args`. Sorted keys keep it stable for tests.
    static func command(environment: [String: String], program: [String]) -> [String] {
        ["/usr/bin/env", "-i"] + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } + program
    }
}
