import Foundation
import ServiceManagement

struct LoginItemState: Equatable {
    var isOn: Bool
    var isAvailable: Bool
    var reason: String?
}

/// Open at login: SMAppService.mainApp first; when macOS refuses it (an ad-hoc signed bundle can be
/// refused, or left waiting for approval) a LaunchAgent in ~/Library/LaunchAgents that opens the app.
/// Only for the bundle installed in /Applications or ~/Applications; a bare binary never registers.
enum LoginItem {
    static let agentLabel = "com.brodykretz.terminal-manager"

    static func agentURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static func availability(bundleURL: URL, home: String = NSHomeDirectory()) -> LoginItemState {
        guard bundleURL.pathExtension == "app" else {
            return LoginItemState(isOn: false, isAvailable: false, reason: "Open at login needs the installed app; this run is the bare binary.")
        }
        let path = bundleURL.standardizedFileURL.path
        let folders = ["/Applications/", home + "/Applications/"]
        guard folders.contains(where: { path.hasPrefix($0) }) else {
            return LoginItemState(isOn: false, isAvailable: false, reason: "Install the app into ~/Applications to open it at login.")
        }
        return LoginItemState(isOn: false, isAvailable: true, reason: nil)
    }

    static func agentPlist(bundlePath: String) -> [String: Any] {
        ["Label": agentLabel, "ProgramArguments": ["/usr/bin/open", "-a", bundlePath], "RunAtLoad": true, "ProcessType": "Interactive"]
    }

    static func agentPoints(at bundlePath: String, agent: URL) -> Bool {
        guard let plist = NSDictionary(contentsOf: agent) as? [String: Any], let arguments = plist["ProgramArguments"] as? [String] else { return false }
        return arguments.last == bundlePath
    }

    static func state(bundleURL: URL, home: String = NSHomeDirectory()) -> LoginItemState {
        var state = availability(bundleURL: bundleURL, home: home)
        guard state.isAvailable else { return state }
        state.isOn = SMAppService.mainApp.status == .enabled || agentPoints(at: bundleURL.path, agent: agentURL(home: home))
        return state
    }

    /// Turns it on or off and says how it ended up; the log names the mechanism used.
    static func set(_ on: Bool, bundleURL: URL, home: String = NSHomeDirectory()) -> LoginItemState {
        let available = availability(bundleURL: bundleURL, home: home)
        guard available.isAvailable else { return available }
        let agent = agentURL(home: home)
        if on {
            do {
                try SMAppService.mainApp.register()
            } catch {
                Log.warn("open at login: SMAppService refused (\(error.localizedDescription)); using a LaunchAgent")
            }
            if SMAppService.mainApp.status == .enabled {
                try? FileManager.default.removeItem(at: agent)
                Log.info("open at login: on through SMAppService.mainApp")
            } else {
                if SMAppService.mainApp.status == .requiresApproval { try? SMAppService.mainApp.unregister() }
                do {
                    try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let data = try PropertyListSerialization.data(fromPropertyList: agentPlist(bundlePath: bundleURL.path), format: .xml, options: 0)
                    try AtomicFile.write(data, to: agent.path, mode: 0o644)
                    Log.info("open at login: on through the LaunchAgent \(agent.lastPathComponent)")
                } catch {
                    Log.error("open at login: the LaunchAgent could not be written: \(error)")
                }
            }
        } else {
            try? SMAppService.mainApp.unregister()
            try? FileManager.default.removeItem(at: agent)
            Log.info("open at login: off")
        }
        return state(bundleURL: bundleURL, home: home)
    }
}
