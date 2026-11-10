import SwiftUI
import SinDiskCore

/// Docker, симуляторы и Homebrew — очистка их собственными командами.
struct DevToolsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var confirm: DevTool?
    @State private var aggressiveDocker = false

    var body: some View {
        let dev = model.devTools
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Инструменты разработчика", systemImage: "hammer")
                    .font(.headline)
                Spacer()
                if dev.loading { ProgressView().controlSize(.small) }
                Button {
                    dev.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Проверить заново")
                .disabled(dev.loading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            // Доступные инструменты — строками, недоступные — одной сноской, чтобы не занимать место.
            let ready = DevTool.allCases.filter { dev.statuses[$0]?.ready == true || dev.running == $0 }
            let unavailable = DevTool.allCases.filter { !ready.contains($0) }
            ForEach(Array(ready.enumerated()), id: \.element) { index, tool in
                if index > 0 { Divider().padding(.leading, 52) }
                row(tool, dev.statuses[tool])
            }
            if !unavailable.isEmpty {
                if !ready.isEmpty { Divider() }
                Text(unavailable.map { "\($0.title): \(dev.statuses[$0]?.note ?? "проверка…")" }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.12)))
        .onAppear { if dev.statuses.isEmpty { dev.refresh() } }
        .confirmationDialog(confirm.map { "Очистить: \($0.title)?" } ?? "",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { tool in
            Button("Выполнить \(tool.command(aggressive: tool == .docker && aggressiveDocker))", role: .destructive) {
                dev.clean(tool, aggressive: tool == .docker && aggressiveDocker)
            }
        } message: { tool in
            Text(tool.detail + "\nОтменить эту очистку нельзя.")
        }
        .alert("Готово", isPresented: Binding(get: { dev.message != nil }, set: { if !$0 { dev.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dev.message ?? "")
        }
    }

    private func row(_ tool: DevTool, _ status: DevToolStatus?) -> some View {
        let dev = model.devTools
        return HStack(spacing: 12) {
            Image(systemName: tool.symbol)
                .font(.title3)
                .foregroundStyle(status?.ready == true ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title).font(.callout.weight(.semibold))
                Text(status?.note ?? "Проверка…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if tool == .docker, status?.ready == true {
                    Toggle("Удалять и неиспользуемые образы (-a)", isOn: $aggressiveDocker)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
            }
            Spacer()
            if let size = status?.reclaimable, status?.ready == true {
                Text(ByteFormat.string(size))
                    .font(.headline)
                    .monospacedDigit()
            }
            if dev.running == tool {
                ProgressView().controlSize(.small)
            } else {
                Button("Очистить…") { confirm = tool }
                    .disabled(status?.ready != true || dev.running != nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
