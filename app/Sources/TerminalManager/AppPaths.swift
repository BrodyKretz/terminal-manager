import Foundation

/// Where the app keeps its things. `support` holds sessions.json, settings.json, feed.json and the tmux
/// config; `home` (~/.terminal-manager) holds what Claude Code reaches: the plugin and the hook socket,
/// whose path must fit a Unix socket address (103 bytes).
struct AppPaths: Equatable {
    static let defaultSupportName = "Terminal Manager"
    static let defaultHomeName = ".terminal-manager"
    static let defaultTmuxSocket = "terminal-manager"

    var support: URL
    var home: URL
    var tmuxSocketName: String

    var sessionsFile: URL { support.appendingPathComponent("sessions.json") }
    var settingsFile: URL { support.appendingPathComponent("settings.json") }
    var feedFile: URL { support.appendingPathComponent("feed.json") }
    var tmuxConfig: URL { support.appendingPathComponent("tmux.conf") }
    var pluginFolder: URL { home.appendingPathComponent("claude-plugin", isDirectory: true) }
    var runFolder: URL { home.appendingPathComponent("run", isDirectory: true) }
    var socketPath: String { runFolder.appendingPathComponent("hooks.sock").path }

    static func defaults(userHome: String = NSHomeDirectory()) -> AppPaths {
        let library = URL(fileURLWithPath: userHome, isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
        return AppPaths(
            support: library.appendingPathComponent(defaultSupportName, isDirectory: true),
            home: URL(fileURLWithPath: userHome, isDirectory: true).appendingPathComponent(defaultHomeName, isDirectory: true),
            tmuxSocketName: defaultTmuxSocket
        )
    }

    func prepare() throws {
        try AtomicFile.makeFolder(support)
        try AtomicFile.makeFolder(home)
        try AtomicFile.makeFolder(runFolder, enforcingMode: true)
    }
}

/// `~/work/api` for a path under the home folder; anything else as it is.
enum DisplayPath {
    static func tilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The page's typed path to an absolute one: `~` expanded, a bare name taken as a folder of ~/work,
    /// trailing slashes and `.`/`..` resolved. nil for an empty path.
    static func absolute(_ typed: String, home: String = NSHomeDirectory()) -> String? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text == "~" { text = home } else if text.hasPrefix("~/") { text = home + text.dropFirst(1) } else if !text.hasPrefix("/") { text = home + "/work/" + text }
        let standardized = (text as NSString).standardizingPath
        return standardized.isEmpty ? nil : standardized
    }
}
