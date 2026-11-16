import AppKit
import SwiftUI
import UnderstudyCore

/// The start window: recent projects, Open…, New Project, and where projects live. Shown at launch
/// unless the last project reopens by itself (a show machine), and after Close Project.
struct StartView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var projects: ProjectManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            // Left: the name, version and where projects live.
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    Text("understudy").font(Theme.grotesk(64, .medium)).tracking(-1.5)
                    Text("Stands in for the cameras between run-throughs.")
                        .font(Theme.grotesk(17, .light)).foregroundStyle(Theme.grey)
                    Text(AppVersion.label).font(Theme.mono(11)).tracking(1.2).foregroundStyle(Theme.grey)
                        .padding(.top, 6)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    Text("PROJECTS FOLDER").font(Theme.mono(9)).tracking(1.2).foregroundStyle(Theme.grey)
                    HStack(spacing: 12) {
                        Text(abbreviated(projects.root.path)).font(Theme.grotesk(14)).lineLimit(1).truncationMode(.middle)
                        TextButton(title: "Change…") { projects.chooseRoot() }
                    }
                    Toggle("Open the last project at launch (show machine)", isOn: $projects.reopenLastAtLaunch)
                        .toggleStyle(.checkbox).font(Theme.grotesk(13))
                    HStack {
                        Spacer()
                        Text("shdwbx").font(Theme.grotesk(15, .medium)).tracking(-0.2)
                    }
                }
            }
            .padding(36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Theme.ink)

            Rectangle().fill(Theme.rule).frame(width: 1)

            // Right: recent projects and the two actions.
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent Projects").font(Theme.grotesk(22, .medium)).padding(24)
                Rule()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let legacy = model.legacyShow, projects.availableRecents.isEmpty {
                            LegacyCard(songs: legacy.songs.count, set: legacy.songs.filter(\.inSet).count) { name in
                                if model.newProject(named: name, keepShow: false, show: legacy) { enterShow() }
                            }
                        }
                        ForEach(projects.availableRecents) { recent in
                            RecentRow(recent: recent) { open(recent) }
                                .contextMenu {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: recent.path)]) }
                                    Button("Remove from Recents") { projects.forget(recent) }
                                }
                            Rule(color: Theme.rule.opacity(0.6))
                        }
                        if projects.availableRecents.isEmpty, model.legacyShow == nil {
                            Text("No projects yet. Start one with New Project.")
                                .font(Theme.grotesk(14, .light)).foregroundStyle(Theme.grey).padding(24)
                        }
                    }
                }
                if let error = projects.lastError {
                    Text(error).font(Theme.mono(10)).foregroundStyle(Theme.amber).padding(.horizontal, 24).padding(.bottom, 8)
                }
                Rule()
                HStack(spacing: 14) {
                    StartButton(title: "Open…") {
                        if let layout = projects.chooseProject(), model.openProject(layout) { enterShow() }
                    }
                    StartButton(title: "+  New Project", primary: true) {
                        if let name = promptForText("New project", value: "Untitled"), !name.isEmpty,
                           model.newProject(named: name, keepShow: false) { enterShow() }
                    }
                }
                .padding(20)
            }
            .frame(width: 420)
            .background(Theme.fill.opacity(0.5))
        }
        .frame(minWidth: 860, minHeight: 540)
        .background(Theme.ink)
        .foregroundStyle(Theme.paper)
        .preferredColorScheme(.dark)
    }

    private func open(_ recent: ProjectManager.Recent) {
        guard let layout = ProjectLayout.project(at: URL(fileURLWithPath: recent.path)) else {
            projects.lastError = "\(recent.name) isn't there any more."
            return
        }
        if model.openProject(layout) { enterShow() }
    }

    /// Show the main window and put this one away.
    private func enterShow() {
        openWindow(id: "main")
        DispatchQueue.main.async { WindowFinder.close(id: "start") }
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

private struct RecentRow: View {
    let recent: ProjectManager.Recent
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recent.name).font(Theme.grotesk(17, .medium)).lineLimit(1)
                    Text(folderText).font(Theme.grotesk(12, .light)).foregroundStyle(Theme.grey).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Text(recent.opened, format: .relative(presentation: .named)).font(Theme.mono(10)).foregroundStyle(Theme.grey)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(hover ? Theme.fill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var folderText: String {
        let folder = URL(fileURLWithPath: recent.path).deletingLastPathComponent().deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
    }
}

/// The show kept before projects existed, offered as the first project.
private struct LegacyCard: View {
    let songs: Int
    let set: Int
    let create: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YOUR CURRENT SHOW").font(Theme.mono(9)).tracking(1.2).foregroundStyle(Theme.lock)
            Text("\(songs) songs, \(set) on the set, from before projects.").font(Theme.grotesk(14))
            TextButton(title: "Make it a project…") {
                if let name = promptForText("Name the project", value: "My Show"), !name.isEmpty { create(name) }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.lock.opacity(0.08))
    }
}

private struct StartButton: View {
    let title: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.grotesk(16, .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .foregroundStyle(primary ? Theme.ink : Theme.paper)
                .background(primary ? Theme.paper : Color.clear)
                .overlay(Rectangle().strokeBorder(Theme.paper, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

enum AppVersion {
    static var label: String {
        let info = Bundle.main.infoDictionary
        guard let v = info?["CFBundleShortVersionString"] as? String else { return "DEV BUILD" }
        let b = info?["CFBundleVersion"] as? String
        return "V\(v)" + (b.map { " · BUILD \($0)" } ?? "")
    }
}

/// SwiftUI windows by scene id, for closing one from another (macOS 13 has no dismissWindow).
@MainActor
enum WindowFinder {
    static func window(id: String) -> NSWindow? {
        NSApp.windows.first { ($0.identifier?.rawValue ?? "").hasPrefix(id) }
    }

    static func close(id: String) { window(id: id)?.close() }
}
