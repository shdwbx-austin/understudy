import AppKit
import SwiftUI

@main
struct Cam4ProgApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("cam4prog") {
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
                Button("Play from Timecode") { model.setMode(.playback) }.keyboardShortcut("3", modifiers: .command)
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
