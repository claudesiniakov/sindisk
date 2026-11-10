import SwiftUI
import AppKit
import SinDiskCore

/// Деинсталлятор: приложение целиком вместе с кэшами, настройками и контейнерами.
struct AppsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let apps = model.apps
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Поиск приложения", text: Binding(get: { apps.filter }, set: { apps.filter = $0 }))
                        .textFieldStyle(.plain)
                    if apps.loading || apps.measuring { ProgressView().controlSize(.small) }
                    Button {
                        apps.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Обновить список")
                }
                .padding(10)
                Divider()
                List(apps.visibleApps, selection: Binding(get: { apps.selectedID }, set: { apps.select($0) })) { app in
                    AppRow(app: app)
                        .tag(app.id)
                }
                .overlay {
                    if apps.loading && apps.apps.isEmpty { ProgressView("Поиск приложений…") }
                }
                Divider()
                Text(apps.measuring ? "Подсчёт размеров…" : "\(apps.apps.count) приложений · без встроенных приложений Apple")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 460)

            Group {
                if let app = apps.selected {
                    AppDetail(app: app)
                } else {
                    ContentUnavailableView("Выберите приложение", systemImage: "square.grid.3x3.square",
                                           description: Text("SinDisk покажет, сколько места оно занимает вместе с кэшами, настройками и данными, и удалит всё разом."))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Приложения")
        .onAppear { apps.loadIfNeeded() }
    }
}

private struct AppIcon: View {
    let path: String
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: size, height: size)
    }
}

private struct AppRow: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(path: app.path)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).lineLimit(1)
                Text(app.lastUsed.map { "Запуск: \($0.shortString)" } ?? (app.version.map { "Версия \($0)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(app.bundleSize > 0 ? ByteFormat.string(app.bundleSize) : "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct AppDetail: View {
    @Environment(AppModel.self) private var model
    let app: InstalledApp
    @State private var confirm = false

    var body: some View {
        let apps = model.apps
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 16) {
                        AppIcon(path: app.path, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(.title2.bold())
                            Text([app.version.map { "Версия \($0)" }, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            HStack(spacing: 8) {
                                if app.isAppStore {
                                    Label("App Store", systemImage: "bag").font(.caption)
                                }
                                if let last = app.lastUsed {
                                    Text("Последний запуск: \(last.formatted(.relative(presentation: .named)))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                    }

                    if apps.runningApp(app) != nil {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("Приложение запущено. Закройте его перед удалением.")
                            Spacer()
                            Button("Завершить") { apps.quit(app) }
                        }
                        .padding(10)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }

                    HStack(spacing: 24) {
                        stat("Приложение", app.bundleSize)
                        stat("Данные и кэши", apps.leftoversTotal)
                        stat("Всего", app.bundleSize + apps.leftoversTotal, accent: true)
                    }

                    if apps.filesLoading {
                        ProgressView("Поиск связанных файлов…").controlSize(.small)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(apps.files.enumerated()), id: \.element.id) { index, file in
                                if index > 0 { Divider().padding(.leading, 40) }
                                AppFileRow(file: file)
                            }
                        }
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                        if apps.files.count == 1 {
                            Text("Связанных файлов в ~/Library не найдено.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                VStack(alignment: .leading) {
                    Text("Будет удалено: \(ByteFormat.string(apps.checkedTotal))").font(.headline).monospacedDigit()
                    Text("Всё переместится в Корзину — можно вернуть в «Истории».")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(apps.checked.contains(app.path) ? "Удалить приложение" : "Удалить выбранное") { confirm = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(apps.checked.isEmpty || apps.filesLoading || model.cleaning)
            }
            .padding(16)
            .background(.bar)
        }
        .confirmationDialog("Удалить «\(app.name)» и связанные файлы (\(ByteFormat.string(apps.checkedTotal)))?",
                            isPresented: $confirm) {
            Button("Переместить в Корзину", role: .destructive) { apps.uninstall(app) }
        } message: {
            Text(apps.runningApp(app) != nil
                 ? "Приложение сейчас запущено — сначала завершите его."
                 : "Отменить можно в разделе «История», пока Корзина не очищена.")
        }
    }

    private func stat(_ title: String, _ value: Int64, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(ByteFormat.string(value))
                .font(.title3.weight(accent ? .bold : .semibold))
                .monospacedDigit()
                .foregroundStyle(accent ? Color.accentColor : .primary)
        }
    }
}

private struct AppFileRow: View {
    @Environment(AppModel.self) private var model
    let file: AppFile

    var body: some View {
        let apps = model.apps
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { apps.checked.contains(file.path) },
                set: { on in if on { apps.checked.insert(file.path) } else { apps.checked.remove(file.path) } }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.kind.title).font(.callout.weight(.medium))
                Text(model.displayPath(file.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(ByteFormat.string(file.size)).monospacedDigit()
            RowActions(path: file.path, showMap: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.reveal([file.path]) }
        .contextMenu { FileContextMenu(path: file.path) }
    }
}
