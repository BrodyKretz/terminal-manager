import AppKit

/// What the menu bar icon says at a glance.
enum StatusIconState: Equatable {
    case idle
    case needsYou
    case ready

    static func from(needsYou: Int, ready: Int) -> StatusIconState {
        if needsYou > 0 { return .needsYou }
        return ready > 0 ? .ready : .idle
    }
}

/// How each state is drawn, in one place so the treatment can change without touching the drawing: a
/// nil tint is a template image (the menu bar colors it for light and dark); a tint is a colored,
/// non-template image.
struct StatusIconStyle {
    var idleTint: NSColor?
    var needsYouTint: NSColor?
    var readyTint: NSColor?

    static let standard = StatusIconStyle(idleTint: nil, needsYouTint: .systemOrange, readyTint: .systemGreen)

    func tint(for state: StatusIconState) -> NSColor? {
        switch state {
        case .idle: return idleTint
        case .needsYou: return needsYouTint
        case .ready: return readyTint
        }
    }
}

/// The plus sign, drawn in code so it stays sharp at every scale.
enum StatusIcon {
    static let size = NSSize(width: 18, height: 18)

    static func image(for state: StatusIconState, style: StatusIconStyle = .standard) -> NSImage {
        let tint = style.tint(for: state)
        let image = NSImage(size: size, flipped: false) { rect in
            (tint ?? .black).setFill()
            let arm: CGFloat = 12
            let thickness: CGFloat = 2.4
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let horizontal = NSRect(x: center.x - arm / 2, y: center.y - thickness / 2, width: arm, height: thickness)
            let vertical = NSRect(x: center.x - thickness / 2, y: center.y - arm / 2, width: thickness, height: arm)
            NSBezierPath(roundedRect: horizontal, xRadius: thickness / 2, yRadius: thickness / 2).fill()
            NSBezierPath(roundedRect: vertical, xRadius: thickness / 2, yRadius: thickness / 2).fill()
            return true
        }
        image.isTemplate = tint == nil
        image.accessibilityDescription = accessibilityText(state)
        return image
    }

    static func accessibilityText(_ state: StatusIconState) -> String {
        switch state {
        case .idle: return "Terminal Manager"
        case .needsYou: return "Terminal Manager: a session needs you"
        case .ready: return "Terminal Manager: a session is ready for review"
        }
    }
}

/// The menu bar item: the plus, and its dropdown built fresh each time it opens.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    enum Action {
        case openWindow
        case openSession(String)
        case newClaude
        case newTerminal
        case toggleOpenAtLogin
        case settings
        case quit
    }

    struct Entry {
        var id: String
        var name: String
        var detail: String
    }

    private let item: NSStatusItem
    private let menu = NSMenu()
    var onAction: ((Action) -> Void)?
    var entries: () -> (needsYou: [Entry], ready: [Entry]) = { ([], []) }
    var loginState: () -> LoginItemState = { LoginItemState(isOn: false, isAvailable: false, reason: nil) }
    private(set) var state: StatusIconState = .idle
    var style = StatusIconStyle.standard

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.image = StatusIcon.image(for: .idle, style: style)
        item.button?.toolTip = "Terminal Manager"
    }

    func update(_ newState: StatusIconState) {
        guard newState != state else { return }
        state = newState
        item.button?.image = StatusIcon.image(for: newState, style: style)
        item.button?.setAccessibilityLabel(StatusIcon.accessibilityText(newState))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    /// Also used by `--debug-menu` to print what the dropdown holds.
    func rebuild() {
        menu.removeAllItems()
        let sessions = entries()
        func section(_ title: String, _ list: [Entry], color: NSColor) {
            guard !list.isEmpty else { return }
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in list {
                let row = NSMenuItem(title: entry.name, action: #selector(pressed(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = entry.id
                row.toolTip = entry.detail
                row.image = Self.dot(color)
                row.indentationLevel = 1
                menu.addItem(row)
            }
        }
        section("Needs you", sessions.needsYou, color: .systemOrange)
        section("Ready for review", sessions.ready, color: .systemGreen)
        if sessions.needsYou.isEmpty && sessions.ready.isEmpty {
            let none = NSMenuItem(title: "Nothing needs you", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        add("New Claude session…", .newClaude)
        add("New terminal…", .newTerminal)
        add("Open window", .openWindow)
        menu.addItem(.separator())
        let login = loginState()
        let loginItem = add("Open at login", .toggleOpenAtLogin)
        loginItem.state = login.isOn ? .on : .off
        loginItem.isEnabled = login.isAvailable
        loginItem.toolTip = login.reason
        add("Settings…", .settings, key: ",")
        menu.addItem(.separator())
        add("Quit Terminal Manager", .quit, key: "q")
    }

    var menuTitles: [String] {
        menu.items.map { $0.isSeparatorItem ? "---" : ($0.indentationLevel > 0 ? "  " : "") + $0.title + ($0.state == .on ? " ✓" : "") }
    }

    @discardableResult
    private func add(_ title: String, _ action: Action, key: String = "") -> NSMenuItem {
        let row = NSMenuItem(title: title, action: #selector(pressed(_:)), keyEquivalent: key)
        row.target = self
        row.representedObject = ActionBox(action)
        menu.addItem(row)
        return row
    }

    @objc private func pressed(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            onAction?(.openSession(id))
        } else if let box = sender.representedObject as? ActionBox {
            onAction?(box.action)
        }
    }

    private static func dot(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        return image
    }

    private final class ActionBox {
        let action: Action
        init(_ action: Action) { self.action = action }
    }
}
