import AppKit
import WebKit

/// What the bridge needs from the app around it.
@MainActor
protocol BridgeHost: AnyObject {
    var openAtLogin: LoginItemState { get }
    func setOpenAtLogin(_ on: Bool) -> LoginItemState
    func chooseFolder(completion: @escaping @MainActor (String?) -> Void)
    func reveal(path: String)
    func pageDidLoad()
    var isDebugRun: Bool { get }
    func debugSnapshot(path: String, completion: @escaping @MainActor (Bool) -> Void)
}

/// `window.webkit.messageHandlers.tm.postMessage({op, ...})` in (each op gets a reply), and
/// `window.TMNative.receive(event)` out.
@MainActor
final class WebBridge: NSObject, WKScriptMessageHandlerWithReply {
    typealias Reply = @MainActor @Sendable (Any?, String?) -> Void

    static let handlerName = "tm"
    static let version = 1

    weak var host: BridgeHost?
    weak var webView: WKWebView?
    let manager: SessionManager
    private var ptys: [Int: PtyClient] = [:]
    private var nextPtyID = 1

    init(manager: SessionManager) {
        self.manager = manager
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        handle(message.body, reply: replyHandler)
    }

    func handle(_ body: Any, reply: @escaping Reply) {
        guard let message = body as? [String: Any], let op = BridgeValue.string(message["op"]) else { return reply(nil, "bad-request") }
        let id = BridgeValue.string(message["id"]) ?? ""
        func finish(_ result: Result<Void, SessionError>) {
            switch result {
            case .success: reply(["ok": true], nil)
            case .failure(let error): reply(nil, error.rawValue)
            }
        }
        switch op {
        case "hello":
            reply(helloObject(), nil)
            host?.pageDidLoad()
        case "create":
            guard let kind = BridgeValue.string(message["kind"]).flatMap(SessionKind.init(rawValue:)), let dir = BridgeValue.string(message["dir"]) else { return reply(nil, "bad-request") }
            let mode = BridgeValue.string(message["mode"]).flatMap { PermissionMode(label: $0) ?? PermissionMode(rawValue: $0) } ?? .default
            manager.create(kind: kind, dir: dir, prompt: BridgeValue.string(message["prompt"]), mode: mode) { result in
                switch result {
                case .success(let newID): reply(["id": newID], nil)
                case .failure(let error): reply(nil, error.rawValue)
                }
            }
        case "delete":
            closePtys(for: id)
            finish(manager.delete(id))
        case "resume":
            switch manager.resumeClosed(id) {
            case .success(let newID): reply(["id": newID], nil)
            case .failure(let error): reply(nil, error.rawValue)
            }
        case "restart": finish(manager.restart(id))
        case "stop": finish(manager.stopSession(id))
        case "send": finish(manager.send(id, text: BridgeValue.string(message["text"]) ?? ""))
        case "answer":
            guard let askID = BridgeValue.string(message["ask"]), !askID.isEmpty else { return reply(nil, "bad-request") }
            let answer: AskAnswer
            if let index = BridgeValue.int(message["index"]) {
                answer = .option(index)
            } else if let text = BridgeValue.string(message["text"]) {
                answer = .text(text)
            } else {
                return reply(nil, "bad-request")
            }
            manager.answer(id, askID: askID, answer: answer) { result in
                if case .failure = result { self.sendSessions() }
                finish(result)
            }
        case "review": finish(manager.review(id))
        case "rename": finish(manager.rename(id, to: BridgeValue.string(message["name"]) ?? ""))
        case "setMuted": finish(manager.setMuted(id, BridgeValue.bool(message["muted"]) ?? false))
        case "setMode":
            guard let mode = BridgeValue.string(message["mode"]).flatMap({ PermissionMode(label: $0) }) else { return reply(nil, "bad-request") }
            finish(manager.setMode(id, mode))
        case "setPrefs":
            if let on = BridgeValue.bool(message["dnd"]) { manager.setDoNotDisturb(on) }
            if let on = BridgeValue.bool(message["notifications"]) { manager.setNotificationsEnabled(on) }
            if let on = BridgeValue.bool(message["openAtLogin"]), let host {
                let state = host.setOpenAtLogin(on)
                return reply(prefsObject(login: state), nil)
            }
            reply(prefsObject(login: host?.openAtLogin), nil)
        case "dirStatus":
            let path = DisplayPath.absolute(BridgeValue.string(message["path"]) ?? "", home: manager.home)
            var isDirectory: ObjCBool = false
            let exists = path.map { FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) } ?? false
            reply(["path": path.map { DisplayPath.tilde($0, home: manager.home) } ?? "", "exists": exists, "isDir": isDirectory.boolValue], nil)
        case "folders":
            reply(["folders": manager.folderSuggestions.map { DisplayPath.tilde($0, home: manager.home) }], nil)
        case "chooseFolder":
            host?.chooseFolder { path in
                let shown: Any = path.map { DisplayPath.tilde($0, home: self.manager.home) } ?? NSNull()
                reply(["path": shown], nil)
            }
        case "finder":
            guard let record = manager.record(id) else { return reply(nil, "not-found") }
            host?.reveal(path: record.dir)
            reply(["ok": true], nil)
        case "copyPath":
            guard let record = manager.record(id) else { return reply(nil, "not-found") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.dir, forType: .string)
            reply(["path": record.dir], nil)
        case "ptyOpen": ptyOpen(message, reply)
        case "ptyInput":
            guard let pty = BridgeValue.int(message["pty"]).flatMap({ ptys[$0] }) else { return reply(nil, "not-found") }
            if let text = BridgeValue.string(message["data"]) {
                pty.write(Data(text.utf8))
            } else if let binary = BridgeValue.string(message["binary"]) {
                pty.write(Data(binary.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }))
            }
            reply(["ok": true], nil)
        case "ptyResize":
            guard let pty = BridgeValue.int(message["pty"]).flatMap({ ptys[$0] }), let cols = BridgeValue.int(message["cols"]), let rows = BridgeValue.int(message["rows"]),
                  (2...1000).contains(cols), (2...500).contains(rows) else { return reply(nil, "bad-request") }
            pty.resize(cols: cols, rows: rows)
            reply(["ok": true], nil)
        case "ptyClose":
            if let ptyID = BridgeValue.int(message["pty"]), let pty = ptys.removeValue(forKey: ptyID) { pty.close() }
            reply(["ok": true], nil)
        case "log":
            Log.info("page: \(BridgeValue.string(message["text"]) ?? "")")
            reply(["ok": true], nil)
        case "debugSnapshot":
            guard let host, host.isDebugRun, let path = BridgeValue.string(message["path"]) else { return reply(nil, "unknown-op") }
            host.debugSnapshot(path: path) { reply(["ok": $0], nil) }
        default:
            reply(nil, "unknown-op")
        }
    }

    private func ptyOpen(_ message: [String: Any], _ reply: @escaping Reply) {
        guard let id = BridgeValue.string(message["id"]), let attach = manager.attachArguments(id) else { return reply(nil, "not-found") }
        let cols = min(max(BridgeValue.int(message["cols"]) ?? 80, 2), 1000)
        let rows = min(max(BridgeValue.int(message["rows"]) ?? 24, 2), 500)
        let ptyID = nextPtyID
        nextPtyID += 1
        manager.afterQueuedTmux { [weak self] in
            guard let self else { return }
            guard let client = PtyClient(id: ptyID, sessionID: id, arguments: attach.arguments, environment: attach.environment, cols: cols, rows: rows) else {
                return reply(nil, "pty-failed")
            }
            client.onOutput = { [weak self] data in
                self?.send(["type": "pty", "pty": ptyID, "data": data.base64EncodedString()])
            }
            client.onExit = { [weak self] in
                guard let self, self.ptys.removeValue(forKey: ptyID) != nil else { return }
                self.send(["type": "ptyExit", "pty": ptyID])
            }
            self.ptys[ptyID] = client
            reply(["pty": ptyID], nil)
        }
    }

    func closePtys(for sessionID: String) {
        for (key, pty) in ptys where pty.sessionID == sessionID {
            pty.close()
            ptys[key] = nil
        }
    }

    func closeAllPtys() {
        ptys.values.forEach { $0.close() }
        ptys = [:]
    }

    func helloObject() -> [String: Any] {
        [
            "version": Self.version,
            "home": manager.home,
            "sessions": manager.bridgeSessions(),
            "closed": manager.bridgeClosed(),
            "events": manager.feed.events.map(\.bridgeObject),
            "permissionModes": PermissionMode.allCases.map { ["label": $0.label, "hint": $0.hint, "value": $0.rawValue] },
            "defaultMode": PermissionMode.default.label,
            "prefs": prefsObject(login: host?.openAtLogin),
        ]
    }

    func prefsObject(login: LoginItemState?) -> [String: Any] {
        var object: [String: Any] = ["dnd": manager.settings.doNotDisturb, "notifications": manager.settings.notificationsEnabled]
        if let login {
            object["openAtLogin"] = login.isOn
            object["openAtLoginAvailable"] = login.isAvailable
            if let reason = login.reason { object["openAtLoginNote"] = reason }
        }
        return object
    }

    func sendSessions() {
        send(["type": "sessions", "sessions": manager.bridgeSessions(), "closed": manager.bridgeClosed()])
    }

    func sendPrefs() {
        send(["type": "prefs", "prefs": prefsObject(login: host?.openAtLogin)])
    }

    func send(_ event: [String: Any]) {
        guard let webView, JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event, options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return }
        // U+2028 and U+2029 end a line in older JavaScript string parsing; escaped they are just text.
        let safe = json.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        webView.evaluateJavaScript("window.TMNative && window.TMNative.receive(\(safe))", completionHandler: nil)
    }
}
