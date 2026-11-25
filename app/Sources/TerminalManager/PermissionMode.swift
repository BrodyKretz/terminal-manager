import Foundation

/// The modes the create flow offers, each the exact `claude --permission-mode` value (`claude --help`
/// on Claude Code 2.1.331 lists acceptEdits, auto, bypassPermissions, manual, dontAsk and plan).
enum PermissionMode: String, Codable, CaseIterable {
    case auto
    case manual
    case acceptEdits
    case plan

    static let `default` = PermissionMode.auto

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .manual: return "Ask before edits"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan only"
        }
    }

    var hint: String {
        switch self {
        case .auto: return "Claude decides, asks when it's unsure"
        case .manual: return "Asks before every change"
        case .acceptEdits: return "Edits freely, asks for commands"
        case .plan: return "Reads and plans, changes nothing"
        }
    }

    init?(label: String) {
        guard let mode = PermissionMode.allCases.first(where: { $0.label == label }) else { return nil }
        self = mode
    }

    /// What a hook's `permission_mode` reports; `default` is the older name of manual.
    init?(hookValue: String) {
        if hookValue == "default" {
            self = .manual
        } else {
            self.init(rawValue: hookValue)
        }
    }
}
