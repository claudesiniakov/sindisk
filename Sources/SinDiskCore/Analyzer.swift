import Foundation

public enum Risk: Int, Comparable, Codable, Sendable, CaseIterable {
    case low, medium, high

    public static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .low: return "Низкий риск"
        case .medium: return "Средний риск"
        case .high: return "Высокий риск"
        }
    }
}

public enum CleanupCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case caches, logs, trash, xcode, devCaches, nodeModules, installers, oldDownloads,
         largeFiles, oldFiles, iosBackups, leftovers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .caches: return "Кэши приложений"
        case .logs: return "Логи и отчёты о сбоях"
        case .trash: return "Корзина"
        case .xcode: return "Xcode и симуляторы"
        case .devCaches: return "Кэши инструментов разработки"
        case .nodeModules: return "Папки node_modules"
        case .installers: return "Установщики в Загрузках"
        case .oldDownloads: return "Старые загрузки"
        case .largeFiles: return "Большие файлы"
        case .oldFiles: return "Давно не открывавшиеся файлы"
        case .iosBackups: return "Резервные копии iPhone/iPad"
        case .leftovers: return "Остатки удалённых приложений"
        }
    }

    public var detail: String {
        switch self {
        case .caches: return "Приложения создадут их заново при необходимости."
        case .logs: return "Журналы работы программ и отчёты о сбоях."
        case .trash: return "Удаляется окончательно, без возможности отмены."
        case .xcode: return "DerivedData пересобирается; архивы и DeviceSupport — по выбору."
        case .devCaches: return "npm, Gradle, Cargo и другие менеджеры пакетов скачают заново."
        case .nodeModules: return "Восстанавливаются командой npm install в проекте."
        case .installers: return "Образы .dmg/.pkg после установки программ обычно не нужны."
        case .oldDownloads: return "Файлы в Загрузках, которые давно не менялись."
        case .largeFiles: return "Проверьте каждый файл перед удалением."
        case .oldFiles: return "Крупные файлы, которые не открывались больше года."
        case .iosBackups: return "Локальные резервные копии устройств из Finder."
        case .leftovers: return "Данные программ, которых больше нет на Mac."
        }
    }

    public var risk: Risk {
        switch self {
        case .caches, .logs, .trash: return .low
        case .xcode, .devCaches, .nodeModules, .installers, .oldDownloads, .leftovers: return .medium
        case .largeFiles, .oldFiles, .iosBackups: return .high
        }
    }

    /// Корзину нельзя переместить в Корзину — она удаляется окончательно.
    public var deletesPermanently: Bool { self == .trash }
}

public struct Candidate: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let size: Int64
    public let category: CleanupCategory
    public let selectedByDefault: Bool
    public let note: String?
    public let modified: Date?
    public let isDirectory: Bool

    public var name: String { (path as NSString).lastPathComponent }
}

public struct CategoryResult: Identifiable, Sendable {
    public var id: CleanupCategory { category }
    public let category: CleanupCategory
    public var items: [Candidate]
    public var total: Int64 { items.reduce(0) { $0 + $1.size } }
}

public struct AnalyzerSettings: Sendable {
    public var largeFileBytes: Int64
    public var oldFileAge: TimeInterval
    public var oldFileMinBytes: Int64
    public var oldDownloadsAge: TimeInterval

    public init(
        largeFileBytes: Int64 = 500_000_000,
        oldFileAge: TimeInterval = 365 * 86_400,
        oldFileMinBytes: Int64 = 50_000_000,
        oldDownloadsAge: TimeInterval = 90 * 86_400
    ) {
        self.largeFileBytes = largeFileBytes
        self.oldFileAge = oldFileAge
        self.oldFileMinBytes = oldFileMinBytes
        self.oldDownloadsAge = oldDownloadsAge
    }
}

