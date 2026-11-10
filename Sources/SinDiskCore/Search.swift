import Foundation

/// Запрос поиска: текст + фильтры-токены (`size:>1GB`, `ext:dmg`, `kind:video`, `modified:<30d`,
/// `opened:>1y`, `in:~/Downloads`, `-in:~/Projects`, `type:file`), маски `*.mov` и `/regex/`.
public struct SearchQuery: Equatable, Sendable {
    public var terms: [String] = []
    public var globs: [String] = []
    public var regexes: [String] = []
    public var minSize: Int64?
    public var maxSize: Int64?
    public var extensions: Set<String> = []
    public var kinds: Set<FileKind> = []
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var openedAfter: Date?
    public var openedBefore: Date?
    public var inPaths: [String] = []
    public var notInPaths: [String] = []
    /// true — только файлы, false — только папки, nil — по умолчанию.
    public var onlyFiles: Bool?
    public var errors: [String] = []

    public init() {}

    public var hasNameCriteria: Bool { !terms.isEmpty || !globs.isEmpty || !regexes.isEmpty }

    public var isEmpty: Bool {
        !hasNameCriteria && minSize == nil && maxSize == nil && extensions.isEmpty && kinds.isEmpty
            && modifiedAfter == nil && modifiedBefore == nil && openedAfter == nil && openedBefore == nil
            && inPaths.isEmpty && onlyFiles == nil
    }

    public static func parse(_ input: String, now: Date = Date(), home: String = NSHomeDirectory()) -> SearchQuery {
        var q = SearchQuery()
        for token in tokenize(input) {
            let lower = token.lowercased()
            if let colon = lower.firstIndex(of: ":"), colon != lower.startIndex {
                let key = String(lower[..<colon])
                let value = String(token[token.index(after: colon)...])
                if q.apply(key: key, value: value, now: now, home: home) { continue }
            }
            if token.count > 2, token.hasPrefix("/"), token.hasSuffix("/") {
                q.regexes.append(String(token.dropFirst().dropLast()))
            } else if token.contains("*") || token.contains("?") {
                q.globs.append(token)
            } else {
                q.terms.append(fold(token))
            }
        }
        return q
    }

    private mutating func apply(key: String, value: String, now: Date, home: String) -> Bool {
        switch key {
        case "size", "размер":
            guard let range = Self.parseRange(value, ByteFormat.parse) else {
                errors.append("Не понял размер «\(value)»")
                return true
            }
            minSize = range.0
            maxSize = range.1
        case "ext", "расширение":
            for e in value.split(separator: ",") {
                extensions.insert(e.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased())
            }
        case "kind", "тип":
            for k in value.split(separator: ",") {
                if let kind = FileKind.parse(String(k)) { kinds.insert(kind) } else { errors.append("Неизвестный тип «\(k)»") }
            }
        case "type":
            switch value.lowercased() {
            case "file", "файл", "f": onlyFiles = true
            case "dir", "folder", "папка", "d": onlyFiles = false
            default: errors.append("type: file или dir")
            }
        case "modified", "изменён", "изменен":
            guard let range = Self.parseDates(value, now: now) else {
                errors.append("Не понял дату «\(value)»")
                return true
            }
            modifiedAfter = range.0
            modifiedBefore = range.1
        case "opened", "открыт":
            guard let range = Self.parseDates(value, now: now) else {
                errors.append("Не понял дату «\(value)»")
                return true
            }
            openedAfter = range.0
            openedBefore = range.1
        case "in", "в":
            inPaths.append(Self.expand(value, home: home))
        case "-in":
            notInPaths.append(Self.expand(value, home: home))
        default:
            return false
        }
        return true
    }

    // MARK: - Разбор значений

    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for ch in s {
            if ch == "\"" {
                quoted.toggle()
            } else if ch.isWhitespace, !quoted {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func expand(_ path: String, home: String) -> String {
        var p = path
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// `>X`, `>=X`, `<X`, `<=X`, `X..Y`, `X` (как `>=X`).
    static func parseRange<T>(_ raw: String, _ parse: (String) -> T?) -> (T?, T?)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: "..") {
            guard let lo = parse(String(s[..<r.lowerBound])), let hi = parse(String(s[r.upperBound...])) else { return nil }
            return (lo, hi)
        }
        for op in [">=", "<=", ">", "<"] where s.hasPrefix(op) {
            guard let v = parse(String(s.dropFirst(op.count))) else { return nil }
            return op.hasPrefix(">") ? (v, nil) : (nil, v)
        }
        guard let v = parse(s) else { return nil }
        return (v, nil)
    }

    /// Даты: абсолютные (`<2025-01-01`) или возраст (`>30d` — старше 30 дней, `<1w` — моложе недели).
    static func parseDates(_ raw: String, now: Date) -> (Date?, Date?)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let age = parseAgeExpression(s, now: now) { return age }
        return parseRange(s) { parseISODate($0) }
    }

