import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, BridgeHost {
    private var options = LaunchOptions()
    private var manager: SessionManager!
    private var bridge: WebBridge!
    private var window: MainWindowController!
    private var statusItem: StatusItemController?
    private let notifier = Notifier()
    private var hasRunDebug = false

    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif

    var isDebugRun: Bool { options.isDebugRun }

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch LaunchOptions.parse(CommandLine.arguments, isDebugBuild: Self.isDebugBuild) {
        case .success(let parsed): options = parsed
        case .failure(let error):
            Log.error("bad arguments: \(error)")
            exit(2)
        }
        MainMenu.install()
        let paths = options.paths()
        manager = SessionManager(paths: paths)
        bridge = WebBridge(manager: manager)
        bridge.host = self
        guard let webDir = resolveWebDir() else {
            Log.error("the web UI is missing (looked in the bundle's Resources/web and --web-dir)")
            exit(1)
        }
        window = MainWindowController(webDir: webDir, bridge: bridge, persistsWebsiteData: options.isAccountRun, isOffscreen: options.isOffscreen)
        window.onKeyChange = { [weak self] isKey in
            self?.bridge.send(["type": "window", "key": isKey])
        }
        wireManager()
        manager.start(executable: Bundle.main.executableURL, version: Version.string)
        if options.hasStatusItem { setUpStatusItem() }
        notifier.onOpen = { [weak self] sid in self?.openSession(sid) }
        notifier.requestPermission()
        setUpOpenAtLoginOnce()
        window.load()
        if options.isOffscreen || !(options.isBackground || Self.launchedAsLoginItem()) { window.show() }
        Log.info("Terminal Manager \(Version.string) running; support \(paths.support.path), tmux -L \(paths.tmuxSocketName)")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge?.closeAllPtys()
        manager?.stop()
    }

    private func resolveWebDir() -> URL? {
        let candidates = [options.webDir, Bundle.main.resourceURL?.appendingPathComponent("web")].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }

    /// macOS marks the launch event of a login item.
    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    private func wireManager() {
        manager.onChange = { [weak self] in
            guard let self else { return }
            self.bridge.sendSessions()
            self.statusItem?.update(StatusIconState.from(needsYou: self.manager.needsYouCount, ready: self.manager.readyCount))
        }
        manager.onFeed = { [weak self] events, removed in
            self?.bridge.send(["type": "feed", "events": events.map(\.bridgeObject), "removed": removed])
        }
        manager.onStatus = { [weak self] record, from, to in
            guard let self else { return }
            self.bridge.send(["type": "status", "sid": record.id, "from": from.rawValue, "to": to.rawValue])
            if from == .needsYou { self.notifier.clear(sessionID: record.id) }
            let settings = self.manager.settings
            if BannerRule.shouldBanner(to: to, isWindowKey: self.window.isKey, notificationsEnabled: settings.notificationsEnabled, doNotDisturb: settings.doNotDisturb, isMuted: record.muted) {
                self.notifier.post(sessionID: record.id, title: record.name, body: record.summary.isEmpty ? "Needs you" : record.summary)
            }
        }
        manager.onToast = { [weak self] text in
            self?.bridge.send(["type": "toast", "text": text])
        }
    }

    private func setUpStatusItem() {
        let item = StatusItemController()
        item.entries = { [weak self] in
            guard let self else { return ([], []) }
            let entry = { (record: SessionRecord) in StatusItemController.Entry(id: record.id, name: record.name, detail: record.summary) }
            return (self.manager.sessions.filter { $0.status == .needsYou }.map(entry), self.manager.sessions.filter { $0.status == .ready }.map(entry))
        }
        item.loginState = { [weak self] in self?.openAtLogin ?? LoginItemState(isOn: false, isAvailable: false, reason: nil) }
        item.onAction = { [weak self] action in self?.perform(action) }
        statusItem = item
        if options.printsMenu {
            item.rebuild()
            print("DEBUG_MENU \(DebugRunner.jsonLine(item.menuTitles))")
        }
    }

    private func perform(_ action: StatusItemController.Action) {
        switch action {
        case .openWindow: window.show()
        case .openSession(let sid): openSession(sid)
        case .newClaude: showAndSend(["type": "menu", "action": "new", "kind": "claude"])
        case .newTerminal: showAndSend(["type": "menu", "action": "new", "kind": "shell"])
        case .settings: showAndSend(["type": "menu", "action": "settings"])
        case .toggleOpenAtLogin:
            _ = setOpenAtLogin(!openAtLogin.isOn)
        case .quit: NSApp.terminate(nil)
        }
    }

    private func openSession(_ sid: String) {
        showAndSend(["type": "menu", "action": "open", "sid": sid])
    }

    private func showAndSend(_ event: [String: Any]) {
        window.show()
        bridge.send(event)
    }

    /// Open at login goes on once, at the first launch of the app installed in an Applications folder.
    private func setUpOpenAtLoginOnce() {
        guard options.isAccountRun, !options.isDebugRun, !manager.settings.hasSetUpOpenAtLogin,
              LoginItem.availability(bundleURL: Bundle.main.bundleURL).isAvailable else { return }
        _ = LoginItem.set(true, bundleURL: Bundle.main.bundleURL)
        manager.markOpenAtLoginSetUp()
    }

    // MARK: BridgeHost

    var openAtLogin: LoginItemState {
        LoginItem.state(bundleURL: Bundle.main.bundleURL)
    }

    func setOpenAtLogin(_ on: Bool) -> LoginItemState {
        guard !options.isDebugRun, options.isAccountRun else {
            return LoginItemState(isOn: false, isAvailable: false, reason: "Scratch and test runs never change Open at login.")
        }
        let state = LoginItem.set(on, bundleURL: Bundle.main.bundleURL)
        manager.markOpenAtLoginSetUp()
        bridge.sendPrefs()
        return state
    }

    func chooseFolder(completion: @escaping @MainActor (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/work")
        panel.beginSheetModal(for: window.window) { response in
            MainActor.assumeIsolated { completion(response == .OK ? panel.url?.path : nil) }
        }
    }

    func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func pageDidLoad() {
        guard !hasRunDebug, options.debugScript != nil || options.snapshot != nil || options.exitAfterDebug else { return }
        hasRunDebug = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            DebugRunner.run(webView: self.window.webView, scriptURL: self.options.debugScript, snapshotURL: self.options.snapshot) {
                if self.options.exitAfterDebug { NSApp.terminate(nil) }
            }
        }
    }

    func debugSnapshot(path: String, completion: @escaping @MainActor (Bool) -> Void) {
        DebugRunner.snapshot(webView: window.webView, to: URL(fileURLWithPath: path), completion: completion)
    }
}
