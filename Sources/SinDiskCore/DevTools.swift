import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public var ok: Bool { status == 0 && !timedOut }

    /// Последние строки вывода — для сообщений об ошибках.
    public var tail: String {
        let text = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(separator: "\n").suffix(4).joined(separator: "\n")
    }
}

/// Запуск консольных утилит с тайм-аутом и захватом вывода.
public enum Shell {
    public static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public static func run(
        _ tool: String,
        _ args: [String],
        env extra: [String: String] = [:],
        timeout: TimeInterval = 120
    ) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath + ":" + (env["PATH"] ?? "")
        for (k, v) in extra { env[k] = v }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let lock = NSLock()
        var outData = Data(), errData = Data()
        let reads = DispatchGroup()
        reads.enter()
        DispatchQueue.global().async {
            let d = outPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); outData = d; lock.unlock()
            reads.leave()
        }
        reads.enter()
        DispatchQueue.global().async {
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errData = d; lock.unlock()
            reads.leave()
        }

        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do {
            try p.run()
        } catch {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            _ = reads.wait(timeout: .now() + 2)
            return ShellResult(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }
        // У дочернего процесса свои копии — закрываем наши концы записи, чтобы чтение завершилось с выходом процесса.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            _ = done.wait(timeout: .now() + 5)
        }
        _ = reads.wait(timeout: .now() + 5)
        lock.lock()
        defer { lock.unlock() }
        return ShellResult(
            status: p.isRunning ? -1 : p.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            timedOut: timedOut
        )
    }

    public static func find(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

public enum DevTool: String, CaseIterable, Identifiable, Sendable {
    case docker, simulators, homebrew

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .docker: return "Docker"
        case .simulators: return "Симуляторы Xcode"
        case .homebrew: return "Homebrew"
        }
    }

    public var detail: String {
        switch self {
        case .docker: return "Остановленные контейнеры, неиспользуемые образы, сети и кэш сборки. Тома с данными не трогаются."
        case .simulators: return "Симуляторы для версий iOS, которых больше нет в Xcode."
        case .homebrew: return "Старые версии пакетов и скачанные установщики в кэше Homebrew."
        }
    }

    public var symbol: String {
        switch self {
        case .docker: return "shippingbox"
        case .simulators: return "iphone"
        case .homebrew: return "mug"
        }
    }

    public func command(aggressive: Bool) -> String {
        switch self {
        case .docker: return aggressive ? "docker system prune -a -f" : "docker system prune -f"
        case .simulators: return "xcrun simctl delete unavailable"
        case .homebrew: return "brew cleanup --prune=all -s"
        }
    }
}

public struct DevToolStatus: Sendable, Identifiable {
    public var id: DevTool { tool }
    public let tool: DevTool
    /// Можно чистить: утилита найдена и отвечает.
    public let ready: Bool
    /// Оценка освобождаемого места.
    public let reclaimable: Int64?
    public let note: String
}

