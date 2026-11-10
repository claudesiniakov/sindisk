import SwiftUI
import SinDiskCore

enum MapMode: String, CaseIterable, Identifiable {
    case sunburst, treemap, list
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sunburst: return "Кольца"
        case .treemap: return "Плитки"
        case .list: return "Список"
        }
    }
    var icon: String {
        switch self {
        case .sunburst: return "chart.pie"
        case .treemap: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

enum ColorMode: String, CaseIterable, Identifiable {
    case type, age
    var id: String { rawValue }
    var title: String { self == .type ? "По типу" : "По возрасту" }
}

/// Что сейчас под курсором на карте.
struct HoverTarget: Equatable {
    let node: FileNode
    let otherCount: Int

    static func == (a: HoverTarget, b: HoverTarget) -> Bool {
        a.node === b.node && a.otherCount == b.otherCount
    }
}

struct VisualizationView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("mapMode") private var mode: MapMode = .sunburst
    @AppStorage("colorMode") private var colorMode: ColorMode = .type
    @State private var hovered: HoverTarget?
    @State private var hoverPoint: CGPoint = .zero

    var body: some View {
        if let root = model.root {
            let focus = model.focus ?? root
            HSplitView {
                VStack(spacing: 0) {
                    MapHeader(focus: focus, mode: $mode, colorMode: $colorMode)
                    Divider()
                    if model.highlightPaths != nil {
                        HighlightBanner()
                    }
                    ZStack(alignment: .topLeading) {
                        switch mode {
                        case .sunburst:
                            SunburstView(focus: focus, colorMode: colorMode, version: model.treeVersion,
                                         hovered: $hovered, hoverPoint: $hoverPoint)
                        case .treemap:
                            TreemapView(focus: focus, colorMode: colorMode, version: model.treeVersion,
                                        hovered: $hovered, hoverPoint: $hoverPoint)
                        case .list:
                            NodeListView(focus: focus)
                        }
                        if mode != .list, let h = hovered {
                            GeometryReader { geo in
                                HoverCard(target: h, root: root)
                                    .fixedSize()
                                    .offset(x: min(hoverPoint.x + 16, max(0, geo.size.width - 260)),
                                            y: min(hoverPoint.y + 16, max(0, geo.size.height - 130)))
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contextMenu { mapContextMenu }
                    Divider()
                    MapLegend(colorMode: colorMode)
                }
                .frame(minWidth: 560)
                CleanupTrayView()
                    .frame(minWidth: 240, idealWidth: 290, maxWidth: 380)
            }
            .navigationTitle("Карта диска")
        } else {
            EmptyScanView()
        }
    }

    @ViewBuilder private var mapContextMenu: some View {
        if let h = hovered {
            let node = h.node
            Text(h.otherCount > 0 ? "Мелкие элементы в «\(node.displayName)»" : node.displayName)
            Button("Показать в Finder") { model.reveal([node.path]) }
            Button("Открыть") { model.openItem(node.path) }
            if h.otherCount == 0 {
                Button("Добавить в лоток очистки") { model.addToTray(node) }
                if node.isDirectory {
                    Button("Открыть на карте") { model.open(node) }
                }
            }
        }
    }
}

// MARK: - Заголовок: хлебные крошки и режимы

private struct MapHeader: View {
    @Environment(AppModel.self) private var model
    let focus: FileNode
    @Binding var mode: MapMode
    @Binding var colorMode: ColorMode

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.goUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(focus.parent == nil)
            .help("На уровень вверх (⌘↑)")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(focus.ancestry, id: \.id) { node in
                        if node !== focus.ancestry.first {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button(node.displayName) { model.focus = node }
                            .buttonStyle(.plain)
                            .foregroundStyle(node === focus ? .primary : .secondary)
                            .fontWeight(node === focus ? .semibold : .regular)
                    }
                }
            }
            Spacer(minLength: 8)
            Text(ByteFormat.string(focus.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Picker("Цвет", selection: $colorMode) {
                ForEach(ColorMode.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)
            Picker("Вид", selection: $mode) {
                ForEach(MapMode.allCases) { m in
                    Label(m.title, systemImage: m.icon).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct HighlightBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Image(systemName: "highlighter")
            Text("Подсвечены результаты поиска: \(model.highlightPaths?.count ?? 0)")
            Spacer()
            Button("Сбросить подсветку") { model.clearHighlight() }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.1))
    }
}

private struct MapLegend: View {
    let colorMode: ColorMode
    static let ages: [(days: Double, title: String)] = [
        (0, "сегодня"), (30, "месяц"), (365, "год"), (1825, "5 лет и старше"),
    ]

    var body: some View {
        HStack(spacing: 14) {
            if colorMode == .type {
                ForEach(FileKind.allCases.filter { $0 != .folder }) { k in
                    HStack(spacing: 4) {
                        Circle().fill(k.color).frame(width: 8, height: 8)
                        Text(k.title)
                    }
                }
                Text("Папки — оттенками ветки").foregroundStyle(.secondary)
            } else {
                Text("Изменено:")
                ForEach(0..<Self.ages.count, id: \.self) { i in
                    HStack(spacing: 4) {
                        Circle().fill(ageColor(Date().addingTimeInterval(-Self.ages[i].days * 86_400)))
                            .frame(width: 8, height: 8)
                        Text(Self.ages[i].title)
                    }
                }
            }
            Spacer()
            Text("Клик — открыть папку · клик в центре — вверх · правый клик — действия")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct HoverCard: View {
    let target: HoverTarget
    let root: FileNode

    var body: some View {
        let n = target.node
        VStack(alignment: .leading, spacing: 3) {
            if target.otherCount > 0 {
                Text("Мелкие элементы: \(target.otherCount)").font(.headline)
                Text("в папке «\(n.displayName)»").foregroundStyle(.secondary)
            } else {
                Text(n.displayName).font(.headline).lineLimit(1)
                Text(ByteFormat.string(n.size)).monospacedDigit()
                if let p = n.parent, p.size > 0 {
                    Text("\(percent(n.size, p.size)) от «\(p.displayName)» · \(percent(n.size, root.size)) от всего")
                        .foregroundStyle(.secondary)
                }
                if n.isDirectory {
                    Text("\(n.fileCount.formatted()) файлов").foregroundStyle(.secondary)
                }
                if let m = n.modified {
                    Text("Изменён \(m.shortString)").foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
    }

    private func percent(_ a: Int64, _ b: Int64) -> String {
        let v = Double(a) / Double(max(b, 1)) * 100
        return v < 0.1 ? "<0,1%" : String(format: "%.1f%%", v)
    }
}

// MARK: - Раскраска

struct HighlightSet {
    let exact: Set<ObjectIdentifier>
    let all: Set<ObjectIdentifier>

    func contains(_ node: FileNode) -> Bool {
        if all.contains(node.id) { return true }
        var cur = node.parent
        while let n = cur {
            if exact.contains(n.id) { return true }
            cur = n.parent
        }
        return false
    }
}

extension AppModel {
    var highlightSet: HighlightSet? {
        highlightPaths == nil ? nil : HighlightSet(exact: highlightExact, all: highlightAll)
    }
}

func mapColor(for node: FileNode, branch: Int, depth: Int, colorMode: ColorMode, highlight: HighlightSet?) -> Color {
    var color: Color
    switch colorMode {
    case .type:
        if node.isDirectory, node.kind == .folder {
            color = Color(hue: Double(branch % 10) / 10, saturation: 0.42,
                          brightness: max(0.55, 0.92 - 0.06 * Double(depth)))
        } else {
            color = node.kind.color
        }
    case .age:
        color = ageColor(node.modified)
    }
    if let highlight, !highlight.contains(node) {
        color = color.opacity(0.15)
    }
    return color
}

// MARK: - Кольцевая диаграмма

struct SunburstView: View {
    @Environment(AppModel.self) private var model
    let focus: FileNode
    let colorMode: ColorMode
    let version: Int
    @Binding var hovered: HoverTarget?
    @Binding var hoverPoint: CGPoint

    static let rings = 6

    var body: some View {
        let arcs = Sunburst.layout(root: focus, maxDepth: Self.rings)
        let highlight = model.highlightSet
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = max(40, min(geo.size.width, geo.size.height) / 2 - 16)
            let inner = radius * 0.22
            let ring = (radius - inner) / CGFloat(Self.rings)

            Canvas { ctx, _ in
                let separator = Color(nsColor: .windowBackgroundColor)
                for arc in arcs {
                    let r0 = inner + ring * CGFloat(arc.depth - 1)
                    let r1 = r0 + ring - 1
                    var path = Path()
                    path.addArc(center: center, radius: r1, startAngle: .radians(arc.start - .pi / 2),
                                endAngle: .radians(arc.end - .pi / 2), clockwise: false)
                    path.addArc(center: center, radius: r0, startAngle: .radians(arc.end - .pi / 2),
                                endAngle: .radians(arc.start - .pi / 2), clockwise: true)
                    path.closeSubpath()
                    let fill: Color = arc.isOther
                        ? Color.gray.opacity(0.25)
                        : mapColor(for: arc.node, branch: arc.branch, depth: arc.depth, colorMode: colorMode, highlight: highlight)
                    ctx.fill(path, with: .color(fill))
                    ctx.stroke(path, with: .color(separator), lineWidth: 0.6)
                    if let h = hovered, h.node === arc.node, h.otherCount == arc.otherCount {
                        ctx.stroke(path, with: .color(.primary), lineWidth: 2)
                    }
                }
                let centerCircle = Path(ellipseIn: CGRect(x: center.x - inner + 3, y: center.y - inner + 3,
                                                          width: (inner - 3) * 2, height: (inner - 3) * 2))
                ctx.fill(centerCircle, with: .color(.secondary.opacity(0.1)))
                ctx.draw(Text(focus.displayName).font(.headline), at: CGPoint(x: center.x, y: center.y - 10))
                ctx.draw(Text(ByteFormat.string(focus.size)).font(.title3.monospacedDigit()),
                         at: CGPoint(x: center.x, y: center.y + 12))
                if focus.parent != nil {
                    ctx.draw(Text("↑ вверх").font(.caption).foregroundStyle(.secondary),
                             at: CGPoint(x: center.x, y: center.y + 34))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(point):
                    hoverPoint = point
                    hovered = target(at: point, center: center, inner: inner, ring: ring, arcs: arcs)
                case .ended:
                    hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                let d = hypot(value.location.x - center.x, value.location.y - center.y)
                if d < inner {
                    model.goUp()
                    hovered = nil
                } else if let t = target(at: value.location, center: center, inner: inner, ring: ring, arcs: arcs),
                          t.otherCount == 0, t.node.isDirectory {
                    model.open(t.node)
                    hovered = nil
                }
            })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Кольцевая диаграмма папки \(focus.displayName), \(ByteFormat.string(focus.size)). Для чтения с VoiceOver используйте режим «Список».")
    }

    private func target(at p: CGPoint, center: CGPoint, inner: CGFloat, ring: CGFloat, arcs: [SunburstArc]) -> HoverTarget? {
        let dx = Double(p.x - center.x), dy = Double(p.y - center.y)
        let d = hypot(dx, dy)
        guard d >= Double(inner) else { return nil }
        let depth = Int((d - Double(inner)) / Double(ring)) + 1
        guard depth <= Self.rings else { return nil }
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        guard let arc = Sunburst.hit(arcs, depth: depth, angle: angle) else { return nil }
        return HoverTarget(node: arc.node, otherCount: arc.otherCount)
    }
}

// MARK: - Плитки (treemap)

struct TreemapView: View {
    @Environment(AppModel.self) private var model
    let focus: FileNode
    let colorMode: ColorMode
    let version: Int
    @Binding var hovered: HoverTarget?
    @Binding var hoverPoint: CGPoint

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size).insetBy(dx: 6, dy: 6)
            let tiles = Treemap.tiles(for: focus, in: bounds, levels: 2)
            let highlight = model.highlightSet
            Canvas { ctx, _ in
                let branchIndex = Dictionary(uniqueKeysWithValues: focus.children.enumerated().map { ($1.id, $0) })
                for tile in tiles {
                    let r = tile.rect.insetBy(dx: 1, dy: 1)
                    guard r.width > 0, r.height > 0 else { continue }
                    let shape = Path(roundedRect: r, cornerRadius: 3)
                    let top = tile.level == 1 ? tile.node : (tile.node.parent ?? tile.node)
                    let branch = branchIndex[top.id] ?? 0
                    var fill = mapColor(for: tile.node, branch: branch, depth: tile.level, colorMode: colorMode, highlight: highlight)
                    if tile.level == 1, tile.node.isDirectory, !tile.node.children.isEmpty, r.width > 70, r.height > 48 {
                        fill = fill.opacity(0.35)
                    }
                    ctx.fill(shape, with: .color(fill))
                    ctx.stroke(shape, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1)
                    if let h = hovered, h.node === tile.node {
                        ctx.stroke(shape, with: .color(.primary), lineWidth: 2)
                    }
                    if r.width > 54, r.height > 16 {
                        let label = Text(tile.node.name).font(tile.level == 1 ? .caption.weight(.semibold) : .caption2)
                        ctx.draw(label, in: CGRect(x: r.minX + 4, y: r.minY + 2, width: r.width - 8, height: 14))
                    }
                    if tile.level == 1, r.width > 80, r.height > 34, tile.node.children.isEmpty || !tile.node.isDirectory {
                        ctx.draw(Text(ByteFormat.string(tile.node.size)).font(.caption2).foregroundStyle(.secondary),
                                 in: CGRect(x: r.minX + 4, y: r.minY + 16, width: r.width - 8, height: 14))
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(point):
                    hoverPoint = point
                    hovered = tiles.last(where: { $0.rect.contains(point) }).map { HoverTarget(node: $0.node, otherCount: 0) }
                case .ended:
                    hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                guard let tile = tiles.last(where: { $0.rect.contains(value.location) }) else { return }
                let node = tile.node.isDirectory ? tile.node : (tile.node.parent ?? focus)
                if node !== focus { model.open(node) }
                hovered = nil
            })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Плиточная карта папки \(focus.displayName). Для VoiceOver используйте режим «Список».")
    }
}

// MARK: - Список

struct NodeListView: View {
    @Environment(AppModel.self) private var model
    let focus: FileNode

    var body: some View {
        let items = Array(focus.children.prefix(1000))
        List(items, id: \.id) { node in
            HStack(spacing: 12) {
                Image(systemName: node.kind.symbol)
                    .foregroundStyle(node.kind.color)
                    .frame(width: 18)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SizeBar(fraction: Double(node.size) / Double(max(focus.size, 1)), color: node.kind.color)
                    .frame(width: 140)
                Text(ByteFormat.string(node.size))
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
                if node.isDirectory {
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.open(node) }
            .contextMenu {
                Button("Показать в Finder") { model.reveal([node.path]) }
                Button("Открыть") { model.openItem(node.path) }
                Button("Добавить в лоток очистки") { model.addToTray(node) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(node.isDirectory ? "Открыть папку" : "")
        }
    }
}

// MARK: - Лоток очистки

struct CleanupTrayView: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Лоток очистки").font(.headline)
                Text(model.tray.isEmpty ? "Правый клик по элементу → «Добавить в лоток»"
                                        : "\(model.tray.count) объектов · \(ByteFormat.string(model.trayTotal))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            List {
                ForEach(model.tray) { item in
                    HStack {
                        FileRowLabel(name: item.name, path: model.displayPath(item.path),
                                     kind: item.isDirectory ? .folder : FileKind(extension: (item.path as NSString).pathExtension))
                        Spacer()
                        Text(ByteFormat.string(item.size)).font(.caption).monospacedDigit()
                        Button {
                            model.tray.removeAll { $0.path == item.path }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Divider()
            HStack {
                Button("Очистить список") { model.tray.removeAll() }
                    .disabled(model.tray.isEmpty)
                Spacer()
                Button("В Корзину") { confirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.tray.isEmpty || model.cleaning)
            }
            .padding(12)
        }
        .confirmationDialog("Переместить в Корзину \(model.tray.count) объектов (\(ByteFormat.string(model.trayTotal)))?",
                            isPresented: $confirm) {
            Button("Переместить в Корзину", role: .destructive) { model.cleanTray() }
        } message: {
            Text("Защищённые системные и личные папки будут пропущены. Отменить можно в «Истории».")
        }
    }
}