/// Раскладывает найденное по категориям очистки.
public struct Analyzer: Sendable {
    public let home: String
    public let settings: AnalyzerSettings
    public let safety: SafetyGuard
    public let appInstalled: @Sendable (String) -> Bool

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]

    public init(
        home: String = NSHomeDirectory(),
        settings: AnalyzerSettings = AnalyzerSettings(),
        safety: SafetyGuard? = nil,
        appInstalled: @escaping @Sendable (String) -> Bool = { _ in true }
    ) {
        self.home = home
        self.settings = settings
        self.safety = safety ?? SafetyGuard(home: home)
        self.appInstalled = appInstalled
    }

    public func analyze(tree: FileNode?, now: Date = Date()) -> [CategoryResult] {
        var results: [CleanupCategory: [Candidate]] = [:]
        func add(_ c: Candidate?) {
            guard let c else { return }
            results[c.category, default: []].append(c)
        }

        // Кэши: по папке на приложение. Системные кэши Apple не отмечаются по умолчанию.
        for c in children("Library/Caches", tree) {
            add(make(c, .caches, selected: !c.name.hasPrefix("com.apple.")))
        }
        for c in children("Library/Logs", tree) { add(make(c, .logs, selected: true)) }
        for c in children(".Trash", tree) { add(make(c, .trash, selected: true)) }

        for c in children("Library/Developer/Xcode/DerivedData", tree) {
            add(make(c, .xcode, selected: true, note: "DerivedData"))
        }
        for c in children("Library/Developer/Xcode/Archives", tree) {
            add(make(c, .xcode, selected: false, note: "Архив сборок"))
        }
        for c in children("Library/Developer/Xcode/iOS DeviceSupport", tree) {
            add(make(c, .xcode, selected: false, note: "Символы устройства"))
        }
        if let n = node("Library/Developer/CoreSimulator/Caches", tree) {
            add(make(n, .xcode, selected: false, note: "Кэш симуляторов"))
        }

        for rel in [".npm/_cacache", ".gradle/caches", ".cargo/registry/cache", ".pub-cache", "go/pkg/mod/cache", ".cache"] {
            if let n = node(rel, tree) { add(make(n, .devCaches, selected: false, note: "~/" + rel)) }
        }

        if let downloads = node("Downloads", tree) {
            let cutoff = now.addingTimeInterval(-settings.oldDownloadsAge)
            for c in downloads.children where c.size > 0 {
                if !c.isDirectory, Self.installerExtensions.contains(c.fileExtension) {
                    add(make(c, .installers, selected: true))
                } else if let m = c.modified, m < cutoff {
                    add(make(c, .oldDownloads, selected: false))
                }
            }
        }

        for c in children("Library/Application Support/MobileSync/Backup", tree) {
            add(make(c, .iosBackups, selected: false))
        }

        if let support = node("Library/Application Support", tree) {
            for c in support.children where c.isDirectory && c.size > 0 && Self.looksLikeBundleID(c.name) {
                if !c.name.hasPrefix("com.apple."), !appInstalled(c.name) {
                    add(make(c, .leftovers, selected: false, note: "Приложение \(c.name) не найдено"))
                }
            }
        }

        if let tree { walkTree(tree, now: now, add: add) }

        return CleanupCategory.allCases.compactMap { cat in
            guard var items = results[cat], !items.isEmpty else { return nil }
            items.sort { $0.size > $1.size }
            return CategoryResult(category: cat, items: items)
        }
    }

    // MARK: - Обход дерева: node_modules, большие и старые файлы

    private func walkTree(_ tree: FileNode, now: Date, add: (Candidate?) -> Void) {
        let homeLibrary = home + "/Library"
        let ageCutoff = now.addingTimeInterval(-settings.oldFileAge)
        var large: [FileNode] = []
        var old: [FileNode] = []
        var stack: [(FileNode, String)] = [(tree, tree.path)]

        while let item = stack.popLast() {
            let (dir, dirPath) = item
            let inHome = SafetyGuard.isInside(dirPath, home)
            let inLibrary = SafetyGuard.isInside(dirPath, homeLibrary)
            let hidden = dirPath.contains("/.")
            for c in dir.children {
                if c.isDirectory {
                    let childPath = dirPath.hasSuffix("/") ? dirPath + c.name : dirPath + "/" + c.name
                    if c.name == "node_modules" {
                        if inHome, !inLibrary, !hidden, c.size > 0 {
                            let project = (dirPath as NSString).lastPathComponent
                            add(make(c, .nodeModules, selected: false, note: "Проект «\(project)»"))
                        }
                        continue
                    }
                    if c.isPackage { continue }
                    stack.append((c, childPath))
                } else if !c.isSymlink {
                    if c.size >= settings.largeFileBytes {
                        large.append(c)
                    } else if inHome, !inLibrary, !hidden, c.size >= settings.oldFileMinBytes,
                              let last = c.accessed ?? c.modified, last < ageCutoff {
                        old.append(c)
                    }
                }
            }
        }
        for n in large.sorted(by: { $0.size > $1.size }).prefix(200) {
            add(make(n, .largeFiles, selected: false))
        }
        for n in old.sorted(by: { $0.size > $1.size }).prefix(200) {
            add(make(n, .oldFiles, selected: false))
        }
    }

    // MARK: - Помощники

    private func node(_ relative: String, _ tree: FileNode?) -> FileNode? {
        let path = home + "/" + relative
        if let tree, let n = tree.node(atPath: path) { return n }
        if let tree, SafetyGuard.isInside(path, tree.path) {
            // Путь внутри отсканированной области, но его нет в дереве — значит, его нет на диске.
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return DiskScanner().scan(path: path)
    }

    private func children(_ relative: String, _ tree: FileNode?) -> [FileNode] {
        node(relative, tree)?.children.filter { $0.size > 0 } ?? []
    }

    private func make(_ n: FileNode, _ category: CleanupCategory, selected: Bool, note: String? = nil) -> Candidate? {
        let p = n.path
        guard safety.check(p).isAllowed else { return nil }
        return Candidate(
            path: p, size: n.size, category: category, selectedByDefault: selected,
            note: note, modified: n.modified, isDirectory: n.isDirectory
        )
    }

    static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        return parts.count >= 3 && !name.contains(" ") && parts.allSatisfy { !$0.isEmpty }
    }
}
