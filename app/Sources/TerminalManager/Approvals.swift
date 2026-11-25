import Foundation

struct AskQuestion: Equatable {
    var question: String
    var header: String
    var options: [String]
    var multiSelect: Bool
}

/// A held PermissionRequest as the cards show it: the literal command or file, the options, and how each
/// option is written back through the waiting helper.
struct AskRequest {
    enum Kind: String {
        case permission
        case question
    }

    static let questionTool = "AskUserQuestion"
    static let typeAnswer = "Type an answer"
    static let allowOnce = "Allow once"
    static let alwaysAllow = "Always allow"
    static let deny = "Deny"
    static let maxShown = 300

    var kind: Kind
    var tool: String
    var toolInput: [String: Any]
    /// One line for the feed and the list: may be clipped, never shown with answer buttons.
    var text: String
    /// The card's heading above `detail`.
    var heading: String
    /// What the card shows in full when it carries answer buttons (AskDisplay); empty otherwise.
    var detail: String
    var options: [String]
    /// The suggestion "Always allow" echoes back; nil when Claude Code offered none to echo.
    var alwaysEntry: [String: Any]?
    var questions: [AskQuestion]
    /// Whether the session view's card may carry answer buttons (AskDisplay's rule).
    var isAnswerable: Bool
    /// Whether the narrow cards (lane, list row) may carry them too.
    var fitsCompact: Bool
    /// Why the card sends you to the terminal; nil when it can be answered here.
    var terminalReason: String?
    /// The list row's line under the name.
    var summary: String

    static func parse(_ input: [String: Any], isInputExact: Bool = true) -> AskRequest? {
        guard let tool = BridgeValue.string(input["tool_name"]), !tool.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let toolInput: [String: Any]
        switch input["tool_input"] {
        case nil, is NSNull: toolInput = [:]
        case let object as [String: Any]: toolInput = object
        default: return nil
        }
        let cwd = BridgeValue.string(input["cwd"])
        if tool == questionTool {
            let questions = parseQuestions(toolInput)
            let first = questions.first
            var fit = AskDisplay.question(input: toolInput, isInputExact: isInputExact)
            if questions.count != 1 || first?.multiSelect != false || (first?.options.isEmpty ?? true) {
                fit = AskDisplay.Fit(detail: "", isAnswerable: false, fitsCompact: false, reason: "This question has several parts; answer it in the terminal")
            }
            return AskRequest(
                kind: .question, tool: tool, toolInput: toolInput,
                text: first.map { clip($0.question) } ?? "Claude asked a question",
                heading: "Claude asks", detail: fit.detail,
                options: fit.isAnswerable ? (first?.options ?? []) + [typeAnswer] : [],
                alwaysEntry: nil, questions: questions, isAnswerable: fit.isAnswerable, fitsCompact: fit.fitsCompact,
                terminalReason: fit.reason, summary: "Asking a question"
            )
        }
        let subject = ToolSubject.describe(tool: tool, input: toolInput, cwd: cwd)
        let always = alwaysEntry(input["permission_suggestions"])
        var options = [allowOnce]
        if always != nil { options.append(alwaysAllow) }
        options.append(deny)
        let fit = AskDisplay.permission(tool: tool, input: toolInput, cwd: cwd, isInputExact: isInputExact)
        return AskRequest(
            kind: .permission, tool: tool, toolInput: toolInput,
            text: subject.map { "Allow \(tool): \(clip($0))?" } ?? "Allow \(tool)?",
            heading: "Allow \(tool)?", detail: fit.detail,
            options: options, alwaysEntry: always, questions: [], isAnswerable: fit.isAnswerable, fitsCompact: fit.fitsCompact,
            terminalReason: fit.reason, summary: ToolSubject.wantsSummary(tool: tool, subject: subject)
        )
    }

    static func parseQuestions(_ input: [String: Any]) -> [AskQuestion] {
        guard let raw = input["questions"] as? [Any] else { return [] }
        return raw.prefix(4).compactMap { item in
            guard let object = item as? [String: Any], let question = BridgeValue.string(object["question"]), !question.isEmpty else { return nil }
            let options = (object["options"] as? [Any] ?? []).prefix(8).compactMap { option -> String? in
                guard let option = option as? [String: Any], let label = BridgeValue.string(option["label"]), !label.isEmpty else { return nil }
                return label
            }
            return AskQuestion(
                question: question, header: BridgeValue.string(object["header"]) ?? "",
                options: options, multiSelect: BridgeValue.bool(object["multiSelect"]) ?? false
            )
        }
    }

    /// One `addRules` entry that allows (echoed exactly), or else a switch to acceptEdits for the session
    /// (what the terminal's "allow all edits" does). Anything else offers no Always.
    static func alwaysEntry(_ raw: Any?) -> [String: Any]? {
        guard let list = raw as? [Any] else { return nil }
        let entries = list.compactMap { $0 as? [String: Any] }
        let allows = entries.filter { BridgeValue.string($0["type"]) == "addRules" && BridgeValue.string($0["behavior"]) == "allow" }
        if allows.count == 1, let entry = allows.first, let rules = entry["rules"] as? [Any], !rules.isEmpty,
           rules.allSatisfy({ ($0 as? [String: Any]).flatMap { BridgeValue.string($0["toolName"]) }?.isEmpty == false }) {
            return entry
        }
        return entries.first { BridgeValue.string($0["type"]) == "setMode" && BridgeValue.string($0["mode"]) == "acceptEdits" }
    }

