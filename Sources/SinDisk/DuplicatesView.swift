import SwiftUI
import QuickLookThumbnailing
import SinDiskCore

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: DuplicateGroup.ID?
    @State private var confirmTrash = false
    @State private var confirmClone = false

    static let sizeOptions: [(title: String, bytes: Int64)] = [
        ("от 1 КБ", 1_000), ("от 1 МБ", 1_000_000), ("от 10 МБ", 10_000_000), ("от 100 МБ", 100_000_000),
    ]

    var body: some View {
        Group {
            if model.root == nil {
                EmptyScanView()
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    content
                }
            }
        }
        .navigationTitle("Дубликаты")
        .confirmationDialog("Переместить в Корзину \(model.markedDuplicateCount) копий (\(ByteFormat.string(model.markedDuplicateTotal)))?",
                            isPresented: $confirmTrash) {
            Button("В Корзину", role: .destructive) { model.cleanDuplicates(useClones: false) }
        } message: {
            Text("В каждой группе остаётся минимум одна копия. Отменить можно в «Истории».")
        }
        .confirmationDialog("Заменить \(model.markedDuplicateCount) копий APFS-клонами?", isPresented: $confirmClone) {
            Button("Заменить клонами") { model.cleanDuplicates(useClones: true) }
        } message: {
            Text("Файлы останутся на своих местах, но будут ссылаться на общие данные. Оригиналы дубликатов уйдут в Корзину — место освободится после её очистки.")
        }
    }

    private var header: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            Picker("Размер", selection: $model.dupMinSize) {
                ForEach(Self.sizeOptions.indices, id: \.self) { i in
                    Text(Self.sizeOptions[i].title).tag(Self.sizeOptions[i].bytes)
                }
            }
            .frame(width: 150)
            Picker("Оставлять", selection: $model.keepRule) {
                ForEach(KeepRule.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 260)
            Spacer()
            if model.dupRunning {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.dupProgress.title).font(.caption)
                    if model.dupProgress.total > 0 {
                        ProgressView(value: Double(model.dupProgress.done), total: Double(model.dupProgress.total))
                            .frame(width: 180)
                    }
                }
                Button("Остановить") { model.cancelDuplicates() }
            } else {
                Button(model.dupSearched ? "Искать заново" : "Найти дубликаты") { model.findDuplicates() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        if model.dupGroups.isEmpty {
            if model.dupRunning {
                ProgressView(model.dupProgress.title).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.dupSearched {
                ContentUnavailableView("Дубликатов нет", systemImage: "checkmark.seal",
                                       description: Text("В \(model.displayPath(model.scanPath)) нет одинаковых файлов выбранного размера."))
            } else {
                ContentUnavailableView {
                    Label("Поиск дубликатов", systemImage: "doc.on.doc")
                } description: {
                    Text("Сравнение по полному содержимому файлов в отсканированной папке. Системные папки, ~/Library, бандлы приложений и медиатека «Фото» не затрагиваются.")
                } actions: {
                    Button("Найти дубликаты") { model.findDuplicates() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            HSplitView {
                VStack(spacing: 0) {
                    DuplicateMap(groups: model.dupGroups, selection: $selection)
                        .frame(height: 190)
                    if model.dupGroups.count > DuplicateMap.limit {
                        Text("На карте — \(DuplicateMap.limit) крупнейших групп из \(model.dupGroups.count); все группы — в списке ниже.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 6)
                    }
                    Divider()
                    List(model.dupGroups, selection: $selection) { g in
                        GroupRow(group: g)
                    }
                }
                .frame(minWidth: 380)
                Group {
                    if let id = selection, let g = model.dupGroups.first(where: { $0.id == id }) {
                        GroupDetail(group: g)
                    } else {
                        ContentUnavailableView("Выберите группу", systemImage: "square.on.square",
                                               description: Text("Кликните по плитке на карте или по строке списка."))
                    }
                }
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Лишних копий: \(ByteFormat.string(model.duplicateWasteTotal)) в \(Plural.count(model.dupGroups.count, "группе", "группах", "группах"))")
                    .font(.headline)
                Text(model.dupMarked.isEmpty
                     ? "Ничего не отмечено. Отметьте копии вручную или кнопкой «Отметить по правилу»."
                     : "Отмечено к удалению: \(Plural.count(model.markedDuplicateCount, "файл", "файла", "файлов")) · \(ByteFormat.string(model.markedDuplicateTotal))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.dupMarked.isEmpty {
                Button("Отметить по правилу") { model.applyKeepRule() }
                    .buttonStyle(.borderedProminent)
                    .help("В каждой группе останется одна копия — по правилу «Оставлять» вверху")
            } else {
                Button("Снять отметки") { model.dupMarked = [] }
                Button("Показать на карте диска") {
                    model.highlight(paths: Array(model.dupMarked))
                }
                Button("Заменить клонами") { confirmClone = true }
                    .disabled(model.cleaning)
                Button("Удалить отмеченные") { confirmTrash = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.cleaning)
            }
        }
        .padding(12)
        .background(.bar)
    }
}

// MARK: - Карта групп: площадь = лишний объём

private struct DuplicateMap: View {
    let groups: [DuplicateGroup]
    @Binding var selection: DuplicateGroup.ID?
    @State private var hovered: DuplicateGroup.ID?

    /// Больше групп на карте превращаются в нечитаемую мозаику.
    static let limit = 40

    var body: some View {
        GeometryReader { geo in
            let shown = Array(groups.prefix(Self.limit))
            let rects = Treemap.squarify(shown.map { Double($0.wasted) },
                                         in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 6, dy: 6))
            Canvas { ctx, _ in
                for (g, rect) in zip(shown, rects) {
                    let r = rect.insetBy(dx: 1, dy: 1)
                    guard r.width > 1, r.height > 1 else { continue }
                    let shape = Path(roundedRect: r, cornerRadius: 4)
                    let isSelected = g.id == selection
                    ctx.fill(shape, with: .color(g.kind.color.opacity(isSelected ? 0.95 : 0.6)))
                    if isSelected || g.id == hovered {
                        ctx.stroke(shape, with: .color(.primary), lineWidth: 2)
                    }
                    if r.width > 70, r.height > 30 {
                        ctx.draw(Text("\(g.name) ×\(g.files.count)").font(.caption.weight(.semibold)),
                                 in: CGRect(x: r.minX + 4, y: r.minY + 3, width: r.width - 8, height: 14))
                        ctx.draw(Text(ByteFormat.string(g.wasted)).font(.caption2),
                                 in: CGRect(x: r.minX + 4, y: r.minY + 17, width: r.width - 8, height: 13))
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case let .active(p) = phase, let i = rects.firstIndex(where: { $0.contains(p) }) {
                    hovered = shown[i].id
                } else {
                    hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { v in
                if let i = rects.firstIndex(where: { $0.contains(v.location) }) { selection = shown[i].id }
            })
            .help(hovered.flatMap { id in groups.first { $0.id == id } }.map {
                "\($0.name): \(Plural.count($0.files.count, "копия", "копии", "копий")) по \(ByteFormat.string($0.size))"
            } ?? "Плитка = группа одинаковых файлов, площадь = лишний объём")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Карта групп дубликатов. Используйте список ниже.")
    }
}

private struct GroupRow: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroup

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: group.kind.symbol)
                .foregroundStyle(group.kind.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).lineLimit(1).truncationMode(.middle)
                Text("\(Plural.count(group.files.count, "копия", "копии", "копий")) по \(ByteFormat.string(group.size)) · \(model.displayPath(group.files[0].directory))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(ByteFormat.string(group.wasted))
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}

private struct GroupDetail: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroup

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Thumbnail(path: group.files[0].path)
                        .frame(width: 96, height: 96)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.name).font(.title3.bold()).lineLimit(2)
                        Text("\(group.files.count) копии · по \(ByteFormat.string(group.size))")
                        Text("Лишний объём: \(ByteFormat.string(group.wasted))")
                            .foregroundStyle(.secondary)
                        Text("Совпадение по полному хэшу содержимого (SHA-256)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(group.files) { file in
                    FileCopyRow(file: file, group: group)
                }
                Text("Отметьте копии для удаления. Одна копия в группе всегда остаётся.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }
}

private struct FileCopyRow: View {
    @Environment(AppModel.self) private var model
    let file: DuplicateFile
    let group: DuplicateGroup

    var body: some View {
        let marked = model.dupMarked.contains(file.path)
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { marked }, set: { _ in model.toggleMark(file, in: group) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayPath(file.path))
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    if marked {
                        Text("в Корзину").foregroundStyle(.red)
                    } else {
                        Label("оставить", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    if let c = file.created { Text("создан \(c.shortString)") }
                    if let m = file.modified { Text("изменён \(m.shortString)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            RowActions(path: file.path)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(marked ? Color.clear : Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(marked ? Color.secondary.opacity(0.3) : Color.accentColor, lineWidth: marked ? 1 : 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.reveal([file.path]) }
        .contextMenu { FileContextMenu(path: file.path) }
    }
}

/// Превью файла через Quick Look Thumbnailing.
struct Thumbnail: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: FileKind(extension: (path as NSString).pathExtension).symbol)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: path) {
            image = nil
            let request = QLThumbnailGenerator.Request(
                fileAt: URL(fileURLWithPath: path),
                size: CGSize(width: 192, height: 192),
                scale: 2,
                representationTypes: .thumbnail
            )
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = rep.nsImage
            }
        }
    }
}
