import Foundation

public enum CleanMode: Codable, Hashable, Sendable {
    /// Переместить в Корзину (можно отменить).
    case trash
    /// Удалить без Корзины.
    case permanent
    /// Заменить файл APFS-клоном указанного файла: путь сохраняется, данные общие.
    case cloneOf(String)
}

public struct CleanRequest: Sendable, Hashable {
    public let path: String
    public let size: Int64
    public let mode: CleanMode
    /// Для файлов: дата изменения на момент анализа. Если файл изменился — он пропускается.
    public let expectedModified: Date?

    public init(path: String, size: Int64, mode: CleanMode = .trash, expectedModified: Date? = nil) {
        self.path = path
        self.size = size
        self.mode = mode
        self.expectedModified = expectedModified
    }
}

public struct CleanRecord: Codable, Identifiable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case done, skipped, failed, restored }

    public var id: UUID
    public let originalPath: String
    public var trashedPath: String?
    public let size: Int64
    public let mode: CleanMode
    public var status: Status
    public var message: String?

    public init(id: UUID = UUID(), originalPath: String, trashedPath: String? = nil, size: Int64,
                mode: CleanMode, status: Status, message: String? = nil) {
        self.id = id
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.size = size
        self.mode = mode
        self.status = status
        self.message = message
    }
}

public struct CleanSession: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public let date: Date
    public let title: String
    public var records: [CleanRecord]
    public var undone: Bool

    public init(id: UUID = UUID(), date: Date = Date(), title: String, records: [CleanRecord], undone: Bool = false) {
        self.id = id
        self.date = date
        self.title = title
        self.records = records
        self.undone = undone
    }

    public var freed: Int64 {
        records.filter { $0.status == .done }.reduce(0) { $0 + $1.size }
    }

    public var doneCount: Int { records.filter { $0.status == .done }.count }
    public var problems: [CleanRecord] { records.filter { $0.status == .failed || $0.status == .skipped } }

    public var canUndo: Bool {
        !undone && records.contains { $0.status == .done && $0.trashedPath != nil }
    }
}

/// Журнал сессий очистки (JSON-файлы, хранение 90 дней).
public final class SessionStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("SinDisk/Sessions", isDirectory: true)
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func save(_ session: CleanSession) {
        lock.lock()
        defer { lock.unlock() }
        let url = directory.appendingPathComponent("\(session.id.uuidString).json")
        if let data = try? encoder.encode(session) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public func load() -> [CleanSession] {
        lock.lock()
        defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(CleanSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    public func prune(olderThan days: Int = 90, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        for s in load() where s.date < cutoff {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(s.id.uuidString).json"))
        }
    }
}

/// Выполняет удаление: проверки SafetyGuard, перепроверка файла, Корзина, журнал, откат.
public final class CleanEngine: @unchecked Sendable {
    public let safety: SafetyGuard
    public let store: SessionStore?
    private let fm = FileManager.default

    public init(safety: SafetyGuard = SafetyGuard(), store: SessionStore? = nil) {
        self.safety = safety
        self.store = store
    }

    public func clean(
        _ requests: [CleanRequest],
        title: String,
        progress: ((Int, Int) -> Void)? = nil
    ) -> CleanSession {
        var records: [CleanRecord] = []
        for (i, req) in requests.enumerated() {
            records.append(perform(req))
            progress?(i + 1, requests.count)
        }
        let session = CleanSession(id: UUID(), date: Date(), title: title, records: records, undone: false)
        store?.save(session)
        return session
    }

    private func perform(_ req: CleanRequest) -> CleanRecord {
        var record = CleanRecord(
            id: UUID(), originalPath: req.path, trashedPath: nil, size: req.size,
            mode: req.mode, status: .failed, message: nil
        )
        let verdict = safety.check(req.path)
        guard verdict.isAllowed else {
            record.message = verdict.reason
            return record
        }
        guard let attrs = try? fm.attributesOfItem(atPath: req.path) else {
            record.status = .skipped
            record.message = "Уже удалён"
            return record
        }
        if let expected = req.expectedModified, let actual = attrs[.modificationDate] as? Date,
           abs(actual.timeIntervalSince(expected)) > 1 {
            record.status = .skipped
            record.message = "Файл изменился после анализа"
            return record
        }

        do {
            switch req.mode {
            case .trash:
                record.trashedPath = try moveToTrash(req.path)
            case .permanent:
                try fm.removeItem(atPath: req.path)
            case let .cloneOf(keeper):
                record.trashedPath = try replaceWithClone(req.path, keeper: keeper)
            }
            record.status = .done
        } catch {
            record.message = error.localizedDescription
        }
        return record
    }

    private func moveToTrash(_ path: String) throws -> String? {
        var resulting: NSURL?
        try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        return resulting?.path
    }

    /// Клонирует `keeper` во временный файл, переносит метаданные дубликата, отправляет
    /// дубликат в Корзину и ставит клон на его место. Операцию можно отменить.
    private func replaceWithClone(_ path: String, keeper: String) throws -> String? {
        guard path != keeper else { throw CleanError("Файл совпадает с оставляемой копией") }
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = dir + "/.sindisk-clone-\(UUID().uuidString)"
        guard clonefile(keeper, tmp, 0) == 0 else {
            let code = errno
            if code == EXDEV { throw CleanError("Копии на разных томах — клонирование невозможно") }
            throw CleanError("Не удалось создать клон: \(String(cString: strerror(code)))")
        }
        // ACL + POSIX-атрибуты (права, даты) + расширенные атрибуты (теги Finder).
        let metadataFlags: copyfile_flags_t = (1 << 0) | (1 << 1) | (1 << 2)
        _ = copyfile(path, tmp, nil, metadataFlags)

        let trashed: String?
        do {
            trashed = try moveToTrash(path)
        } catch {
            unlink(tmp)
            throw error
        }
        guard rename(tmp, path) == 0 else {
            let message = String(cString: strerror(errno))
            if let trashed { try? fm.moveItem(atPath: trashed, toPath: path) }
            unlink(tmp)
            throw CleanError("Не удалось поставить клон на место: \(message)")
        }
        return trashed
    }

    /// Возвращает файлы сессии из Корзины на исходные места.
    public func undo(_ session: CleanSession) -> CleanSession {
        var updated = session
        for i in updated.records.indices {
            let r = updated.records[i]
            guard r.status == .done, let trashed = r.trashedPath else { continue }
            guard fm.fileExists(atPath: trashed) else {
                updated.records[i].message = "Файла уже нет в Корзине"
                continue
            }
            do {
                if case .cloneOf = r.mode, fm.fileExists(atPath: r.originalPath) {
                    try fm.removeItem(atPath: r.originalPath)
                }
                if fm.fileExists(atPath: r.originalPath) {
                    updated.records[i].message = "Исходный путь уже занят"
                    continue
                }
                let parent = (r.originalPath as NSString).deletingLastPathComponent
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: trashed, toPath: r.originalPath)
                updated.records[i].status = .restored
                updated.records[i].message = nil
            } catch {
                updated.records[i].message = error.localizedDescription
            }
        }
        updated.undone = true
        store?.save(updated)
        return updated
    }
}

public struct CleanError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