/// Очистка Docker, симуляторов и Homebrew их собственными командами.
public struct DevToolsCleaner: Sendable {
    public let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    static let dockerPaths = [
        "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
        "/Applications/OrbStack.app/Contents/MacOS/xbin/docker",
    ]
    static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    static let brewEnv = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1",
                          "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1"]

    public func status(_ tool: DevTool) -> DevToolStatus {
        switch tool {
        case .docker:
            guard let docker = Shell.find(Self.dockerPaths) else {
                return DevToolStatus(tool: tool, ready: false, reclaimable: nil, note: "Docker не установлен")
            }
            let r = Shell.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 20)
            guard r.ok else {
                return DevToolStatus(tool: tool, ready: false, reclaimable: nil, note: "Docker не запущен — откройте Docker Desktop")
            }
            let size = Self.parseDockerReclaimable(r.stdout)
            return DevToolStatus(tool: tool, ready: true, reclaimable: size, note: "Можно освободить до")

        case .simulators:
            guard FileManager.default.fileExists(atPath: "/usr/bin/xcrun") else {
                return DevToolStatus(tool: tool, ready: false, reclaimable: nil, note: "Xcode не установлен")
            }
            let r = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"], timeout: 30)
            guard r.ok else {
                return DevToolStatus(tool: tool, ready: false, reclaimable: nil, note: "Нужен Xcode (не только Command Line Tools)")
            }
            let udids = Self.parseUnavailableSimulators(r.stdout)
            let devices = home + "/Library/Developer/CoreSimulator/Devices/"
            let size = udids.reduce(Int64(0)) { $0 + AppUninstaller.size(of: devices + $1) }
            return DevToolStatus(tool: tool, ready: !udids.isEmpty, reclaimable: size,
                                 note: udids.isEmpty ? "Неактуальных симуляторов нет" : "Неактуальных симуляторов: \(udids.count)")

        case .homebrew:
            guard let brew = Shell.find(Self.brewPaths) else {
                return DevToolStatus(tool: tool, ready: false, reclaimable: nil, note: "Homebrew не установлен")
            }
            let r = Shell.run(brew, ["cleanup", "-n", "--prune=all", "-s"], env: Self.brewEnv, timeout: 120)
            guard r.status == 0 else {
                return DevToolStatus(tool: tool, ready: false, reclaimable: nil, note: "brew cleanup не ответил: \(r.tail)")
            }
            let size = Self.parseBrewDryRun(r.stdout + "\n" + r.stderr) ?? 0
            return DevToolStatus(tool: tool, ready: size > 0, reclaimable: size,
                                 note: size > 0 ? "Можно освободить" : "Кэш уже чистый")
        }
    }

    public func clean(_ tool: DevTool, aggressive: Bool = false) -> ShellResult {
        switch tool {
        case .docker:
            guard let docker = Shell.find(Self.dockerPaths) else { return Self.missing("docker") }
            return Shell.run(docker, aggressive ? ["system", "prune", "-a", "-f"] : ["system", "prune", "-f"], timeout: 900)
        case .simulators:
            return Shell.run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"], timeout: 600)
        case .homebrew:
            guard let brew = Shell.find(Self.brewPaths) else { return Self.missing("brew") }
            return Shell.run(brew, ["cleanup", "--prune=all", "-s"], env: Self.brewEnv, timeout: 900)
        }
    }

    static func missing(_ name: String) -> ShellResult {
        ShellResult(status: -1, stdout: "", stderr: "\(name) не найден", timedOut: false)
    }

    // MARK: - Разбор вывода

    /// `docker system df --format '{{json .}}'`: сумма Reclaimable, кроме томов.
    public static func parseDockerReclaimable(_ output: String) -> Int64 {
        var total: Int64 = 0
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["Type"] as? String, !type.lowercased().contains("volume"),
                  let reclaimable = obj["Reclaimable"] as? String else { continue }
            let value = reclaimable.split(separator: "(").first.map(String.init) ?? reclaimable
            total += ByteFormat.parse(value.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return total
    }

    /// `xcrun simctl list devices unavailable -j` → UDID недоступных симуляторов.
    public static func parseUnavailableSimulators(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = obj["devices"] as? [String: [[String: Any]]] else { return [] }
        return devices.values.flatMap { $0 }.compactMap { d in
            (d["isAvailable"] as? Bool) == false ? d["udid"] as? String : nil
        }
    }

    /// `brew cleanup -n`: «This operation would free approximately 1.2GB of disk space.»
    public static func parseBrewDryRun(_ output: String) -> Int64? {
        guard let range = output.range(of: #"approximately\s+([0-9.,]+\s*[KMGT]?B)"#, options: .regularExpression) else {
            return nil
        }
        let value = output[range].replacingOccurrences(of: "approximately", with: "")
        return ByteFormat.parse(value.trimmingCharacters(in: .whitespaces))
    }
}
