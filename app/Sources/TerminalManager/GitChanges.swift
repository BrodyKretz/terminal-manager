import Foundation

struct FileChange: Equatable {
    var path: String
    var add: Int
    var del: Int
    var isBinary = false

    var bridgeObject: [String: Any] {
        ["path": path, "add": add, "del": del, "binary": isBinary]
    }
}

/// The files a finished turn leaves changed: `git diff --numstat HEAD` plus untracked files when the
/// folder is a repo, otherwise the files Claude's Edit and Write calls named this turn.
enum GitChanges {
    static let gitPath = "/usr/bin/git"
    static let maxFiles = 50
    static let maxUntrackedBytes = 1 << 20

    static func changes(in dir: String) -> [FileChange]? {
        let environment = ["GIT_OPTIONAL_LOCKS": "0", "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let inside = ProcessRunner.run([gitPath, "-C", dir, "rev-parse", "--is-inside-work-tree"], environment: environment, timeout: 5)
        guard inside.isSuccess, inside.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return nil }
        var diff = ProcessRunner.run([gitPath, "-C", dir, "diff", "--numstat", "HEAD", "--relative"], environment: environment, timeout: 10)
        if !diff.isSuccess {
            diff = ProcessRunner.run([gitPath, "-C", dir, "diff", "--numstat", "--relative"], environment: environment, timeout: 10)
        }
        var files = parseNumstat(diff.output)
        let untracked = ProcessRunner.run([gitPath, "-C", dir, "ls-files", "--others", "--exclude-standard"], environment: environment, timeout: 10)
        for path in untracked.output.split(separator: "\n").prefix(maxFiles) {
            files.append(untrackedChange(String(path), in: dir))
        }
        return Array(files.prefix(maxFiles))
    }

    /// `12\t3\tpath` lines; `-\t-\tpath` is a binary file.
    static func parseNumstat(_ output: String) -> [FileChange] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            if parts[0] == "-", parts[1] == "-" { return FileChange(path: String(parts[2]), add: 0, del: 0, isBinary: true) }
            guard let add = Int(parts[0]), let del = Int(parts[1]) else { return nil }
            return FileChange(path: String(parts[2]), add: add, del: del)
        }
    }

    static func untrackedChange(_ path: String, in dir: String) -> FileChange {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(path)
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: maxUntrackedBytes) else {
            return FileChange(path: path, add: 0, del: 0)
        }
        try? handle.close()
        if data.contains(0) { return FileChange(path: path, add: 0, del: 0, isBinary: true) }
        return FileChange(path: path, add: lineCount(data), del: 0)
    }

    static func lineCount(_ data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        let newlines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        return data.last == 0x0A ? newlines : newlines + 1
    }

    /// Outside a repo: what an Edit, MultiEdit or Write call says it changes.
    static func toolChange(tool: String, input: [String: Any], cwd: String?) -> FileChange? {
        guard let path = BridgeValue.string(input["file_path"]) else { return nil }
        let shown = ToolSubject.relative(path, to: cwd)
        func lines(_ key: String, in object: [String: Any] = input) -> Int {
            BridgeValue.string(object[key]).map { GitChanges.lineCount(Data($0.utf8)) } ?? 0
        }
        switch tool {
        case "Write": return FileChange(path: shown, add: lines("content"), del: 0)
        case "Edit": return FileChange(path: shown, add: lines("new_string"), del: lines("old_string"))
        case "MultiEdit":
            let edits = (input["edits"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            return FileChange(path: shown, add: edits.map { lines("new_string", in: $0) }.reduce(0, +), del: edits.map { lines("old_string", in: $0) }.reduce(0, +))
        default: return nil
        }
    }

    static func merge(_ change: FileChange, into files: inout [FileChange]) {
        if let index = files.firstIndex(where: { $0.path == change.path }) {
            files[index].add += change.add
            files[index].del += change.del
        } else {
            files.append(change)
        }
    }
}
