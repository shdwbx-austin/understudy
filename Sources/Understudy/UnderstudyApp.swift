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
            CommandGroup(replacing: .undoRedo) {
                UndoCommands(timeline: model.timeline)
            }
            CommandGroup(replacing: .newItem) {
                ProjectCommands(model: model, projects: model.projects)
            }
            CommandMenu("Markers") {
                MarkerCommands(timeline: model.timeline)
            }
            CommandGroup(after: .appInfo) {
                UpdateCommand(updater: model.updater)
            }
            // View menu: the three screens. Program and View take the decks; leaving Record asks first.
            CommandGroup(before: .toolbar) {
                Toggle("Program", isOn: screenBinding(.program)).keyboardShortcut("1", modifiers: .command)
                Toggle("View", isOn: screenBinding(.view)).keyboardShortcut("2", modifiers: .command)
                Toggle("Record", isOn: screenBinding(.decks)).keyboardShortcut("3", modifiers: .command)
                Divider()
                ZoomCommands(timeline: model.timeline)
                Divider()
                OpenTimelineCommand()
                OpenVideoCommand()
                Divider()
            }
            CommandMenu("Record") {
                // What the decks do. Toggles show a tick on the current one; leaving Record asks first.
                Toggle("Stop", isOn: modeBinding(.stop)).keyboardShortcut(".", modifiers: [.command, .shift])
                Toggle("Record", isOn: modeBinding(.record)).keyboardShortcut("r", modifiers: [.command, .shift])
                Toggle("Play to Code", isOn: modeBinding(.playback)).keyboardShortcut("p", modifiers: [.command, .shift])
                Toggle("Follow Program", isOn: modeBinding(.timeline)).keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Record from Timeline (Dev)") { model.startTimelineRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Button("Refresh Takes") { model.refreshTakes() }.keyboardShortcut("r", modifiers: .command)
                Button("Back Up a Take…") {
                    NotificationCenter.default.post(name: .understudyOpenBackup, object: nil)
                }.keyboardShortcut("b", modifiers: .command)
                Button("Transcode a Take to NotchLC…") {
                    NotificationCenter.default.post(name: .understudyOpenNotchLC, object: nil)
                }
                Button("Assign Decks…") {
                    NotificationCenter.default.post(name: .understudyOpenAssign, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.setupLocked)
            }
        }

        Window("Video", id: "video") {
            VideoViewerView(viewer: model.viewer)
                .environmentObject(model)
        }
        .defaultSize(width: 1280, height: 520)

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

    private func screenBinding(_ screen: AppModel.Screen) -> Binding<Bool> {
        Binding(get: { model.screen == screen }, set: { _ in model.show(screen) })
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

private struct UpdateCommand: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheck)
    }
}

/// Opens (or brings forward) the Video window.
private struct OpenVideoCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Video in a Window") { openWindow(id: "video") }
            .keyboardShortcut("v", modifiers: [.command, .option])
    }
}

/// Markers menu: the type editor, and moving between markers.
private struct MarkerCommands: View {
    @ObservedObject var timeline: TimelineModel

    var body: some View {
        Button("Edit Marker Types…") { timeline.editingMarkerTypes = true }
            .keyboardShortcut("m", modifiers: [.command, .option])
        Button("Export Markers…") { timeline.exportingMarkers = true }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        Divider()
        Toggle("Name New Markers", isOn: $timeline.nameNewMarkers)
        Button("Name Selected Marker   ↩") { timeline.nameSelectedMarker() }
            .disabled(timeline.selectedMarkerID == nil)
        Divider()
        Button("Copy Selected Markers   ⌘C") { timeline.copyMarkers() }
        Button("Cut Selected Markers   ⌘X") { timeline.cutMarkers() }
        Button("Paste Markers at Playhead   ⌘V") { timeline.pasteMarkers() }
        Button("Select This Song's Markers   ⌘A") { timeline.selectSongMarkers() }
        Button("Delete Selected Markers   ⌫") { timeline.deleteSelectedMarkers() }
            .disabled(timeline.selectedMarkerID == nil && timeline.selectedMarkerIDs.isEmpty)
        Divider()
        Toggle("Snap to Grid", isOn: $timeline.snap)
        Button("Quantize Selected Markers   Q") { timeline.quantizeSelection() }
        Divider()
        // ] and [ in the timeline (MarkerKeys); not menu shortcuts, which would take the keys
        // from text fields too.
        Button("Next Marker   ]") { timeline.nextMarker() }
        Button("Previous Marker   [") { timeline.previousMarker() }
    }
}

/// View menu: zoom on the current song.
private struct ZoomCommands: View {
    @ObservedObject var timeline: TimelineModel

    var body: some View {
        Button("Zoom In") { timeline.setZoom(timeline.detailZoom * 2) }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(timeline.detailZoom >= TimelineModel.maxZoom)
        Button("Zoom Out") { timeline.setZoom(timeline.detailZoom / 2) }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(timeline.detailZoom <= 1)
        Button("Whole Song") { timeline.setZoom(1) }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(timeline.detailZoom <= 1)
    }
}

/// Edit › Undo / Redo: a text field being typed in keeps its own undo; otherwise they undo marker,
/// loop and tempo changes, by name ("Undo Paste Markers").
private struct UndoCommands: View {
    @ObservedObject var timeline: TimelineModel

    private var typing: Bool { NSApp.keyWindow?.firstResponder is NSText }

    var body: some View {
        Button(timeline.undoName.map { "Undo \($0)" } ?? "Undo") {
            if typing { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { timeline.undo() }
        }
        .keyboardShortcut("z", modifiers: .command)
        Button(timeline.redoName.map { "Redo \($0)" } ?? "Redo") {
            if typing { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { timeline.redo() }
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
    }
}
