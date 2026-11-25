import Foundation

/// The one rule for when a card may carry Allow/Deny (or a question's option buttons): every key of the
/// tool input is shown, the whole detail fits its box with no scrolling and no clipping, and every
/// character is one that cannot hide anything. Anything else is answered in the terminal.
enum AskDisplay {
    /// The session view's ask card: a wide box.
    static let fullColumns = 100
    static let fullLines = 12
    /// The lane card and the list row's quick answer: narrow boxes.
    static let compactColumns = 22
    static let compactLines = 5
    /// A tab counts as this many columns.
    static let tabWidth = 8
    /// The longest run of spaces or tabs on a line, and of blank lines.
    static let maxSpaceRun = 7
    static let maxBlankRun = 1
    static let rejectedScalars: Set<UInt32> = [0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800]

    struct Fit: Equatable {
        var detail: String
        /// Whether the detail obeys the rule at all; when false the card is terminal-only.
        var isAnswerable: Bool
        /// Whether it also fits the narrow boxes; when false only the session view's card has buttons.
        var fitsCompact: Bool
        var reason: String?
    }

    /// The detail a permission card shows: the command, or the file and its new content or diff, then
    /// every other key of the input as compact JSON below it.
    static func detail(tool: String, input: [String: Any], cwd: String?) -> (text: String, consumed: Set<String>) {
        func string(_ key: String, in object: [String: Any] = input) -> String? { object[key] as? String }
        func path(_ key: String) -> String? { string(key).map { ToolSubject.relative($0, to: cwd) } }
        let lines: [String]
        let consumed: Set<String>
        switch tool {
        case "Bash" where string("command") != nil:
            lines = [string("command")!]
            consumed = ["command"]
        case "Write" where string("file_path") != nil && string("content") != nil:
            lines = [path("file_path")!, withoutFinalNewline(string("content")!)]
            consumed = ["file_path", "content"]
        case "Read" where string("file_path") != nil:
            lines = [path("file_path")!]
            consumed = ["file_path"]
        case "Edit" where string("file_path") != nil && string("old_string") != nil && string("new_string") != nil:
            lines = [path("file_path")!, prefixed(string("old_string")!, "- "), prefixed(string("new_string")!, "+ ")]
            consumed = ["file_path", "old_string", "new_string"]
        default:
            lines = []
            consumed = []
        }
        let rest = input.filter { !consumed.contains($0.key) }
        var text = lines.joined(separator: "\n")
        if !rest.isEmpty || lines.isEmpty {
            let json = compactJSON(rest) ?? "?"
            text = text.isEmpty ? json : text + "\n" + json
        }
        return (text, consumed)
    }

    /// A file's final newline shows as nothing; dropping it keeps an ordinary file from looking like a blank run.
    static func withoutFinalNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    static func prefixed(_ text: String, _ prefix: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n")
    }

    static func compactJSON(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Every string anywhere in the input, keys included: what the characters rule checks, since JSON
    /// would show a control character only as an escape.
    static func allStrings(_ value: Any) -> [String] {
        switch value {
        case let text as String: return [text]
        case let list as [Any]: return list.flatMap(allStrings)
        case let object as [String: Any]: return object.flatMap { [$0.key] + allStrings($0.value) }
        default: return []
        }
    }

    /// Bash: printable ASCII, newline and tab only.
    static func isPlainASCII(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0 == "\n" || $0 == "\t" || (0x20...0x7E).contains($0.value) }
    }

    /// Other tools: printable ASCII, newline, tab, ordinary spaces, and beyond ASCII only letters and digits
    /// (L*, N*) that are not default-ignorable and not one of the known blank-looking fillers.
    static func isShowable(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            if scalar == "\n" || scalar == "\t" || (0x20...0x7E).contains(scalar.value) { return true }
            if scalar.value < 0x80 || rejectedScalars.contains(scalar.value) || scalar.properties.isDefaultIgnorableCodePoint { return false }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                return true
            default:
                return false
            }
        }
    }

    /// Columns of a line as the mono box draws it.
    static func columns(_ line: Substring) -> Int {
        line.unicodeScalars.reduce(0) { $0 + ($1 == "\t" ? tabWidth : 1) }
    }

    static func hasLongRuns(_ lines: [Substring]) -> Bool {
        var blanks = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blanks += 1
                if blanks > maxBlankRun { return true }
            } else {
                blanks = 0
            }
            var run = 0
            for scalar in line.unicodeScalars {
                run = scalar == " " || scalar == "\t" ? run + 1 : 0
                if run > maxSpaceRun { return true }
            }
        }
        return false
    }

    static func fits(_ lines: [Substring], columns: Int, lineCount: Int) -> Bool {
        lines.count <= lineCount && lines.allSatisfy { Self.columns($0) <= columns }
    }

    /// The rule, applied to a permission request.
    static func permission(tool: String, input: [String: Any], cwd: String?, isInputExact: Bool) -> Fit {
        let shown = detail(tool: tool, input: input, cwd: cwd).text
        let strings = allStrings(input) + [shown]
        let charactersOK = tool == "Bash"
            ? isPlainASCII(input["command"] as? String ?? "") && strings.allSatisfy(isShowable)
            : strings.allSatisfy(isShowable)
        return judge(shown, charactersOK: charactersOK, isInputExact: isInputExact)
    }

    /// The rule, applied to a question: its text and options are what the card shows; any other key of
    /// the input is shown as JSON below.
    static func question(input: [String: Any], isInputExact: Bool) -> Fit {
        let questions = AskRequest.parseQuestions(input)
        var lines = questions.first.map { [$0.question] + $0.options.map { "- " + $0 } } ?? []
        let rest = input.filter { $0.key != "questions" }
        if !rest.isEmpty { lines.append(compactJSON(rest) ?? "?") }
        let shown = lines.joined(separator: "\n")
        return judge(shown, charactersOK: (allStrings(input) + [shown]).allSatisfy(isShowable), isInputExact: isInputExact)
    }

    static func judge(_ shown: String, charactersOK: Bool, isInputExact: Bool) -> Fit {
        let lines = shown.split(separator: "\n", omittingEmptySubsequences: false)
        var reason: String?
        if !isInputExact { reason = "Answer this one in the terminal" }
        else if !charactersOK { reason = "Answer this one in the terminal: it has characters the card can't show plainly" }
        else if hasLongRuns(lines) || shown.hasPrefix("\n") || shown.hasSuffix("\n") { reason = "Answer this one in the terminal: it has long blank runs" }
        else if !fits(lines, columns: fullColumns, lineCount: fullLines) { reason = "Answer this one in the terminal: it's too long to show here in full" }
        let isAnswerable = reason == nil
        return Fit(
            detail: isAnswerable ? shown : "", isAnswerable: isAnswerable,
            fitsCompact: isAnswerable && fits(lines, columns: compactColumns, lineCount: compactLines), reason: reason
        )
    }
}
