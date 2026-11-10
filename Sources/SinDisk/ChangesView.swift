import SwiftUI
import Charts
import SinDiskCore

/// Что выросло и что уменьшилось между сканированиями одной папки.
struct ChangesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ch = model.changes
        Group {
            if model.root == nil {
                EmptyScanView(message: "Изменения считаются между сканированиями одной и той же папки.")
            } else if ch.snapshots.count < 2 {
                ContentUnavailableView {
                    Label("Пока не с чем сравнивать", systemImage: "chart.line.uptrend.xyaxis")
                } description: {
                    Text("Нужно хотя бы два сканирования «\(model.displayPath(model.scanPath))». SinDisk запоминает каждое сканирование — пересканируйте через день-другой, и здесь появится, что выросло.")
                } actions: {
                    Button("Сканировать заново") { model.startScan() }
                }
            } else {
                content
            }
        }
        .navigationTitle("Изменения")
    }

    private var content: some View {
        let ch = model.changes
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Picker("Сравнить с", selection: Binding(get: { ch.baselineIndex }, set: { ch.setBaseline($0) })) {
                        ForEach(1..<ch.snapshots.count, id: \.self) { i in
                            Text(label(for: ch.snapshots[i])).tag(i)
                        }
                    }
                    .frame(maxWidth: 360)
                    Spacer()
                    if let d = ch.totalDelta, let b = ch.baseline, let c = ch.current {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(signed(d))
                                .font(.title2.bold().monospacedDigit())
                                .foregroundStyle(d > 0 ? Color.red : Color.green)
                            Text("\(ByteFormat.string(b.total)) → \(ByteFormat.string(c.total))")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                // График на двух точках ничего не показывает — появляется с третьего сканирования.
                if ch.snapshots.count >= 3 {
                    TotalsChart(snapshots: ch.snapshots)
                        .frame(height: 110)
                }
            }
            .padding(16)
            Divider()
            if ch.changes.isEmpty {
                ContentUnavailableView("Заметных изменений нет", systemImage: "equal.circle",
                                       description: Text("Ни одна папка не изменилась больше чем на 10 МБ."))
            } else {
                let maxDelta = Double(ch.changes.map { abs($0.delta) }.max() ?? 1)
                List(ch.changes) { change in
                    ChangeRow(change: change, root: ch.current?.rootPath ?? model.scanPath, maxDelta: maxDelta)
                }
                .listStyle(.inset)
            }
        }
    }

    private func label(for s: ScanSnapshot) -> String {
        "\(s.date.formatted(date: .abbreviated, time: .shortened)) (\(s.date.formatted(.relative(presentation: .named))))"
    }
}

func signed(_ bytes: Int64) -> String {
    (bytes > 0 ? "+" : bytes < 0 ? "−" : "") + ByteFormat.string(abs(bytes))
}

private struct TotalsChart: View {
    let snapshots: [ScanSnapshot]

    var body: some View {
        Chart(Array(snapshots.reversed())) { s in
            LineMark(x: .value("Дата", s.date), y: .value("ГБ", Double(s.total) / 1e9))
                .interpolationMethod(.monotone)
            PointMark(x: .value("Дата", s.date), y: .value("ГБ", Double(s.total) / 1e9))
                .symbolSize(24)
        }
        .chartYAxisLabel("ГБ")
        .chartYScale(domain: .automatic(includesZero: false))
    }
}

private struct ChangeRow: View {
    @Environment(AppModel.self) private var model
    let change: SizeChange
    let root: String
    let maxDelta: Double

    var body: some View {
        let path = root.hasSuffix("/") ? root + change.path : root + "/" + change.path
        let grew = change.delta > 0
        HStack(spacing: 12) {
            Image(systemName: grew ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                .foregroundStyle(grew ? Color.red : Color.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(change.path.split(separator: "/").suffix(2).joined(separator: " / "))
                        .lineLimit(1).truncationMode(.middle)
                    if change.isNew { tag("новое", .blue) }
                    if change.isGone { tag("удалено", .secondary) }
                }
                Text(model.displayPath((path as NSString).deletingLastPathComponent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(ByteFormat.string(change.before)) → \(ByteFormat.string(change.after))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 170, alignment: .trailing)
            SizeBar(fraction: Double(abs(change.delta)) / maxDelta, color: grew ? .red.opacity(0.7) : .green.opacity(0.7))
                .frame(width: 90)
            Text(signed(change.delta))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(grew ? Color.red : Color.green)
                .frame(width: 90, alignment: .trailing)
            RowActions(path: path, showMap: !change.isGone)
                .disabled(change.isGone)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !change.isGone { model.reveal([path]) } }
        .contextMenu { if !change.isGone { FileContextMenu(path: path) } }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
