import SwiftUI
import SinDiskCore

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !model.hasFullDiskAccess {
                    AccessCallout()
                }
                HStack(alignment: .top, spacing: 20) {
                    VolumeCard()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScanCard()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                if model.changes.totalDelta != nil {
                    ChangesSummaryCard()
                }
                if !model.kindTotals.isEmpty {
                    KindBreakdown()
                }
                if !model.categories.isEmpty {
                    CategoryTiles()
                }
                if !model.largestFiles.isEmpty {
                    LargestFilesCard()
                }
            }
            .padding(24)
        }
        .navigationTitle("Обзор")
        .onAppear { model.refreshAccess() }
    }
}

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AccessCallout: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Нужен полный доступ к диску").font(.headline)
                Text("Без него macOS скрывает от SinDisk Корзину, почту, резервные копии и часть кэшей — анализ будет неполным. Откройте «Конфиденциальность и безопасность → Доступ к диску», включите SinDisk и перезапустите приложение.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Открыть настройки") { model.openFullDiskAccessSettings() }
                    Button("Проверить снова") { model.refreshAccess() }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct VolumeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Macintosh HD") {
            if let v = model.volume {
                let usedShare = Double(v.used) / Double(max(v.total, 1))
                HStack(alignment: .center, spacing: 28) {
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 16)
                        Circle()
                            .trim(from: 0, to: CGFloat(usedShare))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 2) {
                            Text(usedShare.formatted(.percent.precision(.fractionLength(0))))
                                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                            Text("занято").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 132, height: 132)

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        row("Ёмкость", v.total, dot: nil)
                        Divider().gridCellColumns(2)
                        row("Занято", v.used, dot: .accentColor)
                        row("Свободно", v.available, dot: Color.secondary.opacity(0.3))
                        row("Очищаемое", v.purgeable, dot: nil, quiet: true,
                            help: "Место, которое macOS освободит сама, когда оно понадобится (кэши, локальные снимки)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Не удалось получить данные тома").foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ title: String, _ value: Int64, dot: Color?, quiet: Bool = false, help: String = "") -> some View {
        GridRow {
            HStack(spacing: 8) {
                Circle().fill(dot ?? .clear).frame(width: 8, height: 8)
                Text(title).lineLimit(1).fixedSize()
            }
            .foregroundStyle(quiet ? .secondary : .primary)
            .help(help)
            Text(ByteFormat.string(value))
                .monospacedDigit()
                .fontWeight(quiet ? .regular : .semibold)
                .foregroundStyle(quiet ? .secondary : .primary)
                .gridColumnAlignment(.trailing)
        }
    }
}

private struct ScanCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Анализ") {
            switch model.phase {
            case .idle:
                Text("Просканируйте домашнюю папку или весь диск, чтобы увидеть, что занимает место.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    model.startScan(path: model.home)
                } label: {
                    Label("Сканировать домашнюю папку", systemImage: "house")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                secondaryScanButtons
            case .scanning:
                ProgressView()
                    .progressViewStyle(.linear)
                Text("\(Plural.count(model.progress.files, "файл", "файла", "файлов")) · \(ByteFormat.string(model.progress.bytes))")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(model.displayPath(model.progress.currentPath))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    model.cancelScan()
                } label: {
                    Label("Остановить", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            case .ready:
                if let root = model.root {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.scanPath == model.home ? "Домашняя папка" : model.displayPath(model.scanPath))
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text(ByteFormat.string(root.size))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }
                    Text("\(Plural.count(root.fileCount, "файл", "файла", "файлов")) · \(String(format: "%.1f", model.lastScanDuration)) с · недоступно папок: \(model.progress.unreadable)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.analyzing {
                    ProgressView("Анализ…").controlSize(.small)
                } else {
                    Label("Безопасно освободить: \(ByteFormat.string(model.safeTotal))", systemImage: "leaf.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    Button {
                        model.section = .recommendations
                    } label: {
                        Label("Рекомендации", systemImage: "sparkles").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        model.section = .map
                    } label: {
                        Label("Карта диска", systemImage: "chart.pie").frame(maxWidth: .infinity)
                    }
                }
                .controlSize(.large)
                secondaryScanButtons
            }
        }
    }

    /// Другие варианты сканирования — одинаковые кнопки на всю ширину.
    private var secondaryScanButtons: some View {
        HStack(spacing: 10) {
            if model.phase == .ready {
                Button {
                    model.startScan()
                } label: {
                    Label("Заново", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
            }
            Button {
                model.startScan(path: "/")
            } label: {
                Label("Весь диск", systemImage: "internaldrive").frame(maxWidth: .infinity)
            }
            Button {
                model.chooseFolderAndScan()
            } label: {
                Label("Выбрать папку…", systemImage: "folder").frame(maxWidth: .infinity)
            }
        }
        .controlSize(.large)
    }
}

private struct KindBreakdown: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let total = max(1, model.kindTotals.reduce(Int64(0)) { $0 + $1.size })
        Card(title: "По типам файлов") {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(model.kindTotals) { item in
                        Rectangle()
                            .fill(item.kind.color)
                            .frame(width: max(1, geo.size.width * CGFloat(Double(item.size) / Double(total))))
                            .help("\(item.kind.title): \(ByteFormat.string(item.size))")
                    }
                }
            }
            .frame(height: 18)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(model.kindTotals) { item in
                    HStack(spacing: 6) {
                        Circle().fill(item.kind.color).frame(width: 9, height: 9)
                        Text(item.kind.title)
                        Text(ByteFormat.string(item.size))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }
}

private struct CategoryTiles: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Что можно очистить") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                ForEach(model.categories) { cat in
                    Button {
                        model.section = .recommendations
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(cat.category.title).font(.callout.weight(.semibold))
                            Text(ByteFormat.string(cat.total))
                                .font(.title3.monospacedDigit())
                            RiskBadge(risk: cat.category.risk)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.background, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct LargestFilesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Самые большие файлы") {
            let top = model.largestFiles.prefix(10)
            let maxSize = Double(top.first?.size ?? 1)
            ForEach(Array(top), id: \.id) { node in
                HStack(spacing: 12) {
                    FileRowLabel(name: node.name, path: model.displayPath(node.path), kind: node.kind)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SizeBar(fraction: Double(node.size) / maxSize, color: node.kind.color)
                        .frame(width: 120)
                    Text(ByteFormat.string(node.size))
                        .monospacedDigit()
                        .frame(width: 80, alignment: .trailing)
                    RowActions(path: node.path)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.reveal([node.path]) }
                .contextMenu {
                    FileContextMenu(path: node.path)
                    Divider()
                    Button("Добавить в лоток очистки") { model.addToTray(node) }
                }
            }
        }
    }
}

private struct ChangesSummaryCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ch = model.changes
        if let d = ch.totalDelta, let b = ch.baseline {
            Button {
                model.section = .changes
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: d > 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                        .font(.title)
                        .foregroundStyle(d > 0 ? Color.red : Color.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("С прошлого сканирования (\(b.date.formatted(.relative(presentation: .named))))")
                            .foregroundStyle(.secondary)
                        Text(d == 0 ? "Без изменений" : (d > 0 ? "Занято больше на \(ByteFormat.string(d))" : "Освободилось \(ByteFormat.string(-d))"))
                            .font(.title3.weight(.semibold))
                    }
                    Spacer()
                    if let top = ch.changes.first(where: { $0.delta > 0 }) {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("Больше всего выросло").font(.caption).foregroundStyle(.secondary)
                            Text("\(top.name) \(signed(top.delta))").font(.callout.weight(.medium)).lineLimit(1)
                        }
                    }
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
