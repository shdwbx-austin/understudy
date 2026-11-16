import AppKit
import SwiftUI
import UnderstudyCore

@main
struct UnderstudyApp: App {
    @StateObject private var model = AppModel()

    init() {
        // One copy only: a second (e.g. the login agent firing while one is open) hands over and
        // quits cleanly, which the agent doesn't treat as a crash.
        if ShowMachine.handOffToRunningCopy() { exit(0) }
    }

    var body: some Scene {
        // First scene: shown at launch. It hands straight over to the show when the last project
        // reopens by itself (a show machine, or a relaunch after a crash).
        Window("Understudy", id: "start") {
            StartView(projects: model.projects)
                .environmentObject(model)
                .modifier(LaunchHandOff(model: model))
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1000, height: 620)

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
            CommandGroup(replacing: .newItem) {
                ProjectCommands(model: model, projects: model.projects)
            }
            CommandMenu("Mode") {
                // Toggles show a tick on the current mode; leaving Record asks first.
                Toggle("Stop", isOn: modeBinding(.stop)).keyboardShortcut("1", modifiers: .command)
                Toggle("Record", isOn: modeBinding(.record)).keyboardShortcut("2", modifiers: .command)
                Toggle("Play to code", isOn: modeBinding(.playback)).keyboardShortcut("3", modifiers: .command)
                Toggle("Timeline", isOn: modeBinding(.timeline)).keyboardShortcut("4", modifiers: .command)
                Button("Record from Timeline (Dev)") { model.startTimelineRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                OpenTimelineCommand()
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

        Window("Timeline", id: "timeline") {
            TimelineView(timeline: model.timeline)
                .environmentObject(model)
        }
        .defaultSize(width: 1200, height: 760)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }

    private func modeBinding(_ mode: AppModel.Mode) -> Binding<Bool> {
        Binding(get: { model.mode == mode }, set: { _ in model.requestMode(mode) })
    }
}

/// Opens (or brings forward) the Timeline window.
private struct OpenTimelineCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Timeline") { openWindow(id: "timeline") }
            .keyboardShortcut("t", modifiers: .command)
    }
}

/// File menu: projects.
private struct ProjectCommands: View {
    @ObservedObject var model: AppModel
    @ObservedObject var projects: ProjectManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Project…") {
            let alert = NSAlert()
            alert.messageText = "New project"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.stringValue = "Untitled"
            let keep = NSButton(checkboxWithTitle: "Start from the open show (songs, set, markers)", target: nil, action: nil)
            keep.state = projects.current == nil ? .off : .on
            let stack = NSStackView(views: [field, keep])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.frame = NSRect(x: 0, y: 0, width: 320, height: 54)
            alert.accessoryView = stack
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            if model.newProject(named: field.stringValue, keepShow: keep.state == .on) { show() }
        }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(model.setupLocked)
        Button("Open Project…") {
            if let layout = projects.chooseProject(), model.openProject(layout) { show() }
        }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(model.setupLocked)
        Menu("Open Recent") {
            ForEach(projects.availableRecents) { recent in
                Button(recent.name) {
                    if let layout = ProjectLayout.project(at: URL(fileURLWithPath: recent.path)), model.openProject(layout) { show() }
                }
            }
        }
        .disabled(model.setupLocked || projects.availableRecents.isEmpty)
        Divider()
        Button("Show Project in Finder") {
            if let p = projects.current { NSWorkspace.shared.activateFileViewerSelecting([p.file]) }
        }
        .disabled(projects.current == nil)
        Button("Copy All Audio Into Project") { model.collectProjectFiles() }
            .disabled(projects.current == nil)
        Button("Close Project") {
            model.closeProject()
            openWindow(id: "start")
            DispatchQueue.main.async { WindowFinder.close(id: "main") }
        }
        .keyboardShortcut("w", modifiers: [.command, .shift])
        .disabled(projects.current == nil || model.setupLocked)
        Button("Start Window") { openWindow(id: "start") }
    }

    private func show() {
        openWindow(id: "main")
        DispatchQueue.main.async { WindowFinder.close(id: "start") }
    }
}

/// At launch: reopen the last project and go straight to the show when asked to (the setting, a
/// launch-agent relaunch, or resuming Record/Play after a restart).
private struct LaunchHandOff: ViewModifier {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var done = false

    func body(content: Content) -> some View {
        content.onAppear {
            guard !done else { return }
            done = true
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard model.projects.current == nil else { return }
            let auto = model.projects.reopenLastAtLaunch || ShowMachine.launchedByAgent || model.resumedMode != nil
            guard auto, let last = model.projects.availableRecents.first,
                  let layout = ProjectLayout.project(at: URL(fileURLWithPath: last.path)),
                  model.openProject(layout) else { return }
            openWindow(id: "main")
            DispatchQueue.main.async { WindowFinder.close(id: "start") }
        }
    }
}
