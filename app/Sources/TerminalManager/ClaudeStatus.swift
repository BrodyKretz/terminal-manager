import Foundation

/// What a Claude session is doing as the list shows it.
struct ClaudeActivity: Equatable {
    var status: SessionStatus
    var statusAt: Date
    var summary: String
    var hasError: Bool

    static func fresh(at date: Date) -> ClaudeActivity {
        ClaudeActivity(status: .idle, statusAt: date, summary: "Waiting for your first message", hasError: false)
    }
}

/// What a hook (or the app) says happened in a Claude session, reduced to what moves its status.
enum ClaudeSignal: Equatable {
    case sessionStarted(source: String?)
    case promptSubmitted(String?)
    case toolStarted(summary: String)
    /// A PostToolUse or PostToolUseFailure; `hasPendingAsk` when a held request still waits.
    case toolEnded(hasPendingAsk: Bool)
    case permissionRequested(summary: String)
    case questionAsked
    /// Notification `permission_prompt`: a dialog shows, even one the app holds nothing for.
    case permissionPrompt
    case stopped(lastReply: String?, stopHookActive: Bool)
    case stopFailed
    case sessionEnded(reason: String?)
    /// The last held request was answered (from the app or in the terminal).
    case answered
    case reviewed
    /// The registry says the session sits at its prompt while it looked busy: an interrupt (Esc), which no hook reports.
    case wentIdle
    case processExited
    case restarted
}

/// The status rules, pure. Viewing a ready session changes nothing; only "Looks good" (reviewed) does.
enum ClaudeStatusReducer {
    static let maxSummary = 80

    static func reduce(_ activity: ClaudeActivity, _ signal: ClaudeSignal, now: Date) -> ClaudeActivity {
        var next = activity
        func move(_ status: SessionStatus, _ summary: String, hasError: Bool = false) {
            if next.status != status { next.statusAt = now }
            next.status = status
            next.summary = summary
            next.hasError = hasError
        }
        switch signal {
        case .sessionStarted(let source):
            switch source {
            case "clear": move(.idle, "Cleared, waiting for a message")
            case "compact": break
            case "resume": if activity.status != .working { move(.idle, "Resumed, waiting for a message") }
            default: if activity.status == .exited || activity.status == .idle { move(.idle, "Waiting for your first message") }
            }
        case .promptSubmitted(let prompt):
            move(.working, prompt.map { clip(oneLine($0)) }.flatMap { $0.isEmpty ? nil : $0 } ?? "Working on your message")
        case .toolStarted(let summary):
            if activity.status != .needsYou { move(.working, summary) }
        case .toolEnded(let hasPendingAsk):
            if activity.status == .needsYou, hasPendingAsk { break }
            if activity.status == .needsYou || activity.status == .working || activity.status == .idle {
                move(.working, activity.status == .needsYou ? "Continuing" : activity.summary)
            }
        case .permissionRequested(let summary):
            move(.needsYou, summary)
        case .questionAsked:
            move(.needsYou, "Asking a question")
        case .permissionPrompt:
            if activity.status == .working || activity.status == .idle { move(.needsYou, "Waiting for permission") }
        case .stopped(let reply, let stopHookActive):
            guard !stopHookActive else { break }
            let text = reply.map { clip(oneLine($0)) } ?? ""
            move(.ready, text.isEmpty ? "Finished its turn" : "Done: \(text)")
        case .stopFailed:
            move(.ready, "Stopped on an error", hasError: true)
        case .sessionEnded(let reason):
            if reason == "clear" { break }
            move(.exited, "Claude exited")
        case .answered:
            if activity.status == .needsYou { move(.working, "Continuing") }
        case .reviewed:
            if activity.status == .ready { move(.reviewed, "Reviewed, nothing owed") }
        case .wentIdle:
            if activity.status == .working || activity.status == .needsYou { move(.ready, "Interrupted") }
        case .processExited:
            if activity.status != .exited { move(.exited, "Claude exited") }
        case .restarted:
            move(.idle, "Restarted, waiting for a message")
        }
        return next
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func clip(_ text: String, to limit: Int = maxSummary) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
