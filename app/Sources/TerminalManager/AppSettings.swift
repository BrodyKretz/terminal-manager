import Foundation

/// settings.json: the preferences the window's Settings and the menu bar share, and the folders used.
struct AppSettings: Codable, Equatable {
    static let maxRecentDirs = 30

    var notificationsEnabled = true
    var doNotDisturb = false
    /// Open at login is switched on once, at the first launch of the installed app; after that only the toggle changes it.
    var hasSetUpOpenAtLogin = false
    var recentDirs: [String] = []

    mutating func noteUsed(_ dir: String) {
        recentDirs.removeAll { $0 == dir }
        recentDirs.insert(dir, at: 0)
        if recentDirs.count > Self.maxRecentDirs { recentDirs.removeLast(recentDirs.count - Self.maxRecentDirs) }
    }

    static func load(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url), let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(self), to: url.path)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        doNotDisturb = try container.decodeIfPresent(Bool.self, forKey: .doNotDisturb) ?? false
        hasSetUpOpenAtLogin = try container.decodeIfPresent(Bool.self, forKey: .hasSetUpOpenAtLogin) ?? false
        recentDirs = try container.decodeIfPresent([String].self, forKey: .recentDirs) ?? []
    }
}

/// The folder picker's suggestions: every folder in ~/work, the ones used from this app first (most
/// recent first), then the rest by when they last changed.
enum FolderSuggestions {
    static func list(recent: [String], workFolder: String, fileManager: FileManager = .default) -> [String] {
        var modified: [(path: String, date: Date)] = []
        if let names = try? fileManager.contentsOfDirectory(atPath: workFolder) {
            for name in names where !name.hasPrefix(".") {
                let path = workFolder + "/" + name
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                let date = (try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                modified.append((path, date))
            }
        }
        return order(recent: recent, folders: modified)
    }

    static func order(recent: [String], folders: [(path: String, date: Date)]) -> [String] {
        let rest = folders.filter { !recent.contains($0.path) }.sorted { $0.date == $1.date ? $0.path < $1.path : $0.date > $1.date }.map(\.path)
        return recent + rest
    }
}
