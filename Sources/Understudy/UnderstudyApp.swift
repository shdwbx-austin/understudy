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
        WindowGroup("understudy") {
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
                Button("Stop") { model.setMode(.stop) }.keyboardShortcut("1", modifiers: .command)
                Button("Record") { model.setMode(.record) }.keyboardShortcut("2", modifiers: .command)
                Button("Play to Code") { model.setMode(.playback) }.keyboardShortcut("3", modifiers: .command)
                Divider()
                Button("Refresh Takes") { model.refreshTakes() }.keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
