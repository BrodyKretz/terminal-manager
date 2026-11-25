import AppKit
import WebKit

/// The one window: the web UI in a WKWebView. Closing it only hides it; the app and every session go on.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    static let defaultSize = NSSize(width: 1440, height: 900)
    static let minimumSize = NSSize(width: 1080, height: 680)

    let window: NSWindow
    let webView: WKWebView
    private let webDir: URL
    private let isOffscreen: Bool
    var onKeyChange: ((Bool) -> Void)?

    init(webDir: URL, bridge: WebBridge, persistsWebsiteData: Bool, isOffscreen: Bool) {
        self.webDir = webDir
        self.isOffscreen = isOffscreen
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = persistsWebsiteData ? .default() : .nonPersistent()
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: WebBridge.handlerName)
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let frame = NSRect(origin: .zero, size: Self.defaultSize)
        webView = WKWebView(frame: frame, configuration: configuration)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Terminal Manager"
        window.isReleasedWhenClosed = false
        window.minSize = Self.minimumSize
        window.contentView = webView
        window.delegate = self
        window.setFrameAutosaveName(isOffscreen ? "" : "TerminalManagerMain")
        if !window.setFrameUsingName("TerminalManagerMain") || isOffscreen { window.center() }
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        bridge.webView = webView
    }

    func load() {
        webView.loadFileURL(webDir.appendingPathComponent("index.html"), allowingReadAccessTo: webDir)
    }

    /// Brings the window forward (LSUIElement apps must activate themselves). Offscreen test runs place it
    /// past every display and never activate, so nothing shows on the screen.
    func show() {
        if isOffscreen {
            let far = NSScreen.screens.map(\.frame.maxX).max() ?? 4000
            window.setFrameOrigin(NSPoint(x: far + 2000, y: 0))
            window.orderFrontRegardless()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    var isKey: Bool { window.isKeyWindow && NSApp.isActive }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) { onKeyChange?(true) }
    func windowDidResignKey(_ notification: Notification) { onKeyChange?(false) }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if url.isFileURL, url.standardizedFileURL.path.hasPrefix(webDir.standardizedFileURL.path) { return decisionHandler(.allow) }
        if url.scheme == "about" { return decisionHandler(.allow) }
        if ["http", "https"].contains(url.scheme ?? ""), navigationAction.targetFrame?.isMainFrame != false {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(navigationAction.targetFrame?.isMainFrame == false && ["http", "https"].contains(url.scheme ?? "") ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.warn("the page's web process ended; reloading")
        load()
    }
}

/// The main menu an LSUIElement app never shows but still needs: its key equivalents are what make
/// ⌘C, ⌘V, ⌘A and ⌘W work in the window.
enum MainMenu {
    @MainActor
    static func install() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Terminal Manager", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Terminal Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }
}
