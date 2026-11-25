import Foundation

/// The command line. Scratch runs name their own folders and tmux server so they never touch the
/// installed app's sessions; the debug switches exist only in debug builds.
struct LaunchOptions: Equatable {
    var supportDir: URL?
    var appHome: URL?
    var tmuxSocket: String?
    var webDir: URL?
    var isBackground = false
    var isOffscreen = false
    var hasStatusItem = true
    var snapshot: URL?
    var debugScript: URL?
    var exitAfterDebug = false
    var printsMenu = false

    static let debugOnly: Set<String> = ["--snapshot", "--debug-script", "--exit-after-debug", "--offscreen", "--debug-menu"]

    enum ParseError: Error, Equatable {
        case missingValue(String)
        case unknown(String)
        case debugOnly(String)
    }

    static func parse(_ arguments: [String], isDebugBuild: Bool) -> Result<LaunchOptions, ParseError> {
        var options = LaunchOptions()
        var remaining = ArraySlice(arguments.dropFirst())
        while let argument = remaining.popFirst() {
            if !isDebugBuild, debugOnly.contains(argument) { return .failure(.debugOnly(argument)) }
            func value() -> String? {
                guard let next = remaining.popFirst(), !next.isEmpty else { return nil }
                return next
            }
            func url(_ name: String) -> Result<URL, ParseError> {
                guard let text = value() else { return .failure(.missingValue(name)) }
                return .success(URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL)
            }
            switch argument {
            case "--support-dir":
                switch url(argument) { case .success(let u): options.supportDir = u; case .failure(let e): return .failure(e) }
            case "--app-home":
                switch url(argument) { case .success(let u): options.appHome = u; case .failure(let e): return .failure(e) }
            case "--web-dir":
                switch url(argument) { case .success(let u): options.webDir = u; case .failure(let e): return .failure(e) }
            case "--snapshot":
                switch url(argument) { case .success(let u): options.snapshot = u; case .failure(let e): return .failure(e) }
            case "--debug-script":
                switch url(argument) { case .success(let u): options.debugScript = u; case .failure(let e): return .failure(e) }
            case "--tmux-socket":
                guard let name = value(), name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return .failure(.missingValue(argument)) }
                options.tmuxSocket = name
            case "--background": options.isBackground = true
            case "--offscreen": options.isOffscreen = true
            case "--no-status-item": options.hasStatusItem = false
            case "--exit-after-debug": options.exitAfterDebug = true
            case "--debug-menu": options.printsMenu = true
            default:
                // Launch Services may add -psn_ and -NS… arguments of its own.
                if argument.hasPrefix("-psn_") { continue }
                if argument.hasPrefix("-NS") || argument.hasPrefix("-Apple") {
                    if let next = remaining.first, !next.hasPrefix("-") { remaining.removeFirst() }
                    continue
                }
                return .failure(.unknown(argument))
            }
        }
        return .success(options)
    }

    /// A run that uses the account's own folders and tmux server: the installed app or a plain dev run.
    var isAccountRun: Bool { supportDir == nil && appHome == nil && tmuxSocket == nil }

    var isDebugRun: Bool { snapshot != nil || debugScript != nil || exitAfterDebug || printsMenu }

    func paths(userHome: String = NSHomeDirectory()) -> AppPaths {
        var paths = AppPaths.defaults(userHome: userHome)
        if let supportDir { paths.support = supportDir }
        if let appHome { paths.home = appHome }
        if let tmuxSocket { paths.tmuxSocketName = tmuxSocket }
        return paths
    }
}
