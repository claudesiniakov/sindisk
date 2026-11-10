import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SinDiskCore

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<SearchHit.ID>()
    @State private var showHelp = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var model = model
        Group {
            if model.root == nil {
                EmptyScanView(message: "Поиск работает по результатам сканирования.")
            } else {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Имя, *.mov, size:>1GB, kind:video, opened:>1y, in:~/Downloads",
                                      text: $model.searchText)
                                .textFieldStyle(.plain)
                                .font(.title3)
                                .focused($fieldFocused)
                                .onSubmit { model.runSearch(); model.rememberQuery() }
                            if model.searching { ProgressView().controlSize(.small) }
                            if !model.searchText.isEmpty {
                                Button {
                                    model.searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            Button {
                                showHelp.toggle()
                            } label: {
                                Image(systemName: "questionmark.circle")
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showHelp) { SearchHelp() }
                        }
                        .padding(10)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

                        QueryChips()

                        ForEach(model.searchErrors, id: \.self) { e in
                            Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(12)
                    Divider()
                    results
                }
            }
        }
        .navigationTitle("Поиск")
        .onChange(of: model.searchText) { model.runSearch() }
        .onAppear { fieldFocused = true }
    }

    @ViewBuilder private var results: some View {
        if model.searchResults.isEmpty {
            ContentUnavailableView(
                model.searchText.isEmpty ? "Введите запрос" : "Ничего не найдено",
                systemImage: "magnifyingglass",
                description: Text(model.searchText.isEmpty
                                  ? "Ищите по имени и фильтрам. Подсказка — кнопка «?»."
                                  : "Попробуйте ослабить фильтры.")
            )
        } else {
            Table(model.searchResults, selection: $selection) {
                TableColumn("Имя") { hit in
                    HStack(spacing: 6) {
                        Image(systemName: hit.kind.symbol).foregroundStyle(hit.kind.color)
                        Text(hit.name).lineLimit(1).truncationMode(.middle)
                    }
                }
                .width(min: 160, ideal: 260)
                TableColumn("Папка") { hit in
                    Text(model.displayPath(hit.directory))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                .width(min: 160, ideal: 320)
                TableColumn("Размер") { hit in
                    Text(ByteFormat.string(hit.size)).monospacedDigit()
                }
                .width(min: 70, ideal: 90)
                TableColumn("Изменён") { hit in
                    Text(hit.modified?.shortString ?? "—").foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 110)
            }
            .contextMenu(forSelectionType: SearchHit.ID.self) { ids in
                Button("Показать в Finder") { model.reveal(Array(ids)) }
                Button("Показать на карте") { model.highlight(paths: Array(ids)) }
                Button("Добавить в лоток очистки") { addToTray(ids) }
            } primaryAction: { ids in
                model.reveal(Array(ids))
            }
            Divider()
            HStack {
                let total = model.searchResults.reduce(Int64(0)) { $0 + $1.size }
                Text("Найдено: \(model.searchResults.count.formatted()) · \(ByteFormat.string(total))")
                    .monospacedDigit()
                if model.searchResults.count >= 5000 {
                    Text("(показаны первые 5000)").foregroundStyle(.secondary)
                }
                Spacer()
                let targets = selection.isEmpty ? Set(model.searchResults.map(\.id)) : selection
                Button(selection.isEmpty ? "Все на карте" : "Выбранные на карте") {
                    model.highlight(paths: Array(targets))
                }
                Button("Показать в Finder") { model.reveal(Array(selection)) }
                    .disabled(selection.isEmpty)
                Button("В лоток очистки") { addToTray(selection) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty)
                Button("Экспорт CSV") { exportCSV() }
            }
            .padding(12)
        }
    }

    private func addToTray(_ ids: Set<SearchHit.ID>) {
        for hit in model.searchResults where ids.contains(hit.id) {
            model.addToTray(path: hit.path, size: hit.size, isDirectory: hit.isDirectory)
        }
        model.section = .map
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SinDisk-поиск.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let iso = ISO8601DateFormatter()
        var lines = ["path,size_bytes,modified"]
        for h in model.searchResults {
            lines.append([esc(h.path), String(h.size), h.modified.map { iso.string(from: $0) } ?? ""].joined(separator: ","))
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct QueryChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(AppModel.presetQueries.indices, id: \.self) { i in
                    chip(AppModel.presetQueries[i].title, query: AppModel.presetQueries[i].query, icon: "sparkle")
                }
                ForEach(model.savedQueries, id: \.self) { q in
                    chip(q, query: q, icon: "folder.badge.gearshape")
                        .contextMenu {
                            Button("Удалить из сохранённых") { model.savedQueries.removeAll { $0 == q } }
                        }
                }
                Menu {
                    if model.recentQueries.isEmpty {
                        Text("История пуста")
                    }
                    ForEach(model.recentQueries, id: \.self) { q in
                        Button(q) { model.searchText = q }
                    }
                } label: {
                    Label("Недавние", systemImage: "clock")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button {
                    model.saveCurrentQuery()
                } label: {
                    Label("Сохранить запрос", systemImage: "plus")
                }
                .disabled(model.searchText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
    }

    private func chip(_ title: String, query: String, icon: String) -> some View {
        Button {
            model.searchText = query
            model.rememberQuery()
        } label: {
            Label(title, systemImage: icon)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(model.searchText == query ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct SearchHelp: View {
    static let rows: [(String, String)] = [
        ("отчёт", "имя содержит «отчёт» (без учёта регистра и ё/е)"),
        ("*.mov  IMG_20??", "маска имени"),
        ("/^IMG_\\d+$/", "регулярное выражение"),
        ("size:>1GB  size:100MB..500MB", "размер на диске"),
        ("ext:dmg,zip", "расширение"),
        ("kind:video", "тип: video, image, audio, archive, installer, document, code, app, folder"),
        ("modified:<7d  modified:<2025-01-01", "изменён за 7 дней / до даты"),
        ("opened:>1y", "не открывался больше года (d, w, m, y)"),
        ("in:~/Downloads  -in:~/Projects", "искать в папке / исключить папку"),
        ("type:file  type:dir", "только файлы / только папки"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Синтаксис поиска").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(0..<Self.rows.count, id: \.self) { i in
                    GridRow {
                        Text(Self.rows[i].0).font(.system(.callout, design: .monospaced))
                        Text(Self.rows[i].1).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Условия складываются через «И». Без фильтров по имени папки не показываются — добавьте type:dir.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 560)
    }
}
