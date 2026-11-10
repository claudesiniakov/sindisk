import SwiftUI
import SinDiskCore

struct RecommendationsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false
    @State private var expanded: Set<CleanupCategory> = []

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
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.categories) { result in
                            CategoryCard(result: result, expanded: Binding(
                                get: { expanded.contains(result.category) },
                                set: { if $0 { expanded.insert(result.category) } else { expanded.remove(result.category) } }
                            ))
                        }
                        DevToolsPanel()
                            .padding(.top, 6)
                    }
                    .padding(20)
                }
                .safeAreaInset(edge: .top, spacing: 0) { selectionBar }
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

    /// Итог найденного и массовый выбор.
    private var selectionBar: some View {
        let total = model.categories.reduce(Int64(0)) { $0 + $1.total }
        let allExpanded = expanded.count == model.categories.count
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Найдено \(ByteFormat.string(total)) в \(Plural.count(model.categories.count, "категории", "категориях", "категориях"))")
                    .font(.headline)
                    .monospacedDigit()
                Text("Безопасно (низкий риск): \(ByteFormat.string(model.safeTotal))")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button(allExpanded ? "Свернуть все" : "Развернуть все") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expanded = allExpanded ? [] : Set(model.categories.map(\.category))
                }
            }
            Menu {
                Button("Рекомендуемые") { model.selectRecommended() }
                Button("Только низкий риск") { model.selectAll(maxRisk: .low) }
                Button("Всё, кроме высокого риска") { model.selectAll(maxRisk: .medium) }
                    .keyboardShortcut("a")
                Button("Всё, включая высокий риск") { model.selectAll(maxRisk: .high) }
                Divider()
                Button("Снять выбор") { model.selected.removeAll() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            } label: {
                Label("Выбрать", systemImage: "checklist")
            }
            .fixedSize()
            Button("Снять выбор") { model.selected.removeAll() }
                .disabled(model.selected.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var bottomBar: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(model.selected.isEmpty ? "Ничего не выбрано" : "Выбрано: \(ByteFormat.string(model.selectedTotal))")
                    .font(.headline)
                    .monospacedDigit()
                Text(model.selected.isEmpty ? "Отметьте категории или воспользуйтесь меню «Выбрать»" : "\(Plural.count(model.selectedCandidates.count, "объект", "объекта", "объектов"))")
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
        "Очистить \(Plural.count(model.selectedCandidates.count, "объект", "объекта", "объектов")) (\(ByteFormat.string(model.selectedTotal)))?"
    }

    private var confirmMessage: String {
        let items = model.selectedCandidates
        var lines: [String] = []
        let high = items.filter { $0.category.risk == .high }.count
        if high > 0 { lines.append("Высокий риск: \(Plural.count(high, "объект", "объекта", "объектов")) — проверьте их ещё раз.") }
        let permanent = items.filter { $0.category.deletesPermanently }.count
        if permanent > 0 { lines.append("Содержимое Корзины (\(permanent)) будет удалено окончательно.") }
        lines.append("Остальное переместится в Корзину; отменить можно в «Истории».")
        return lines.joined(separator: "\n")
    }
}

private struct CategoryCard: View {
    @Environment(AppModel.self) private var model
    let result: CategoryResult
    @Binding var expanded: Bool
    @State private var shown = 50

    var body: some View {
        let paths = result.items.map(\.path)
        let selectedCount = paths.filter { model.selected.contains($0) }.count
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 14)

                Button {
                    if selectedCount == paths.count {
                        model.selected.subtract(paths)
                    } else {
                        model.selected.formUnion(paths)
                    }
                } label: {
                    Image(systemName: selectedCount == 0 ? "square"
                          : selectedCount == paths.count ? "checkmark.square.fill" : "minus.square.fill")
                        .font(.title2)
                        .foregroundStyle(selectedCount == 0 ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(selectedCount == paths.count ? "Снять выбор" : "Выбрать всё")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(result.category.title).font(.headline)
                        RiskBadge(risk: result.category.risk)
                    }
                    Text(result.category.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(ByteFormat.string(result.total))
                        .font(.headline)
                        .monospacedDigit()
                    Text("выбрано \(selectedCount) из \(paths.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            }

            if expanded {
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(Array(result.items.prefix(shown).enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 70) }
                        CandidateRow(item: item)
                            .padding(.leading, 42)
                            .padding(.trailing, 16)
                            .padding(.vertical, 6)
                    }
                    if result.items.count > shown {
                        Divider()
                        Button("Показать ещё \(min(100, result.items.count - shown)) из \(result.items.count - shown)") {
                            shown += 100
                        }
                        .buttonStyle(.link)
                        .padding(10)
                    }
                }
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.12)))
    }
}

private struct CandidateRow: View {
    @Environment(AppModel.self) private var model
    let item: Candidate

    /// Путь и пояснение; пояснение не повторяет путь.
    private var subtitle: String {
        let path = model.displayPath(item.path)
        guard let note = item.note, note != path else { return path }
        return path + " · " + note
    }

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
                path: subtitle,
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
            RowActions(path: item.path)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.reveal([item.path]) }
        .contextMenu { FileContextMenu(path: item.path) }
        .help("Двойной клик — показать в Finder")
    }
}