    static func clip(_ text: String) -> String {
        let line = ClaudeStatusReducer.oneLine(text)
        return line.count > maxShown ? String(line.prefix(maxShown - 1)) + "…" : line
    }
}

/// What a tool works on, as one line: the command, the file (relative to the session's folder), the url,
/// the pattern.
enum ToolSubject {
    static let fileTools: Set<String> = ["Read", "Edit", "Write", "MultiEdit", "NotebookEdit"]

    static func describe(tool: String, input: [String: Any], cwd: String?) -> String? {
        func value(_ key: String) -> String? {
            guard let text = BridgeValue.string(input[key]), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        switch tool {
        case "Bash": return value("command").map(ClaudeStatusReducer.oneLine)
        case "Read", "Edit", "Write", "MultiEdit": return value("file_path").map { relative($0, to: cwd) }
        case "NotebookEdit": return (value("notebook_path") ?? value("file_path")).map { relative($0, to: cwd) }
        case "Grep", "Glob": return value("pattern")
        case "WebFetch": return value("url")
        case "WebSearch": return value("query")
        case "Task", "Agent": return value("description")
        default: return nil
        }
    }

    static func relative(_ path: String, to cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return DisplayPath.tilde(path) }
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : DisplayPath.tilde(path)
    }

    static func wantsSummary(tool: String, subject: String?) -> String {
        guard let subject else { return "Wants to use \(tool)" }
        let short = ClaudeStatusReducer.clip(subject, to: 60)
        switch tool {
        case "Bash": return "Wants to run \(short)"
        case "Edit", "MultiEdit", "NotebookEdit": return "Wants to edit \(short)"
        case "Write": return "Wants to write \(short)"
        case "WebFetch": return "Wants to fetch \(short)"
        default: return "Wants to use \(tool)"
        }
    }

    static func doingSummary(tool: String, subject: String?) -> String {
        let short = subject.map { ClaudeStatusReducer.clip($0, to: 60) }
        switch tool {
        case "Bash": return short.map { "Running \($0)" } ?? "Running a command"
        case "Read": return short.map { "Reading \($0)" } ?? "Reading"
        case "Edit", "MultiEdit", "NotebookEdit": return short.map { "Editing \($0)" } ?? "Editing"
        case "Write": return short.map { "Writing \($0)" } ?? "Writing"
        case "Grep", "Glob": return "Searching"
        case "WebFetch", "WebSearch": return "Looking it up"
        case "Task", "Agent": return short.map { "Agent: \($0)" } ?? "Running an agent"
        default: return "Using \(tool)"
        }
    }
}

/// An answer from the page: one of the card's options by index, or text typed for a question.
enum AskAnswer: Equatable {
    case option(Int)
    case text(String)
}

/// The hook outputs written back through the waiting helper.
enum HookAnswer {
    static let denyMessage = "The user denied this from Terminal Manager."
    static let maxTyped = 2000

    /// The output for an answer, and the words the feed stamps on the ask; nil when the answer does not fit the request.
    static func output(for ask: AskRequest, answer: AskAnswer) -> (output: [String: Any], stamp: String)? {
        guard ask.isAnswerable else { return nil }
        switch (ask.kind, answer) {
        case (.permission, .option(let index)):
            guard ask.options.indices.contains(index) else { return nil }
            switch ask.options[index] {
            case AskRequest.allowOnce: return (wrap(["behavior": "allow"]), "Allowed once")
            case AskRequest.alwaysAllow:
                guard let entry = ask.alwaysEntry else { return nil }
                return (wrap(["behavior": "allow", "updatedPermissions": [entry]]), "Always allowed")
            case AskRequest.deny: return (wrap(["behavior": "deny", "message": denyMessage]), "Denied")
            default: return nil
            }
        case (.question, .option(let index)):
            guard let question = ask.questions.first, question.options.indices.contains(index) else { return nil }
            let label = question.options[index]
            return (questionOutput(ask, question: question.question, answer: label), "Answered: \(label)")
        case (.question, .text(let text)):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let question = ask.questions.first, !trimmed.isEmpty, trimmed.count <= maxTyped else { return nil }
            return (questionOutput(ask, question: question.question, answer: trimmed), "Answered: \(trimmed)")
        default:
            return nil
        }
    }

    static func questionOutput(_ ask: AskRequest, question: String, answer: String) -> [String: Any] {
        var updated = ask.toolInput
        updated["answers"] = [question: answer]
        return wrap(["behavior": "allow", "updatedInput": updated])
    }

    static func wrap(_ decision: [String: Any]) -> [String: Any] {
        ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
    }
}

/// Deep equality of JSON values, telling booleans from numbers (Foundation's isEqual does not).
enum JSONEquality {
    static func isEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil), (is NSNull, is NSNull):
            return true
        case let (left as String, right as String):
            return left == right
        case let (left as NSNumber, right as NSNumber):
            let isBool = CFGetTypeID(left) == CFBooleanGetTypeID()
            guard isBool == (CFGetTypeID(right) == CFBooleanGetTypeID()) else { return false }
            return left == right
        case let (left as [Any], right as [Any]):
            return left.count == right.count && zip(left, right).allSatisfy { isEqual($0, $1) }
        case let (left as [String: Any], right as [String: Any]):
            return left.count == right.count && left.allSatisfy { key, value in right[key].map { isEqual(value, $0) } ?? false }
        default:
            return false
        }
    }
}
