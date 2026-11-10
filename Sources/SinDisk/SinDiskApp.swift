import SwiftUI
import AppKit
import SinDiskCore

@main
struct SinDiskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        WindowGroup("SinDisk", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Сканировать домашнюю папку") { model.startScan(path: NSHomeDirectory()) }
                    .keyboardShortcut("r")
                Button("Сканировать весь диск") { model.startScan(path: "/") }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Сканировать папку…") { model.chooseFolderAndScan() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Перейти") {
                ForEach(Array(AppModel.Section.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { model.section = section }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
                Divider()
                Button("Поиск") { model.section = .search }
                    .keyboardShortcut("f")
                Button("На уровень вверх") { model.goUp() }
                    .keyboardShortcut(.upArrow)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent()
                .environment(model)
        } label: {
            Label(model.menuBarTitle, systemImage: "internaldrive")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let v = model.volume {
            Text("Свободно \(ByteFormat.string(v.availableImportant)) из \(ByteFormat.string(v.total))")
        }
        Button("Открыть SinDisk") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Сканировать домашнюю папку") {
            model.startScan(path: NSHomeDirectory())
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Рекомендации по очистке") {
            model.section = .recommendations
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Обновить") { model.refreshAccess() }
        Button("Выйти") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @AppStorage("largeFileMB") private var largeFileMB = 500
    @AppStorage("oldFileDays") private var oldFileDays = 365
    @AppStorage("downloadsDays") private var downloadsDays = 90
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some View {
        Form {
            Section("Пороги анализа") {
                Stepper("Большие файлы: от \(largeFileMB) МБ", value: $largeFileMB, in: 50...10_000, step: 50)
                Stepper("Давно не открывались: \(oldFileDays) дн.", value: $oldFileDays, in: 30...3650, step: 30)
                Stepper("Старые загрузки: \(downloadsDays) дн.", value: $downloadsDays, in: 7...730, step: 7)
                Text("Изменения применяются при следующем анализе.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Интерфейс") {
                Toggle("Показывать в строке меню", isOn: $showMenuBar)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding()
    }
}
