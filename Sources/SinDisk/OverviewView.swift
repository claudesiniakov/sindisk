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
                    ScanCard()
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
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
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
                HStack(spacing: 20) {
                    ZStack {
                        Circle().stroke(.quaternary, lineWidth: 14)
                        Circle()
                            .trim(from: 0, to: CGFloat(Double(v.used) / Double(max(v.total, 1))))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 2) {
                            Text("\(Int((Double(v.used) / Double(max(v.total, 1)) * 100).rounded()))%")
                                .font(.title2.bold().monospacedDigit())
                            Text("занято").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 120, height: 120)
                    Grid(alignment: .leading, verticalSpacing: 6) {
                        row("Ёмкость", v.total)
                        row("Занято", v.used)
                        row("Свободно", v.available)
                        row("Освобождаемое системой", v.purgeable)
                    }
                }
            } else {
                Text("Не удалось получить данные тома").foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ title: String, _ value: Int64) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(ByteFormat.string(value)).monospacedDigit()
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
                scanButtons
            case .scanning:
                ProgressView()
                    .progressViewStyle(.linear)
                Text("\(model.progress.files.formatted()) файлов · \(ByteFormat.string(model.progress.bytes))")
                    .monospacedDigit()
                Text(model.displayPath(model.progress.currentPath))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Остановить") { model.cancelScan() }
            case .ready:
                if let root = model.root {
                    Text("\(model.displayPath(model.scanPath)): \(ByteFormat.string(root.size))")
                        .font(.title3.weight(.semibold))
                    Text("\(root.fileCount.formatted()) файлов · \(String(format: "%.1f", model.lastScanDuration)) с · недоступно папок: \(model.progress.unreadable)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.analyzing {
                    ProgressView("Анализ…").controlSize(.small)
                } else {
                    Text("Безопасно освободить: \(ByteFormat.string(model.safeTotal))")
                        .font(.headline)
                        .foregroundStyle(.green)
                }
                HStack {
                    Button("Рекомендации") { model.section = .recommendations }
                        .buttonStyle(.borderedProminent)
                    Button("Карта диска") { model.section = .map }
                }
                scanButtons
            }
        }
    }

    private var scanButtons: some View {
        HStack {
            Button("Домашняя папка") { model.startScan(path: model.home) }
            Button("Весь диск") { model.startScan(path: "/") }
            Button("Папка…") { model.chooseFolderAndScan() }
        }
        .controlSize(.small)
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
                }
                .contextMenu {
                    Button("Показать в Finder") { model.reveal([node.path]) }
                    Button("Добавить в лоток очистки") { model.addToTray(node) }
                }
            }
        }
    }
}
