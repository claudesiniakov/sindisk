import SwiftUI
import AppKit
import SinDiskCore

struct TrayItem: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let size: Int64
    let isDirectory: Bool
    var name: String { (path as NSString).lastPathComponent }
}

struct VolumeInfo {
    let total: Int64
    let available: Int64
    let availableImportant: Int64

    var used: Int64 { max(0, total - available) }
    var purgeable: Int64 { max(0, availableImportant - available) }

    static func current(path: String = "/") -> VolumeInfo? {
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]), let total = v.volumeTotalCapacity else { return nil }
        let available = Int64(v.volumeAvailableCapacity ?? 0)
        return VolumeInfo(
            total: Int64(total),
            available: available,
            availableImportant: v.volumeAvailableCapacityForImportantUsage ?? available
        )
    }
}

@MainActor
@Observable
final class AppModel {
    enum Section: String, Hashable, CaseIterable, Identifiable {
        case overview, map, recommendations, apps, duplicates, changes, search, history
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "Обзор"
            case .map: return "Карта диска"
            case .recommendations: return "Рекомендации"
            case .apps: return "Приложения"
            case .duplicates: return "Дубликаты"
            case .changes: return "Изменения"
            case .search: return "Поиск"
            case .history: return "История"
            }
        }

        var icon: String {
            switch self {
            case .overview: return "gauge.with.dots.needle.33percent"
            case .map: return "chart.pie"
            case .recommendations: return "sparkles"
            case .apps: return "square.grid.3x3.square"
            case .duplicates: return "doc.on.doc"
            case .changes: return "chart.line.uptrend.xyaxis"
            case .search: return "magnifyingglass"
            case .history: return "clock.arrow.circlepath"
            }
        }
    }

    enum Phase: Equatable { case idle, scanning, ready }

    let home = NSHomeDirectory()
    let safety = SafetyGuard()
    let store: SessionStore
    let engine: CleanEngine
    let apps = AppsModel()
    let devTools = DevToolsModel()
    let changes = ChangesModel()

    // Навигация
    var section: Section? = .overview

    // Сканирование
    var phase: Phase = .idle
    var scanPath: String
    var root: FileNode?
    var treeVersion = 0
    var treeIsStale = false
    /// Дерево загружено из сохранённого прошлого сканирования (а не только что построено).
    var restoredFromCache = false
    var restoring = false
    var progress = ScanProgress()
    var lastScanDate: Date?
    var lastScanDuration: TimeInterval = 0
    var kindTotals: [KindTotal] = []
    var largestFiles: [FileNode] = []
    var volume: VolumeInfo? = VolumeInfo.current()
    var hasFullDiskAccess = false
    @ObservationIgnored private var scanner: DiskScanner?

    // Рекомендации
    var categories: [CategoryResult] = []
    var selected: Set<String> = []
    var analyzing = false

    // Карта
    var focus: FileNode?
    var highlightPaths: Set<String>?
    var highlightExact: Set<ObjectIdentifier> = []
    var highlightAll: Set<ObjectIdentifier> = []

    // Лоток очистки
    var tray: [TrayItem] = []

    // Дубликаты
    var dupGroups: [DuplicateGroup] = []
    var dupRunning = false
    var dupSearched = false
    var dupProgress = DuplicateProgress()
    var dupMinSize: Int64 = 1_000_000
    var dupMarked: Set<String> = []
    var keepRule: KeepRule = .oldest {
        didSet { if !dupMarked.isEmpty { applyKeepRule() } }
    }
    @ObservationIgnored private var dupFinder: DuplicateFinder?

    // Поиск
    var searchText = ""
    var searchResults: [SearchHit] = []
    var searchErrors: [String] = []
    var searching = false
    var savedQueries: [String] {
        didSet { UserDefaults.standard.set(savedQueries, forKey: "savedQueries") }
    }
    var recentQueries: [String] {
        didSet { UserDefaults.standard.set(recentQueries, forKey: "recentQueries") }
    }
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    // Очистка и история
    var cleaning = false
    /// Короткое сообщение пользователю (показывается алертом).
    var notice: String?
    var sessions: [CleanSession] = []
    var lastResult: CleanSession?

    static let presetQueries: [(title: String, query: String)] = [
        ("Видео больше 1 ГБ", "kind:video size:>1GB"),
        ("Установщики в Загрузках", "kind:installer in:~/Downloads"),
        ("Не открывалось больше года", "type:file size:>50MB opened:>1y"),
        ("Архивы", "kind:archive size:>10MB"),
    ]

    init() {
        scanPath = NSHomeDirectory()
        store = SessionStore(directory: SessionStore.defaultDirectory)
        engine = CleanEngine(safety: SafetyGuard(), store: store)
        savedQueries = UserDefaults.standard.stringArray(forKey: "savedQueries") ?? []
        recentQueries = UserDefaults.standard.stringArray(forKey: "recentQueries") ?? []
        store.prune()
        sessions = store.load()
        refreshAccess()
        apps.owner = self
        devTools.owner = self
        restoreLastScan()
    }

    // MARK: - Доступ и объём

    func refreshAccess() {
        hasFullDiskAccess = (try? FileManager.default.contentsOfDirectory(atPath: home + "/Library/Safari")) != nil
        volume = VolumeInfo.current()
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    var menuBarTitle: String {
        guard let v = volume else { return "SinDisk" }
        return ByteFormat.string(v.availableImportant)
    }

    // MARK: - Сканирование

    func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Сканировать"
        if panel.runModal() == .OK, let url = panel.url {
            startScan(path: url.path)
        }
    }

    /// Открывает результат прошлого сканирования, чтобы приложение не начиналось с пустого экрана.
    private func restoreLastScan() {
        restoring = true
        Task {
            let cached = await Task.detached(priority: .userInitiated) { () -> (FileNode, Date, [KindTotal], [FileNode])? in
                guard let c = TreeCache.load() else { return nil }
                return (c.root, c.scannedAt, TreeStats.kindTotals(c.root), TreeStats.largestFiles(c.root, limit: 50))
            }.value
            self.restoring = false
            guard let cached, self.root == nil, self.phase == .idle else { return }
            self.root = cached.0
            self.focus = cached.0
            self.scanPath = cached.0.path
            self.lastScanDate = cached.1
            self.kindTotals = cached.2
            self.largestFiles = cached.3
            self.restoredFromCache = true
            self.treeVersion += 1
            self.phase = .ready
            self.runAnalysis()
            self.changes.load(root: cached.0.path)
        }
    }

    func startScan(path: String? = nil) {
        guard phase != .scanning else { return }
        if let path { scanPath = path }
        let scanner = DiskScanner()
        if scanPath == "/" { scanner.excludedPaths = DiskScanner.rootExclusions }
        self.scanner = scanner
        phase = .scanning
        progress = ScanProgress()
        let target = scanPath
        let started = Date()

        Task {
            let poll = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    self.progress = scanner.progress
                }
            }
            let tree = await Task.detached(priority: .userInitiated) { scanner.scan(path: target) }.value
            let stats = await Task.detached(priority: .utility) {
                (TreeStats.kindTotals(tree), TreeStats.largestFiles(tree, limit: 50))
            }.value
            poll.cancel()
            self.progress = scanner.progress
            if scanner.isCancelled {
                self.phase = self.root == nil ? .idle : .ready
                return
            }
            self.root = tree
            self.focus = tree
            self.kindTotals = stats.0
            self.largestFiles = stats.1
            self.treeVersion += 1
            self.treeIsStale = false
            self.restoredFromCache = false
            self.lastScanDate = Date()
            self.lastScanDuration = Date().timeIntervalSince(started)
            self.phase = .ready
            self.dupGroups = []
            self.dupMarked = []
            self.dupSearched = false
            self.searchResults = []
            self.clearHighlight()
            self.volume = VolumeInfo.current()
            self.runAnalysis()
            self.changes.record(tree)
            let scannedAt = Date()
            Task.detached(priority: .utility) { _ = try? TreeCache.save(tree, scannedAt: scannedAt) }
        }
    }

    func cancelScan() {
        scanner?.cancel()
    }

    // MARK: - Анализ

    func runAnalysis() {
        analyzing = true
        let tree = root
        let home = home
        let defaults = UserDefaults.standard
        let largeMB = defaults.integer(forKey: "largeFileMB")
        let oldDays = defaults.integer(forKey: "oldFileDays")
        let downloadsDays = defaults.integer(forKey: "downloadsDays")
        let settings = AnalyzerSettings(
            largeFileBytes: Int64(largeMB > 0 ? largeMB : 500) * 1_000_000,
            oldFileAge: Double(oldDays > 0 ? oldDays : 365) * 86_400,
            oldDownloadsAge: Double(downloadsDays > 0 ? downloadsDays : 90) * 86_400
        )
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        Task {
            let result = await Task.detached(priority: .utility) {
                Analyzer(home: home, settings: settings, appInstalled: { id in
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
                }, runningBundleIDs: running).analyze(tree: tree)
            }.value
            self.categories = result
            self.selected = Set(result.flatMap(\.items).filter(\.selectedByDefault).map(\.path))
            self.analyzing = false
        }
    }

    /// Выбрать всё до указанного уровня риска включительно.
    func selectAll(maxRisk: Risk) {
        selected = Set(categories.filter { $0.category.risk <= maxRisk }.flatMap(\.items).map(\.path))
    }

    /// Выбор по умолчанию: то, что SinDisk отмечает сам после анализа.
    func selectRecommended() {
        selected = Set(categories.flatMap(\.items).filter(\.selectedByDefault).map(\.path))
    }

    var selectedCandidates: [Candidate] {
        categories.flatMap(\.items).filter { selected.contains($0.path) }
    }

    var selectedTotal: Int64 { selectedCandidates.reduce(0) { $0 + $1.size } }

    var safeTotal: Int64 {
        categories.filter { $0.category.risk == .low }.reduce(0) { $0 + $1.total }
    }

    func cleanSelectedRecommendations() {
        let requests = selectedCandidates.map { c in
            CleanRequest(
                path: c.path, size: c.size,
                mode: c.category.deletesPermanently ? .permanent : .trash,
                expectedModified: c.isDirectory ? nil : c.modified
            )
        }
        performClean(requests, title: "Рекомендации: \(Plural.count(requests.count, "объект", "объекта", "объектов"))")
    }

    // MARK: - Карта и лоток

    func open(_ node: FileNode) {
        guard node.isDirectory else { return }
        focus = node
    }

    func goUp() {
        if let p = focus?.parent { focus = p }
    }

    func addToTray(path: String, size: Int64, isDirectory: Bool) {
        guard !tray.contains(where: { $0.path == path }) else { return }
        tray.append(TrayItem(path: path, size: size, isDirectory: isDirectory))
    }

    func addToTray(_ node: FileNode) {
        addToTray(path: node.path, size: node.size, isDirectory: node.isDirectory)
    }

    var trayTotal: Int64 { tray.reduce(0) { $0 + $1.size } }

    func cleanTray() {
        let requests = tray.map { CleanRequest(path: $0.path, size: $0.size, mode: .trash) }
        performClean(requests, title: "Лоток очистки: \(Plural.count(requests.count, "объект", "объекта", "объектов"))")
    }

    func highlight(paths: [String]) {
        guard let root else { return }
        var exact = Set<ObjectIdentifier>()
        var all = Set<ObjectIdentifier>()
        for p in paths {
            guard let n = root.node(atPath: p) else { continue }
            exact.insert(n.id)
            for a in n.ancestry { all.insert(a.id) }
        }
        highlightPaths = Set(paths)
        highlightExact = exact
        highlightAll = all
        focus = root
        section = .map
    }

    func clearHighlight() {
        highlightPaths = nil
        highlightExact = []
        highlightAll = []
    }

    func isHighlighted(_ node: FileNode) -> Bool {
        if highlightAll.contains(node.id) { return true }
        var cur = node.parent
        while let n = cur {
            if highlightExact.contains(n.id) { return true }
            cur = n.parent
        }
        return false
    }

    // MARK: - Дубликаты

    func findDuplicates() {
        guard let root, !dupRunning else { return }
        let finder = DuplicateFinder(home: home)
        finder.minSize = dupMinSize
        dupFinder = finder
        dupRunning = true
        dupProgress = DuplicateProgress()
        Task {
            let poll = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    self.dupProgress = finder.progress
                }
            }
            let groups = await Task.detached(priority: .utility) { finder.find(in: root) }.value
            poll.cancel()
            self.dupProgress = finder.progress
            self.dupRunning = false
            if finder.isCancelled { return }
            self.dupGroups = groups
            self.dupSearched = true
            // Ничего не отмечаем сами: пользователь отмечает копии кнопкой «Отметить по правилу» или вручную.
            self.dupMarked = []
        }
    }

    func cancelDuplicates() {
        dupFinder?.cancel()
    }

    func applyKeepRule() {
        var marked = Set<String>()
        for g in dupGroups {
            let keeper = keepRule.keeper(in: g, home: home)
            for f in g.files where f.path != keeper.path { marked.insert(f.path) }
        }
        dupMarked = marked
    }

    /// Переключает отметку; последнюю неотмеченную копию в группе отметить нельзя.
    func toggleMark(_ file: DuplicateFile, in group: DuplicateGroup) {
        if dupMarked.contains(file.path) {
            dupMarked.remove(file.path)
        } else {
            let unmarked = group.files.filter { !dupMarked.contains($0.path) }
            if unmarked.count <= 1 {
                NSSound.beep()
                return
            }
            dupMarked.insert(file.path)
        }
    }

    func keeper(of group: DuplicateGroup) -> DuplicateFile? {
        group.files.first { !dupMarked.contains($0.path) }
    }

    var markedDuplicateTotal: Int64 {
        dupGroups.reduce(0) { sum, g in sum + g.files.filter { dupMarked.contains($0.path) }.reduce(0) { $0 + $1.size } }
    }

    var markedDuplicateCount: Int {
        dupGroups.reduce(0) { $0 + $1.files.filter { dupMarked.contains($0.path) }.count }
    }

    var duplicateWasteTotal: Int64 { dupGroups.reduce(0) { $0 + $1.wasted } }

    func cleanDuplicates(useClones: Bool) {
        var requests: [CleanRequest] = []
        for g in dupGroups {
            guard let keeper = keeper(of: g) else { continue }
            for f in g.files where dupMarked.contains(f.path) {
                requests.append(CleanRequest(
                    path: f.path, size: f.size,
                    mode: useClones ? .cloneOf(keeper.path) : .trash,
                    expectedModified: f.modified,
                    mustMatch: keeper.path
                ))
            }
        }
        let title = useClones ? "Дубликаты → клоны: \(requests.count)" : "Дубликаты в Корзину: \(requests.count)"
        performClean(requests, title: title)
    }

    // MARK: - Поиск

    func runSearch() {
        searchTask?.cancel()
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard let root, !text.isEmpty else {
            searchResults = []
            searchErrors = []
            searching = false
            return
        }
        let query = SearchQuery.parse(text, home: home)
        searchErrors = query.errors
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            let hits = await Task.detached(priority: .userInitiated) {
                SearchEngine.search(root: root, query: query, limit: 5000)
            }.value
            if Task.isCancelled { return }
            self.searchResults = hits
            self.searching = false
        }
    }

    func rememberQuery() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        recentQueries.removeAll { $0 == q }
        recentQueries.insert(q, at: 0)
        if recentQueries.count > 20 { recentQueries.removeLast(recentQueries.count - 20) }
    }

    func saveCurrentQuery() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !savedQueries.contains(q) else { return }
        savedQueries.append(q)
    }

    // MARK: - Очистка

    func performClean(_ requests: [CleanRequest], title: String, completion: ((CleanSession) -> Void)? = nil) {
        guard !requests.isEmpty else { return }
        guard !cleaning else {
            notice = "Сейчас идёт другая очистка. Дождитесь её завершения и повторите."
            return
        }
        cleaning = true
        let engine = engine
        Task {
            let session = await Task.detached(priority: .userInitiated) {
                engine.clean(requests, title: title)
            }.value
            self.sessions.insert(session, at: 0)
            self.applyRemovals(session)
            self.lastResult = session
            self.cleaning = false
            self.volume = VolumeInfo.current()
            completion?(session)
        }
    }

    private func applyRemovals(_ session: CleanSession) {
        let done = session.records.filter { $0.status == .done }
        let removed = Set(done.filter { if case .cloneOf = $0.mode { return false } else { return true } }.map(\.originalPath))
        let touched = Set(done.map(\.originalPath))
        for p in removed {
            root?.node(atPath: p)?.detach()
        }
        for i in categories.indices {
            categories[i].items.removeAll { removed.contains($0.path) }
        }
        categories.removeAll { $0.items.isEmpty }
        selected.subtract(removed)
        tray.removeAll { touched.contains($0.path) }
        for i in dupGroups.indices {
            dupGroups[i].files.removeAll { touched.contains($0.path) }
        }
        dupGroups.removeAll { $0.files.count < 2 }
        dupMarked.subtract(touched)
        searchResults.removeAll { removed.contains($0.path) }
        if let f = focus, f.parent == nil, f !== root { focus = root }
        if let r = root {
            kindTotals = TreeStats.kindTotals(r)
            largestFiles = largestFiles.filter { !removed.contains($0.path) }
        }
        treeVersion += 1
    }

    func undo(_ session: CleanSession) {
        let engine = engine
        Task {
            let updated = await Task.detached { engine.undo(session) }.value
            if let i = self.sessions.firstIndex(where: { $0.id == updated.id }) {
                self.sessions[i] = updated
            }
            if self.lastResult?.id == updated.id { self.lastResult = nil }
            self.treeIsStale = true
            self.volume = VolumeInfo.current()
        }
    }

    // MARK: - Finder

    func reveal(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openItem(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func displayPath(_ path: String) -> String {
        SafetyGuard.isInside(path, home) ? "~" + path.dropFirst(home.count) : path
    }
}
