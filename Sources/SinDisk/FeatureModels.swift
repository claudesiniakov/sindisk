import SwiftUI
import AppKit
import SinDiskCore

// MARK: - Деинсталлятор

@MainActor
@Observable
final class AppsModel {
    var apps: [InstalledApp] = []
    var loading = false
    var measuring = false
    var loaded = false
    var selectedID: InstalledApp.ID?
    var files: [AppFile] = []
    var filesLoading = false
    var checked: Set<String> = []
    var filter = ""

    @ObservationIgnored weak var owner: AppModel?
    @ObservationIgnored private let uninstaller = AppUninstaller()
    @ObservationIgnored private var filesTask: Task<Void, Never>?

    var selected: InstalledApp? { apps.first { $0.id == selectedID } }

    var visibleApps: [InstalledApp] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.bundleID.localizedCaseInsensitiveContains(q)
        }
        return list.sorted { $0.bundleSize == $1.bundleSize ? $0.name < $1.name : $0.bundleSize > $1.bundleSize }
    }

    func loadIfNeeded() {
        if !loaded { reload() }
    }

    func reload() {
        guard !loading else { return }
        loading = true
        let uninstaller = uninstaller
        Task {
            let list = await Task.detached(priority: .userInitiated) { uninstaller.installedApps() }.value
            self.apps = list
            self.loading = false
            self.loaded = true
            self.measuring = true
            // Размеры и даты запуска считаются параллельно и появляются по мере готовности.
            let measured = await Task.detached(priority: .utility) { () -> [InstalledApp] in
                var out = [InstalledApp?](repeating: nil, count: list.count)
                let lock = NSLock()
                DispatchQueue.concurrentPerform(iterations: list.count) { i in
                    let m = AppUninstaller.measure(list[i])
                    lock.lock(); out[i] = m; lock.unlock()
                }
                return out.compactMap { $0 }
            }.value
            self.apps = measured
            self.measuring = false
            if let id = self.selectedID, let app = measured.first(where: { $0.id == id }) { self.loadFiles(app) }
        }
    }

    func select(_ id: InstalledApp.ID?) {
        selectedID = id
        files = []
        checked = []
        guard let app = selected else { return }
        loadFiles(app)
    }

    private func loadFiles(_ app: InstalledApp) {
        filesTask?.cancel()
        filesLoading = true
        let uninstaller = uninstaller
        filesTask = Task {
            let found = await Task.detached(priority: .userInitiated) { uninstaller.files(for: app) }.value
            if Task.isCancelled || self.selectedID != app.id { return }
            self.files = found
            self.checked = Set(found.map(\.path))
            self.filesLoading = false
        }
    }

    var checkedTotal: Int64 { files.filter { checked.contains($0.path) }.reduce(0) { $0 + $1.size } }
    var leftoversTotal: Int64 { files.filter { $0.kind != .bundle }.reduce(0) { $0 + $1.size } }

    func runningApp(_ app: InstalledApp) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first
    }

    func quit(_ app: InstalledApp) {
        runningApp(app)?.terminate()
    }

    func uninstall(_ app: InstalledApp) {
        guard let owner else { return }
        let requests = files.filter { checked.contains($0.path) }
            .map { CleanRequest(path: $0.path, size: $0.size, mode: .trash) }
        let removesBundle = checked.contains(app.path)
        let title = removesBundle ? "Удаление «\(app.name)»" : "Остатки «\(app.name)»"
        owner.performClean(requests, title: title) { [weak self] session in
            guard let self else { return }
            let done = Set(session.records.filter { $0.status == .done }.map(\.originalPath))
            if done.contains(app.path) {
                self.apps.removeAll { $0.id == app.id }
                self.selectedID = nil
                self.files = []
            } else {
                self.files.removeAll { done.contains($0.path) }
                self.checked.subtract(done)
            }
        }
    }
}

// MARK: - Инструменты разработчика

@MainActor
@Observable
final class DevToolsModel {
    var statuses: [DevTool: DevToolStatus] = [:]
    var loading = false
    var running: DevTool?
    var message: String?

    @ObservationIgnored weak var owner: AppModel?
    @ObservationIgnored private let cleaner = DevToolsCleaner()

    func refresh() {
        guard !loading else { return }
        loading = true
        let cleaner = cleaner
        Task {
            await withTaskGroup(of: DevToolStatus.self) { group in
                for tool in DevTool.allCases {
                    group.addTask { await Task.detached(priority: .utility) { cleaner.status(tool) }.value }
                }
                for await status in group {
                    self.statuses[status.tool] = status
                }
            }
            self.loading = false
        }
    }

    func clean(_ tool: DevTool, aggressive: Bool) {
        guard running == nil else { return }
        running = tool
        let cleaner = cleaner
        let before = VolumeInfo.current()?.availableImportant ?? 0
        Task {
            let result = await Task.detached(priority: .userInitiated) { cleaner.clean(tool, aggressive: aggressive) }.value
            let after = VolumeInfo.current()?.availableImportant ?? 0
            let freed = max(0, after - before)
            let record = CleanRecord(
                originalPath: tool.command(aggressive: aggressive),
                size: freed,
                mode: .permanent,
                status: result.ok ? .done : .failed,
                message: result.ok ? nil : (result.timedOut ? "Превышено время ожидания" : result.tail)
            )
            let session = CleanSession(title: "\(tool.title): очистка", records: [record])
            self.owner?.store.save(session)
            self.owner?.sessions.insert(session, at: 0)
            self.owner?.volume = VolumeInfo.current()
            self.message = result.ok
                ? "\(tool.title): освобождено около \(ByteFormat.string(freed))."
                : "\(tool.title): команда завершилась с ошибкой.\n\(record.message ?? "")"
            self.running = nil
            self.statuses[tool] = await Task.detached(priority: .utility) { cleaner.status(tool) }.value
        }
    }
}

// MARK: - Изменения между сканированиями

@MainActor
@Observable
final class ChangesModel {
    var snapshots: [ScanSnapshot] = []
    var baselineIndex = 1
    var changes: [SizeChange] = []

    @ObservationIgnored let store = SnapshotStore(directory: SnapshotStore.defaultDirectory)

    var current: ScanSnapshot? { snapshots.first }

    var baseline: ScanSnapshot? {
        snapshots.indices.contains(baselineIndex) ? snapshots[baselineIndex] : nil
    }

    var totalDelta: Int64? {
        guard let c = current, let b = baseline else { return nil }
        return c.total - b.total
    }

    /// Сохраняет слепок только что завершённого сканирования и пересчитывает изменения.
    func record(_ tree: FileNode) {
        let store = store
        Task {
            let snaps = await Task.detached(priority: .utility) { () -> [ScanSnapshot] in
                store.save(ScanSnapshot.make(from: tree))
                return store.load(root: tree.path)
            }.value
            self.snapshots = snaps
            self.baselineIndex = min(1, max(0, snaps.count - 1))
            self.recompute()
        }
    }

    func setBaseline(_ index: Int) {
        baselineIndex = index
        recompute()
    }

    private func recompute() {
        guard let c = current, let b = baseline, c.id != b.id else {
            changes = []
            return
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) { SnapshotDiff.compare(old: b, new: c) }.value
            self.changes = result
        }
    }
}
