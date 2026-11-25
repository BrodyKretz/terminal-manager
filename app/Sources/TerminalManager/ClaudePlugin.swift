import Darwin
import Foundation
import HookWire

/// The app's Claude Code plugin, which CLAUDE_CODE_PLUGIN_DIRS loads in every session the app starts:
/// `.claude-plugin/plugin.json`, `hooks/hooks.json` running the helper for each event, and a copy of the
/// helper. Written at launch, only where a file's bytes would change.
enum ClaudePlugin {
    static let name = "terminal-manager"
    static let description = "Session status and permission answers for Terminal Manager"
    static let helperName = "terminal-manager-hook"
    static let pluginManifest = ".claude-plugin/plugin.json"
    static let hooksFile = "hooks/hooks.json"
    static let helperFile = "bin/\(helperName)"
    /// The events and whether each takes a matcher: the tool events do.
    static let events: [(name: String, hasMatcher: Bool)] = [
        ("SessionStart", false), ("UserPromptSubmit", false), ("PreToolUse", true), ("PermissionRequest", true), ("PermissionDenied", true),
        ("PostToolUse", true), ("PostToolUseFailure", true), ("Notification", false), ("Stop", false), ("StopFailure", false), ("SessionEnd", false),
    ]
    static let permissionTimeout = 600
    static let forwardTimeout = 5

    /// `"${CLAUDE_PLUGIN_ROOT}/bin/terminal-manager-hook" --socket "<path>" --server "<app>" <Event>`, run by a
    /// shell. `--server` is the running app's executable: the helper answers to nothing else.
    static func command(event: String, socketPath: String, serverPath: String) -> String {
        "\"${CLAUDE_PLUGIN_ROOT}/bin/\(helperName)\" --socket \"\(shellDoubleQuoted(socketPath))\" --server \"\(shellDoubleQuoted(serverPath))\" \(event)"
    }

    static func socketPathProblem(_ socketPath: String) -> String? {
        let length = socketPath.utf8.count
        guard length > HookSocket.maxPathBytes else { return nil }
        return "the hook socket's path is \(length) bytes, more than the \(HookSocket.maxPathBytes) a Unix socket takes (\(socketPath))"
    }

    /// The inside of a double-quoted shell word: backslash, quote, dollar and backtick escaped.
    static func shellDoubleQuoted(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\\"$`".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    static func hooksObject(socketPath: String, serverPath: String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in events {
            let timeout = event.name == HookLine.permissionRequest ? permissionTimeout : forwardTimeout
            let command = command(event: event.name, socketPath: socketPath, serverPath: serverPath)
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": timeout]]]
            if event.hasMatcher { group["matcher"] = "*" }
            hooks[event.name] = [group]
        }
        return ["hooks": hooks]
    }

    static func manifestObject(version: String) -> [String: Any] {
        ["name": name, "version": version, "description": description]
    }

    static func json(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    /// The helper next to the running executable: `.build/debug/`, `build/dev/` or the app's `Contents/MacOS/`.
    static func helperNextTo(executable: URL?) -> URL? {
        guard let executable else { return nil }
        let helper = executable.deletingLastPathComponent().appendingPathComponent(helperName)
        return access(helper.path, X_OK) == 0 ? helper : nil
    }

    @discardableResult
    static func install(in folder: URL, helper: URL, socketPath: String, serverPath: String, version: String) throws -> [String] {
        let helperData = try Data(contentsOf: helper)
        let files: [(path: String, data: Data, mode: mode_t)] = [
            (pluginManifest, json(manifestObject(version: version)), 0o600),
            (hooksFile, json(hooksObject(socketPath: socketPath, serverPath: serverPath)), 0o600),
            (helperFile, helperData, 0o700),
        ]
        try AtomicFile.makeFolder(folder, enforcingMode: true)
        for sub in [".claude-plugin", "hooks", "bin"] {
            try AtomicFile.makeFolder(folder.appendingPathComponent(sub, isDirectory: true), enforcingMode: true)
        }
        var written: [String] = []
        for file in files {
            let url = folder.appendingPathComponent(file.path)
            if let existing = try? Data(contentsOf: url), existing == file.data { continue }
            try AtomicFile.write(file.data, to: url.path, mode: file.mode)
            written.append(file.path)
        }
        return written
    }
}
