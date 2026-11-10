import SwiftUI
import SinDiskCore

struct RecommendationsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false

    var body: some View {
        Group {
            if model.root == nil, model.categories.isEmpty {
                EmptyScanView()
            } else if model.analyzing, model.categories.isEmpty {
                ProgressView("Анализ…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.categories.isEmpty {
                ContentUnavailableView("Чисто", systemImage: "checkmark.seal",
                                       description: Text("Ничего лишнего не найдено."))
            } else {
                List {
                    ForEach(model.categories) { result in
                        CategorySection(result: result)
                    }
                }
                .listStyle(.inset)
                .safeAreaInset(edge: .bottom) { bottomBar }
            }
        }
        .navigationTitle("Рекомендации")
        .confirmationDialog(confirmTitle, isPresented: $confirm) {
            Button("Очистить", role: .destructive) { model.cleanSelectedRecommendations() }
        } message: {
            Text(confirmMessage)
        }
    }

    private var bottomBar: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Выбрано: \(ByteFormat.string(model.selectedTotal))")
                    .font(.headline)
                    .monospacedDigit()
                Text("\(model.selectedCandidates.count) объектов")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.cleaning { ProgressView().controlSize(.small) }
            Button("Очистить выбранное") { confirm = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.selected.isEmpty || model.cleaning)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var confirmTitle: String {
        "Очистить \(model.selectedCandidates.count) объектов (\(ByteFormat.string(model.selectedTotal)))?"
    }

    private var confirmMessage: String {
        let items = model.selectedCandidates
        var lines: [String] = []
        let high = items.filter { $0.category.risk == .high }.count
        if high > 0 { lines.append("Высокий риск: \(high) объектов — проверьте их ещё раз.") }
        let permanent = items.filter { $0.category.deletesPermanently }.count
        if permanent > 0 { lines.append("Содержимое Корзины (\(permanent)) будет удалено окончательно.") }
        lines.append("Остальное переместится в Корзину; отменить можно в «Истории».")
        return lines.joined(separator: "\n")
    }
}

private struct CategorySection: View {
    @Environment(AppModel.self) private var model
    let result: CategoryResult
    @State private var expanded = false

    var body: some View {
        let paths = result.items.map(\.path)
        let selectedCount = paths.filter { model.selected.contains($0) }.count
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(result.items) { item in
                    CandidateRow(item: item)
                }
            } label: {
                HStack(spacing: 10) {
                    Button {
                        if selectedCount == paths.count {
                            model.selected.subtract(paths)
                        } else {
                            model.selected.formUnion(paths)
                        }
                    } label: {
                        Image(systemName: selectedCount == 0 ? "square"
                              : selectedCount == paths.count ? "checkmark.square.fill" : "minus.square.fill")
                            .font(.title3)
                            .foregroundStyle(selectedCount == 0 ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(selectedCount == paths.count ? "Снять выбор" : "Выбрать всё")

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(result.category.title).font(.headline)
                            RiskBadge(risk: result.category.risk)
                        }
                        Text(result.category.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(ByteFormat.string(result.total))
                            .font(.headline)
                            .monospacedDigit()
                        Text("\(selectedCount) из \(paths.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct CandidateRow: View {
    @Environment(AppModel.self) private var model
    let item: Candidate

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.selected.contains(item.path) },
                set: { on in
                    if on { model.selected.insert(item.path) } else { model.selected.remove(item.path) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            FileRowLabel(
                name: item.name,
                path: [model.displayPath(item.path), item.note].compactMap { $0 }.joined(separator: " · "),
                kind: item.isDirectory ? .folder : FileKind(extension: (item.name as NSString).pathExtension)
            )
            Spacer()
            if let m = item.modified {
                Text(m.shortString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(ByteFormat.string(item.size))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
        }
        .contextMenu {
            Button("Показать в Finder") { model.reveal([item.path]) }
            Button("Открыть") { model.openItem(item.path) }
            Button("Показать на карте") { model.highlight(paths: [item.path]) }
        }
    }
}
