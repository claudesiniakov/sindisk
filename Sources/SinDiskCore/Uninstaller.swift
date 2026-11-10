import Foundation

public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bundleID: String
    public let version: String?
    public let isAppStore: Bool
    public var bundleSize: Int64 = 0
    public var lastUsed: Date?
}

public struct AppFile: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case bundle, support, cache, preferences, container, groupContainer, savedState, webData, logs, launchAgent, scripts

        public var title: String {
            switch self {
            case .bundle: return "Приложение"
            case .support: return "Данные (Application Support)"
            case .cache: return "Кэш"
            case .preferences: return "Настройки"
            case .container: return "Контейнер песочницы"
            case .groupContainer: return "Общий контейнер"
            case .savedState: return "Сохранённое состояние окон"
            case .webData: return "Веб-данные"
            case .logs: return "Логи"
            case .launchAgent: return "Агент автозапуска"
            case .scripts: return "Скрипты"
            }
        }
    }

    public var id: String { path }
    public let path: String
    public let size: Int64
    public let kind: Kind
    public let isDirectory: Bool

    public var name: String { (path as NSString).lastPathComponent }
}

/// Поиск установленных приложений и всего, что они оставляют в ~/Library.
public struct AppUninstaller: Sendable {
    public let home: String
    public let appDirectories: [String]

    public init(home: String = NSHomeDirectory(), appDirectories: [String]? = nil) {
        self.home = home
        self.appDirectories = appDirectories ?? ["/Applications", home + "/Applications"]
    }

    // MARK: - Список приложений

    /// Приложения из /Applications и ~/Applications (и их подпапок первого уровня), кроме приложений Apple.
    public func installedApps() -> [InstalledApp] {
        var seen = Set<String>()
        var result: [InstalledApp] = []
        let fm = FileManager.default
        for dir in appDirectories {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                let path = dir + "/" + entry
                if entry.hasSuffix(".app") {
                    if seen.insert(path).inserted, let app = Self.readApp(path) { result.append(app) }
                } else if let sub = try? fm.contentsOfDirectory(atPath: path) {
                    for s in sub where s.hasSuffix(".app") {
                        let p = path + "/" + s
                        if seen.insert(p).inserted, let app = Self.readApp(p) { result.append(app) }
                    }
                }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func readApp(_ path: String) -> InstalledApp? {
        guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
              let bundleID = info["CFBundleIdentifier"] as? String,
              !bundleID.hasPrefix("com.apple.") else { return nil }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return InstalledApp(
            path: path,
            name: name,
            bundleID: bundleID,
            version: info["CFBundleShortVersionString"] as? String,
            isAppStore: FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt")
        )
    }

    /// Размер бандла и дата последнего запуска (по данным Spotlight).
    public static func measure(_ app: InstalledApp) -> InstalledApp {
        var a = app
        a.bundleSize = DiskScanner().scan(path: app.path).size
        a.lastUsed = NSMetadataItem(url: URL(fileURLWithPath: app.path))?
            .value(forAttribute: "kMDItemLastUsedDate") as? Date
        return a
    }

    // MARK: - Остатки

    static let locations: [(String, AppFile.Kind, Bool)] = [
        ("Application Support", .support, true),
        ("Caches", .cache, true),
        ("Preferences", .preferences, true),
        ("Containers", .container, true),
        ("Saved Application State", .savedState, true),
        ("HTTPStorages", .webData, true),
        ("WebKit", .webData, true),
        ("Logs", .logs, false),
        ("LaunchAgents", .launchAgent, true),
        ("Application Scripts", .scripts, true),
    ]

    /// Бандл приложения и связанные с ним файлы в ~/Library.
    public func files(for app: InstalledApp) -> [AppFile] {
        var out: [AppFile] = [
            AppFile(path: app.path, size: app.bundleSize > 0 ? app.bundleSize : Self.size(of: app.path),
                    kind: .bundle, isDirectory: true),
        ]
        let fm = FileManager.default
        let library = home + "/Library"
        let bid = app.bundleID.lowercased()
        let names: Set<String> = [bid, app.name.lowercased()]

        for (rel, kind, allowPrefix) in Self.locations {
            let dir = library + "/" + rel
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where Self.matches(entry, names: names, bundleID: bid, allowPrefix: allowPrefix) {
                out.append(Self.file(dir + "/" + entry, kind: kind))
            }
        }
        // Общие контейнеры называются «TEAMID.bundle.id» или «group.bundle.id».
        if let entries = try? fm.contentsOfDirectory(atPath: library + "/Group Containers") {
            for entry in entries where entry.lowercased().hasSuffix("." + bid) || entry.lowercased() == "group." + bid {
                out.append(Self.file(library + "/Group Containers/" + entry, kind: .groupContainer))
            }
        }
        return out
    }

    static func matches(_ entry: String, names: Set<String>, bundleID: String, allowPrefix: Bool) -> Bool {
        let e = entry.lowercased()
        let stem = (e as NSString).deletingPathExtension
        if names.contains(e) || names.contains(stem) { return true }
        return allowPrefix && e.hasPrefix(bundleID + ".")
    }

    static func file(_ path: String, kind: AppFile.Kind) -> AppFile {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return AppFile(path: path, size: size(of: path), kind: kind, isDirectory: isDir.boolValue)
    }

    static func size(of path: String) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if isDir.boolValue { return DiskScanner().scan(path: path).size }
        let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
    }
}
