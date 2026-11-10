import SwiftUI
import AppKit
import SinDiskCore

/// Проверка, загрузка и установка обновлений из GitHub Releases.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(ReleaseInfo)
        case installing(ReleaseInfo)
        case failed(String)

        var isInstalling: Bool {
            if case .installing = self { return true }
            return false
        }
    }

    var state: State = .idle
    var showSheet = false
    var showUpToDate = false
    var lastCheck: Date? = UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date
    var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: Keys.autoCheck) }
    }

    private enum Keys {
        static let autoCheck = "autoCheckUpdates"
        static let lastCheck = "lastUpdateCheck"
        static let skipped = "skippedUpdateVersion"
    }

    let currentVersion: AppVersion?
    let currentVersionString: String

    init() {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        currentVersion = short.flatMap(AppVersion.init)
        currentVersionString = short ?? "dev"
        autoCheck = UserDefaults.standard.object(forKey: Keys.autoCheck) as? Bool ?? true
    }

    /// Установка возможна только из собранного .app с правом записи в его папку.
    var canInstallInPlace: Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", currentVersion != nil else { return false }
        return FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }

    var release: ReleaseInfo? {
        switch state {
        case let .available(r), let .downloading(r), let .installing(r): return r
        default: return nil
        }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    // MARK: - Проверка

    func checkOnLaunch() async {
        guard autoCheck else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        state = .checking
        do {
            var request = URLRequest(url: ReleaseFeed.latestURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("SinDisk-Updater", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ReleaseFeedError.invalidResponse
            }
            let release = try ReleaseFeed.parse(data)
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: Keys.lastCheck)

            let newer = currentVersion.map { release.version > $0 } ?? true
            let skipped = UserDefaults.standard.string(forKey: Keys.skipped) == release.version.description
            if newer, userInitiated || !skipped {
                state = .available(release)
                showSheet = true
            } else {
                state = .upToDate
                if userInitiated { showUpToDate = true }
            }
        } catch {
            state = .failed(error.localizedDescription)
            if userInitiated { showSheet = true }
        }
    }

    func skip(_ release: ReleaseInfo) {
        UserDefaults.standard.set(release.version.description, forKey: Keys.skipped)
        showSheet = false
        state = .idle
    }

    func remindLater() {
        showSheet = false
        state = .idle
    }

    func openReleasePage() {
        NSWorkspace.shared.open(release?.pageURL ?? ReleaseFeed.releasesPage)
    }

    // MARK: - Установка

    @ObservationIgnored private var installTask: Task<Void, Never>?

    func startInstall(_ release: ReleaseInfo) {
        guard installTask == nil else { return }
        installTask = Task {
            await install(release)
            installTask = nil
        }
    }

    func cancelInstall() {
        installTask?.cancel()
        installTask = nil
        UpdateLog.write("Установка отменена пользователем")
        if let r = release { state = .available(r) }
        step = ""
    }

    /// Текущий шаг установки (показывается в окне и пишется в журнал).
    var step = ""

    private func setStep(_ text: String) {
        step = text
        UpdateLog.write(text)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpAdditionalHeaders = ["User-Agent": "SinDisk-Updater"]
        return URLSession(configuration: config)
    }()

    func install(_ release: ReleaseInfo) async {
        guard canInstallInPlace else {
            openReleasePage()
            return
        }
        UpdateLog.write("— Обновление \(currentVersionString) → \(release.version), бандл \(Bundle.main.bundleURL.path)")
        state = .downloading(release)
        do {
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("SinDisk-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            setStep("Загрузка \(release.archiveURL.lastPathComponent)…")
            let (downloaded, response) = try await Self.session.download(from: release.archiveURL)
            try Task.checkCancellation()
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw CleanError("Не удалось скачать обновление (HTTP \(code))") }
            let archive = work.appendingPathComponent(ReleaseFeed.archiveName)
            try FileManager.default.moveItem(at: downloaded, to: archive)

            if let sumURL = release.checksumURL {
                setStep("Проверка контрольной суммы…")
                let (sumData, _) = try await Self.session.data(from: sumURL)
                guard let expected = UpdateVerifier.parseChecksum(String(decoding: sumData, as: UTF8.self)) else {
                    throw CleanError("Некорректная контрольная сумма в релизе")
                }
                let actual = try await Self.background { try UpdateVerifier.sha256(of: archive) }
                guard actual == expected else { throw CleanError("Контрольная сумма архива не совпала — установка отменена") }
            }
            try Task.checkCancellation()

            setStep("Распаковка…")
            let newApp = try await Self.background { try Self.unpack(archive: archive, in: work) }
            setStep("Проверка подписи и версии…")
            try await Self.background { try Self.verify(newApp: newApp, expected: release.version) }
            try Task.checkCancellation()

            state = .installing(release)
            setStep("Перезапуск…")
            try launchReplacement(newApp: newApp, log: UpdateLog.url)
            showSheet = false
            try? await Task.sleep(for: .milliseconds(300))
            UpdateLog.write("Завершение приложения для замены")
            NSApp.terminate(nil)
            // Если что-то помешало штатному выходу — завершаемся сами: скрипт замены ждёт нашего PID.
            try? await Task.sleep(for: .seconds(3))
            UpdateLog.write("terminate не сработал — принудительный выход")
            exit(0)
        } catch is CancellationError {
            return
        } catch {
            UpdateLog.write("Ошибка: \(error.localizedDescription)")
            state = .failed(error.localizedDescription + "\n\nПодробности: ~/Library/Logs/SinDisk/update.log")
            step = ""
            showSheet = true
        }
    }

    /// Блокирующая работа — на обычной очереди GCD, не в пуле Swift Concurrency.
    nonisolated private static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    nonisolated private static func unpack(archive: URL, in work: URL) throws -> URL {
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        let newApp = unpacked.appendingPathComponent("SinDisk.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            throw CleanError("В архиве не найдено приложение SinDisk")
        }
        return newApp
    }

    nonisolated private static func verify(newApp: URL, expected: AppVersion) throws {
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw CleanError("Архив содержит другое приложение")
        }
        let version = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        guard version == expected else {
            throw CleanError("Версия в архиве (\(version?.description ?? "?")) не совпадает с релизом \(expected)")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
    }

    /// Запуск внешней утилиты с тайм-аутом; ожидание через terminationHandler, без run loop.
    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 60) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        let name = (tool as NSString).lastPathComponent
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            throw CleanError("\(name) не ответил за \(Int(timeout)) с")
        }
        UpdateLog.write("\(name) → код \(p.terminationStatus)")
        guard p.terminationStatus == 0 else {
            throw CleanError("\(name) завершился с кодом \(p.terminationStatus)")
        }
        return p.terminationStatus
    }

    /// Скрипт ждёт выхода приложения (не дольше 30 с), меняет бандл с откатом при ошибке
    /// и запускает новую версию. Весь вывод — в журнал обновлений.
    private func launchReplacement(newApp: URL, log: URL) throws {
        let script = """
        #!/bin/sh
        PID="$1"; OLD="$2"; NEW="$3"; LOG="$4"
        exec >>"$LOG" 2>&1
        trap '' HUP
        echo "$(date '+%F %T') скрипт: жду выхода PID $PID"
        i=0
        while kill -0 "$PID" 2>/dev/null; do
          i=$((i+1))
          if [ $i -gt 150 ]; then echo "приложение не вышло за 30 с — завершаю"; kill -9 "$PID"; sleep 1; fi
          sleep 0.2
        done
        BACKUP="$OLD.sindisk-previous"
        rm -rf "$BACKUP"
        if mv "$OLD" "$BACKUP"; then
          if mv "$NEW" "$OLD" || ditto "$NEW" "$OLD"; then
            rm -rf "$BACKUP"
            echo "$(date '+%F %T') скрипт: новая версия установлена"
          else
            echo "$(date '+%F %T') скрипт: замена не удалась, возвращаю прежнюю версию"
            rm -rf "$OLD"; mv "$BACKUP" "$OLD"
          fi
        else
          echo "$(date '+%F %T') скрипт: не удалось убрать старую версию"
        fi
        open "$OLD"
        """
        let scriptURL = newApp.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier),
                       Bundle.main.bundleURL.path, newApp.path, log.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        UpdateLog.write("Скрипт замены запущен, PID \(p.processIdentifier)")
    }
}