    private static func parseAgeExpression(_ s: String, now: Date) -> (Date?, Date?)? {
        var op = ""
        var rest = Substring(s)
        for candidate in [">=", "<=", ">", "<"] where rest.hasPrefix(candidate) {
            op = candidate
            rest = rest.dropFirst(candidate.count)
            break
        }
        guard let unit = rest.last, let n = Double(rest.dropLast()) else { return nil }
        let day = 86_400.0
        let seconds: Double
        switch unit {
        case "d", "д": seconds = n * day
        case "w", "н": seconds = n * 7 * day
        case "m", "м": seconds = n * 30 * day
        case "y", "г": seconds = n * 365 * day
        default: return nil
        }
        let edge = now.addingTimeInterval(-seconds)
        // «>30d» — старше 30 дней, значит дата раньше границы.
        if op.hasPrefix("<") { return (edge, nil) }
        return (nil, edge)
    }

    static func parseISODate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    public static func fold(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

public struct SearchHit: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let size: Int64
    public let modified: Date?
    public let isDirectory: Bool
    public let kind: FileKind

    public var directory: String { (path as NSString).deletingLastPathComponent }
}

/// Сопоставление узлов дерева с запросом.
public struct SearchMatcher {
    public let query: SearchQuery
    private let compiled: [NSRegularExpression]

    public init(_ query: SearchQuery) {
        self.query = query
        var regs: [NSRegularExpression] = []
        for g in query.globs {
            let pattern = "^" + NSRegularExpression.escapedPattern(for: g)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".") + "$"
            if let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) { regs.append(r) }
        }
        for r in query.regexes {
            if let re = try? NSRegularExpression(pattern: r, options: [.caseInsensitive]) { regs.append(re) }
        }
        compiled = regs
    }

    public func matches(_ node: FileNode) -> Bool {
        let q = query
        if node.isDirectory {
            if q.onlyFiles == true { return false }
            if q.onlyFiles == nil, !q.hasNameCriteria, q.kinds.isDisjoint(with: [.folder, .app]) { return false }
        } else if q.onlyFiles == false {
            return false
        }
        if let lo = q.minSize, node.size < lo { return false }
        if let hi = q.maxSize, node.size > hi { return false }
        if !q.extensions.isEmpty, !q.extensions.contains(node.fileExtension) { return false }
        if !q.kinds.isEmpty, !q.kinds.contains(node.kind) { return false }
        if q.modifiedAfter != nil || q.modifiedBefore != nil {
            guard let m = node.modified else { return false }
            if let a = q.modifiedAfter, m < a { return false }
            if let b = q.modifiedBefore, m > b { return false }
        }
        if q.openedAfter != nil || q.openedBefore != nil {
            guard let o = node.accessed ?? node.modified else { return false }
            if let a = q.openedAfter, o < a { return false }
            if let b = q.openedBefore, o > b { return false }
        }
        if !q.terms.isEmpty || !compiled.isEmpty {
            let name = node.name
            if !q.terms.isEmpty {
                let folded = SearchQuery.fold(name)
                for t in q.terms where !folded.contains(t) { return false }
            }
            let range = NSRange(name.startIndex..., in: name)
            for r in compiled where r.firstMatch(in: name, range: range) == nil { return false }
        }
        return true
    }
}

public enum SearchEngine {
    public static func search(
        root: FileNode,
        query: SearchQuery,
        limit: Int = 5000,
        isCancelled: () -> Bool = { false }
    ) -> [SearchHit] {
        guard !query.isEmpty else { return [] }
        return TreeAccess.read { searchUnlocked(root: root, query: query, limit: limit, isCancelled: isCancelled) }
    }

    private static func searchUnlocked(root: FileNode, query: SearchQuery, limit: Int, isCancelled: () -> Bool) -> [SearchHit] {
        let matcher = SearchMatcher(query)
        var found: [(FileNode, String)] = []
        var stack: [(FileNode, String)] = [(root, root.path)]
        var visited = 0

        while let item = stack.popLast() {
            let (dir, dirPath) = item
            visited += 1
            if visited % 4096 == 0, isCancelled() { return [] }
            for c in dir.children {
                let p = dirPath.hasSuffix("/") ? dirPath + c.name : dirPath + "/" + c.name
                if query.notInPaths.contains(where: { SafetyGuard.isInside(p, $0) }) { continue }
                let insideScope = query.inPaths.isEmpty || query.inPaths.contains { SafetyGuard.isInside(p, $0) }
                if insideScope, matcher.matches(c) { found.append((c, p)) }
                if c.isDirectory {
                    let leadsToScope = insideScope || query.inPaths.contains { SafetyGuard.isInside($0, p) }
                    if leadsToScope { stack.append((c, p)) }
                }
            }
        }
        found.sort { $0.0.size > $1.0.size }
        return found.prefix(limit).map { node, path in
            SearchHit(path: path, name: node.name, size: node.size, modified: node.modified,
                      isDirectory: node.isDirectory, kind: node.kind)
        }
    }
}
