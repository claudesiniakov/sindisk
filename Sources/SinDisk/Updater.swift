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

    func install(_ release: ReleaseInfo) async {
        guard canInstallInPlace else {
            openReleasePage()
            return
        }
        state = .downloading(release)
        do {
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("SinDisk-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            let (downloaded, response) = try await URLSession.shared.download(from: release.archiveURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CleanError("Не удалось скачать обновление") }
            let archive = work.appendingPathComponent(ReleaseFeed.archiveName)
            try FileManager.default.moveItem(at: downloaded, to: archive)

            if let sumURL = release.checksumURL {
                let (sumData, _) = try await URLSession.shared.data(from: sumURL)
                guard let expected = UpdateVerifier.parseChecksum(String(decoding: sumData, as: UTF8.self)) else {
                    throw CleanError("Некорректная контрольная сумма в релизе")
                }
                let actual = try await Task.detached { try UpdateVerifier.sha256(of: archive) }.value
                guard actual == expected else { throw CleanError("Контрольная сумма архива не совпала — установка отменена") }
            }

            state = .installing(release)
            let newApp = try await Task.detached { try Self.unpackAndVerify(archive: archive, in: work, expected: release.version) }.value
            try launchReplacement(newApp: newApp)
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
            showSheet = true
        }
    }

    nonisolated private static func unpackAndVerify(archive: URL, in work: URL, expected: AppVersion) throws -> URL {
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        let newApp = unpacked.appendingPathComponent("SinDisk.app")
        guard let bundle = Bundle(url: newApp),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw CleanError("В архиве не найдено приложение SinDisk")
        }
        let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        guard version == expected else { throw CleanError("Версия в архиве не совпадает с релизом") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        return newApp
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw CleanError("\((tool as NSString).lastPathComponent) завершился с кодом \(p.terminationStatus)")
        }
        return p.terminationStatus
    }

    /// Скрипт ждёт выхода приложения, меняет бандл (с откатом при ошибке) и запускает новую версию.
    private func launchReplacement(newApp: URL) throws {
        let script = """
        #!/bin/sh
        PID="$1"; OLD="$2"; NEW="$3"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        BACKUP="$OLD.sindisk-previous"
        rm -rf "$BACKUP"
        if mv "$OLD" "$BACKUP"; then
          if mv "$NEW" "$OLD" || ditto "$NEW" "$OLD"; then
            rm -rf "$BACKUP"
          else
            rm -rf "$OLD"; mv "$BACKUP" "$OLD"
          fi
        fi
        open "$OLD"
        """
        let scriptURL = newApp.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier),
                       Bundle.main.bundleURL.path, newApp.path]
        try p.run()
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
        .interactiveDismissDisabled(updater.isBusy)
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
                Text("Загрузка и проверка…")
            case .installing:
                ProgressView().controlSize(.small)
                Text("Установка, приложение перезапустится…")
            default:
                Button("Пропустить версию") { updater.skip(release) }
                Button("Позже") { updater.remindLater() }
                Spacer()
                if updater.canInstallInPlace {
                    Button("Установить и перезапустить") {
                        Task { await updater.install(release) }
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
