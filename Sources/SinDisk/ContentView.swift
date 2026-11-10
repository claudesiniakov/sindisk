import SwiftUI
import SinDiskCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater

    var body: some View {
        @Bindable var model = model
        @Bindable var updater = updater
        NavigationSplitView {
            List(AppModel.Section.allCases, selection: $model.section) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                ScanStatusFooter()
            }
        } detail: {
            VStack(spacing: 0) {
                if model.treeIsStale {
                    StaleBanner()
                }
                detail
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    ScanToolbar()
                }
            }
            .sheet(isPresented: $updater.showSheet) {
                UpdateSheet().environment(updater)
            }
            .alert("Установлена последняя версия", isPresented: $updater.showUpToDate) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("SinDisk \(updater.currentVersionString) — самая свежая версия.")
            }
        }
        .alert("SinDisk", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice ?? "")
        }
        .sheet(item: $model.lastResult) { session in
            CleanResultView(session: session)
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.section ?? .overview {
        case .overview: OverviewView()
        case .map: VisualizationView()
        case .recommendations: RecommendationsView()
        case .apps: AppsView()
        case .duplicates: DuplicatesView()
        case .changes: ChangesView()
        case .search: SearchView()
        case .history: HistoryView()
        }
    }
}

struct ScanToolbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.phase == .scanning {
            ProgressView()
                .controlSize(.small)
            Button {
                model.cancelScan()
            } label: {
                Label("Остановить", systemImage: "stop.circle")
            }
        } else {
            Menu {
                Button("Домашняя папка") { model.startScan(path: model.home) }
                Button("Весь диск (Macintosh HD)") { model.startScan(path: "/") }
                Button("Выбрать папку…") { model.chooseFolderAndScan() }
            } label: {
                Label("Сканировать", systemImage: "arrow.clockwise")
            } primaryAction: {
                model.startScan()
            }
            .help("Сканировать заново (⌘R)")
        }
    }
}

struct ScanStatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.phase {
            case .idle:
                Text("Диск ещё не сканирован")
            case .scanning:
                Text("Сканирование… \(model.progress.files.formatted()) файлов")
                Text(ByteFormat.string(model.progress.bytes))
                    .monospacedDigit()
            case .ready:
                Label(model.scanPath == model.home ? "Домашняя папка"
                      : model.scanPath == "/" ? "Macintosh HD" : model.displayPath(model.scanPath),
                      systemImage: model.scanPath == model.home ? "house" : "internaldrive")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let root = model.root {
                    Text("\(ByteFormat.string(root.size)) · \(root.fileCount.formatted()) файлов")
                        .monospacedDigit()
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

struct StaleBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Image(systemName: "arrow.uturn.backward.circle")
            Text("Файлы восстановлены из Корзины — данные на экране устарели.")
            Spacer()
            Button("Пересканировать") { model.startScan() }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.15))
    }
}

struct EmptyScanView: View {
    @Environment(AppModel.self) private var model
    var message = "Сначала просканируйте диск."

    var body: some View {
        ContentUnavailableView {
            Label("Нет данных", systemImage: "internaldrive")
        } description: {
            Text(message)
        } actions: {
            if model.phase == .scanning {
                ProgressView("Сканирование… \(model.progress.files.formatted()) файлов")
            } else {
                Button("Сканировать домашнюю папку") { model.startScan(path: model.home) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct CleanResultView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: CleanSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: session.problems.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(session.problems.isEmpty ? .green : .orange)
                VStack(alignment: .leading) {
                    Text("Освобождено \(ByteFormat.string(session.freed))")
                        .font(.title2.bold())
                    Text("\(session.doneCount) объектов · \(session.title)")
                        .foregroundStyle(.secondary)
                }
            }
            if session.records.contains(where: { $0.status == .done && $0.trashedPath != nil }) {
                Text("Файлы перемещены в Корзину. Место на диске освободится после её очистки; до этого всё можно вернуть.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !session.problems.isEmpty {
                Text("Не удалено: \(session.problems.count)")
                    .font(.headline)
                List(session.problems) { r in
                    VStack(alignment: .leading) {
                        Text(model.displayPath(r.originalPath)).lineLimit(1).truncationMode(.middle)
                        Text(r.message ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 120, maxHeight: 220)
            }
            HStack {
                if session.canUndo {
                    Button("Отменить очистку") {
                        model.undo(session)
                        dismiss()
                    }
                }
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
