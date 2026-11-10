import Foundation

/// Последняя линия защиты: каждый путь проверяется здесь перед удалением.
public struct SafetyGuard: Sendable {
    public enum Verdict: Equatable, Sendable {
        case allowed
        case protected(String)

        public var isAllowed: Bool { self == .allowed }

        public var reason: String? {
            if case let .protected(r) = self { return r }
            return nil
        }
    }

    public let home: String
    public let ownBundlePath: String?

    public init(home: String = NSHomeDirectory(), ownBundlePath: String? = SafetyGuard.currentBundlePath) {
        self.home = SafetyGuard.normalize(home)
        self.ownBundlePath = ownBundlePath
    }

    public static var currentBundlePath: String? {
        let p = Bundle.main.bundlePath
        return p.hasSuffix(".app") ? p : nil
    }

    static let systemPrefixes = [
        "/System", "/usr", "/bin", "/sbin", "/private/var/db", "/var/db", "/Library/Apple",
        "/private/etc", "/etc", "/private/var/vm", "/var/vm",
    ]
    static let systemExceptions = ["/usr/local"]

    var exactProtected: Set<String> {
        var s: Set<String> = [
            "/", "/Users", "/Applications", "/Library", "/private", "/private/var", "/private/tmp",
            "/tmp", "/var", "/opt", "/usr/local", "/Applications/Utilities",
        ]
        let homeRoots = [
            "", "/Documents", "/Desktop", "/Downloads", "/Pictures", "/Movies", "/Music", "/Public",
            "/Applications", "/Library", "/Library/Caches", "/Library/Logs", "/Library/Application Support",
            "/Library/Developer", "/Library/Containers", "/Library/Group Containers", "/.Trash",
            "/Library/Mobile Documents",
        ]
        for r in homeRoots { s.insert(home + r) }
        return s
    }

    var personalSubtrees: [String] {
        [
            "/Library/Keychains", "/Library/Messages", "/Library/Mail", "/Library/Accounts",
            "/Library/Group Containers/group.com.apple.notes", "/Library/Preferences",
            "/Library/Cookies", "/Library/Safari",
        ].map { home + $0 } + ["/Library/Keychains"]
    }

    public func check(_ rawPath: String) -> Verdict {
        guard rawPath.hasPrefix("/") else { return .protected("Некорректный путь") }
        let path = Self.normalize(rawPath)

        if exactProtected.contains(path) {
            return .protected("Корневая папка «\((path as NSString).lastPathComponent)» не удаляется целиком")
        }
        for p in Self.systemPrefixes where Self.isInside(path, p) {
            if Self.systemExceptions.contains(where: { Self.isInside(path, $0) }) { break }
            return .protected("Системная область \(p)")
        }
        for p in personalSubtrees where Self.isInside(path, p) {
            return .protected("Защищённые личные данные")
        }
        if path.split(separator: "/").contains(where: { $0.hasSuffix(".photoslibrary") }) {
            return .protected("Медиатека «Фото» — удаление только через приложение «Фото»")
        }
        if let own = ownBundlePath, Self.isInside(path, Self.normalize(own)) {
            return .protected("Файлы самого SinDisk")
        }
        return .allowed
    }

    public static func isInside(_ path: String, _ prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
    }

    /// Нормализует путь: убирает `.`/`..`, раскрывает символические ссылки в родительских каталогах
    /// (сам элемент не раскрывается — удаляется ссылка, а не её цель).
    public static func normalize(_ raw: String) -> String {
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        var path = url.path
        if path == "/" || path.isEmpty { return "/" }
        if path.hasSuffix("/") { path.removeLast() }
        let parent = (path as NSString).deletingLastPathComponent
        let last = (path as NSString).lastPathComponent
        var resolvedParent = parent
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(parent, &buffer) != nil {
            resolvedParent = String(cString: buffer)
        }
        return resolvedParent == "/" ? "/" + last : resolvedParent + "/" + last
    }
}
