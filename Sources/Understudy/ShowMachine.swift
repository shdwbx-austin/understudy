import AppKit
import Foundation
import ServiceManagement

/// Running Understudy unattended on a dedicated Mac.
///
/// - Keeps the app out of App Nap always (its timing loop must not be throttled when the window
///   is hidden or the display sleeps) and, when asked, stops the Mac idle-sleeping.
/// - Registers a launch agent bundled in the app (Contents/Library/LaunchAgents) that starts
///   Understudy at login and relaunches it if it ever exits unexpectedly. A normal Quit exits
///   cleanly and is not relaunched.
@MainActor
final class ShowMachine: ObservableObject {
    static let agentPlist = "com.shdwbx.understudy.agent.plist"

    @Published private(set) var agentStatus: SMAppService.Status = .notRegistered
    @Published private(set) var agentError: String?
    @Published private(set) var keepingAwake = false

    private var activity: NSObjectProtocol?

    init() { refresh() }

    private var agent: SMAppService { .agent(plistName: Self.agentPlist) }

    /// Only a bundled app can register its agent (not `swift run`).
    var canManageAgent: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    // MARK: Awake

    func keepAwake(_ on: Bool) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        let base: ProcessInfo.ActivityOptions = [.latencyCritical]
        activity = ProcessInfo.processInfo.beginActivity(
            options: base.union(on ? .userInitiated : .userInitiatedAllowingIdleSystemSleep),
            reason: on ? "Understudy is running a rehearsal (keeping the Mac awake)" : "Understudy is chasing timecode"
        )
        keepingAwake = on
    }

    // MARK: Login agent

    func refresh() {
        agentStatus = canManageAgent ? agent.status : .notFound
    }

    var runsAtLogin: Bool { agentStatus == .enabled || agentStatus == .requiresApproval }

    func setRunAtLogin(_ on: Bool) {
        agentError = nil
        do {
            if on { try agent.register() } else { try agent.unregister() }
        } catch {
            agentError = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    var agentStatusText: String {
        switch agentStatus {
        case .enabled:
            return Self.launchedByAgent
                ? "On. This copy was started by the login agent and is relaunched if it quits unexpectedly."
                : "On from the next login. This copy was opened by hand, so it isn't watched; log out and in (or restart) to run under the agent."
        case .requiresApproval: return "Waiting for approval in System Settings › General › Login Items."
        case .notRegistered: return "Off."
        case .notFound: return canManageAgent ? "Not available in this build." : "Available in the installed app, not when run from source."
        @unknown default: return "Unknown."
        }
    }

    /// Started by the login agent (launchd names the job in the environment).
    static var launchedByAgent: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.shdwbx.understudy.agent"
    }

    // MARK: Single instance

    /// If another copy is already running (e.g. the login agent started it), bring that one forward
    /// and report true so this one can quit cleanly — two copies would fight over the decks.
    static func handOffToRunningCopy() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let other = others.first else { return false }
        other.activate()
        return true
    }
}
