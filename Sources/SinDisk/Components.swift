import SwiftUI
import Quartz
import SinDiskCore

extension FileKind {
    var color: Color {
        switch self {
        case .folder: return Color(hue: 0.58, saturation: 0.35, brightness: 0.80)
        case .app: return Color(hue: 0.70, saturation: 0.50, brightness: 0.85)
        case .video: return Color(hue: 0.80, saturation: 0.50, brightness: 0.85)
        case .image: return Color(hue: 0.92, saturation: 0.45, brightness: 0.90)
        case .audio: return Color(hue: 0.08, saturation: 0.60, brightness: 0.95)
        case .archive: return Color(hue: 0.11, saturation: 0.45, brightness: 0.70)
        case .diskImage: return Color(hue: 0.00, saturation: 0.55, brightness: 0.88)
        case .document: return Color(hue: 0.60, saturation: 0.60, brightness: 0.90)
        case .code: return Color(hue: 0.47, saturation: 0.55, brightness: 0.75)
        case .other: return Color(hue: 0.0, saturation: 0.0, brightness: 0.70)
        }
    }

    var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .app: return "app.fill"
        case .video: return "film"
        case .image: return "photo"
        case .audio: return "music.note"
        case .archive: return "archivebox"
        case .diskImage: return "opticaldiscdrive"
        case .document: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .other: return "doc"
        }
    }
}

extension Risk {
    var color: Color {
        switch self {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }
}

/// Цвет по возрасту: свежие — зелёные, старые (5+ лет) — красные.
func ageColor(_ date: Date?, now: Date = Date()) -> Color {
    guard let date else { return .gray.opacity(0.5) }
    let days = max(0, now.timeIntervalSince(date) / 86_400)
    let t = min(1, log(1 + days) / log(1 + 1825))
    return Color(hue: 0.33 * (1 - t), saturation: 0.55, brightness: 0.88)
}

struct RiskBadge: View {
    let risk: Risk

    var body: some View {
        Text(risk.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(risk.color.opacity(0.15), in: Capsule())
            .foregroundStyle(risk.color)
    }
}

struct SizeBar: View {
    let fraction: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color)
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
    }
}

struct FileRowLabel: View {
    let name: String
    let path: String
    let kind: FileKind

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1).truncationMode(.middle)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

extension Date {
    var shortString: String { formatted(date: .abbreviated, time: .omitted) }
}

// MARK: - Быстрый просмотр и действия с файлом

/// Quick Look для произвольных путей (как пробел в Finder).
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var urls: [URL] = []

    func show(_ paths: [String]) {
        urls = paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}

/// Кнопки на строке файла: быстрый просмотр, Finder, карта диска.
struct RowActions: View {
    @Environment(AppModel.self) private var model
    let path: String
    var showMap = true

    var body: some View {
        HStack(spacing: 0) {
            action("eye", "Быстрый просмотр") { QuickLook.shared.show([path]) }
            action("folder", "Показать в Finder") { model.reveal([path]) }
            if showMap {
                action("chart.pie", "Показать на карте диска") { model.highlight(paths: [path]) }
            }
        }
    }

    private func action(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Контекстное меню строки файла — те же действия плюс «Открыть».
struct FileContextMenu: View {
    @Environment(AppModel.self) private var model
    let path: String

    var body: some View {
        Button("Быстрый просмотр") { QuickLook.shared.show([path]) }
        Button("Показать в Finder") { model.reveal([path]) }
        Button("Открыть") { model.openItem(path) }
        Button("Показать на карте диска") { model.highlight(paths: [path]) }
    }
}
