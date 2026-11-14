import AppKit
import SwiftUI

@main
struct UnderstudyApp: App {
    @StateObject private var model = AppModel()

    init() {
        // One copy only: a second (e.g. the login agent firing while one is open) hands over and
        // quits cleanly, which the agent doesn't treat as a crash.
        if ShowMachine.handOffToRunningCopy() { exit(0) }
    }

    var body: some Scene {
        Window("understudy", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    // Needed when launched via `swift run` (no bundle).
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .commands {
            CommandMenu("Mode") {
                // Toggles show a tick on the current mode; leaving Record asks first.
                Toggle("Stop", isOn: modeBinding(.stop)).keyboardShortcut("1", modifiers: .command)
                Toggle("Record", isOn: modeBinding(.record)).keyboardShortcut("2", modifiers: .command)
                Toggle("Play to code", isOn: modeBinding(.playback)).keyboardShortcut("3", modifiers: .command)
                Divider()
                Button("Refresh Takes") { model.refreshTakes() }.keyboardShortcut("r", modifiers: .command)
                Button("Back Up a Take…") {
                    NotificationCenter.default.post(name: .understudyOpenBackup, object: nil)
                }.keyboardShortcut("b", modifiers: .command)
                Button("Assign Decks…") {
                    NotificationCenter.default.post(name: .understudyOpenAssign, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.setupLocked)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }

    private func modeBinding(_ mode: AppModel.Mode) -> Binding<Bool> {
        Binding(get: { model.mode == mode }, set: { _ in model.requestMode(mode) })
    }
}
