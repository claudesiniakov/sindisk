import SwiftUI
import Charts
import SinDiskCore

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmUndo: CleanSession?

    var body: some View {
        Group {
            if model.sessions.isEmpty {
                ContentUnavailableView("История пуста", systemImage: "clock",
                                       description: Text("Здесь появятся все очистки за последние 90 дней."))
            } else {
                List {
                    Section {
                        FreedChart(sessions: model.sessions)
                            .frame(height: 140)
                            .padding(.vertical, 6)
                    }
                    Section("Сессии очистки") {
                        ForEach(model.sessions) { s in
                            SessionRow(session: s) { confirmUndo = s }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("История")
        .confirmationDialog("Вернуть файлы сессии на исходные места?",
                            isPresented: Binding(get: { confirmUndo != nil }, set: { if !$0 { confirmUndo = nil } }),
                            presenting: confirmUndo) { s in
            Button("Вернуть \(s.records.filter { $0.trashedPath != nil && $0.status == .done }.count) объектов") {
                model.undo(s)
            }
        } message: { _ in
            Text("Файлы будут перемещены из Корзины обратно. Окончательно удалённые объекты вернуть нельзя.")
        }
    }
}

private struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: CleanSession
    let onUndo: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(session.records) { r in
                HStack {
                    Image(systemName: icon(r.status)).foregroundStyle(color(r.status))
                    VStack(alignment: .leading) {
                        Text(model.displayPath(r.originalPath)).lineLimit(1).truncationMode(.middle)
                        if let m = r.message {
                            Text(m).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(ByteFormat.string(r.size)).font(.caption).monospacedDigit()
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.headline)
                    Text(session.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if session.undone {
                    Text("Отменено").font(.caption).foregroundStyle(.secondary)
                } else if !session.problems.isEmpty {
                    Text("Пропущено: \(session.problems.count)").font(.caption).foregroundStyle(.orange)
                }
                Text(ByteFormat.string(session.freed))
                    .monospacedDigit()
                    .frame(width: 90, alignment: .trailing)
                if session.canUndo {
                    Button("Отменить", action: onUndo)
                }
            }
        }
    }

    private func icon(_ s: CleanRecord.Status) -> String {
        switch s {
        case .done: return "checkmark.circle"
        case .skipped: return "forward.circle"
        case .failed: return "xmark.octagon"
        case .restored: return "arrow.uturn.backward.circle"
        }
    }

    private func color(_ s: CleanRecord.Status) -> Color {
        switch s {
        case .done: return .green
        case .skipped: return .secondary
        case .failed: return .red
        case .restored: return .blue
        }
    }
}

/// Освобождённое место по дням.
private struct FreedChart: View {
    let sessions: [CleanSession]

    struct Point: Identifiable {
        let day: Date
        let bytes: Int64
        var id: Date { day }
    }

    var body: some View {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: sessions.filter { !$0.undone }) { cal.startOfDay(for: $0.date) }
        let points = grouped.map { Point(day: $0.key, bytes: $0.value.reduce(0) { $0 + $1.freed }) }
            .sorted { $0.day < $1.day }
        VStack(alignment: .leading, spacing: 6) {
            Text("Освобождено по дням").font(.headline)
            Chart(points) { p in
                BarMark(x: .value("День", p.day, unit: .day), y: .value("ГБ", Double(p.bytes) / 1e9))
                    .foregroundStyle(Color.accentColor)
            }
            .chartYAxisLabel("ГБ")
        }
    }
}