/// Журнал обновлений: ~/Library/Logs/SinDisk/update.log
enum UpdateLog {
    static var url: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/SinDisk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("update.log")
    }

    static func write(_ line: String) {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        let data = Data("\(stamp) \(line)\n".utf8)
        let url = url
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Окно обновления

struct UpdateSheet: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch updater.state {
            case let .failed(message):
                Label("Не удалось обновиться", systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.orange)
                Text(message).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Открыть страницу релизов") { updater.openReleasePage() }
                    Spacer()
                    Button("Закрыть") { updater.remindLater() }
                        .keyboardShortcut(.defaultAction)
                }
            default:
                if let release = updater.release {
                    releaseView(release)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(updater.state.isInstalling)
    }

    @ViewBuilder private func releaseView(_ release: ReleaseInfo) -> some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Доступна версия \(release.version.description)")
                    .font(.title2.bold())
                Text("У вас \(updater.currentVersionString)"
                     + (release.archiveSize > 0 ? " · загрузка \(ByteFormat.string(release.archiveSize))" : ""))
                    .foregroundStyle(.secondary)
            }
        }
        if !release.notes.isEmpty {
            ScrollView {
                Text(notes(release.notes))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 120, maxHeight: 260)
            .padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
        if !updater.canInstallInPlace {
            Text("Автоустановка недоступна: приложение запущено не из .app или нет прав на запись в его папку. Скачайте новую версию со страницы релиза.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            switch updater.state {
            case .downloading:
                ProgressView().controlSize(.small)
                Text(updater.step.isEmpty ? "Подготовка…" : updater.step)
                Spacer()
                Button("Отменить") { updater.cancelInstall() }
            case .installing:
                ProgressView().controlSize(.small)
                Text(updater.step.isEmpty ? "Установка, приложение перезапустится…" : updater.step)
            default:
                Button("Пропустить версию") { updater.skip(release) }
                Button("Позже") { updater.remindLater() }
                Spacer()
                if updater.canInstallInPlace {
                    Button("Установить и перезапустить") {
                        updater.startInstall(release)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Открыть страницу релиза") { updater.openReleasePage() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func notes(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}

/// Блок настроек обновлений.
struct UpdateSettingsSection: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        Section("Обновления") {
            LabeledContent("Версия", value: updater.currentVersionString)
            Toggle("Проверять обновления автоматически", isOn: $updater.autoCheck)
            HStack {
                Button("Проверить сейчас") { Task { await updater.check(userInitiated: true) } }
                    .disabled(updater.isBusy)
                if updater.state == .checking { ProgressView().controlSize(.small) }
                Spacer()
                if let last = updater.lastCheck {
                    Text("Последняя проверка: \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
