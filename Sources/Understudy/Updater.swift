import Foundation
import Sparkle

/// Updates from GitHub Releases through Sparkle: checks once a day and from the menu, downloads
/// the new version, and installs it on relaunch. Each release carries an `appcast.xml` (signed
/// with the project's update key) that the feed URL in Info.plist points at.
///
/// Builds without an update key (local builds) can't verify an update, so updating is off there.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// "Up to date", "Version 0.3.0 is ready", … for the start window.
    @Published private(set) var status: String
    @Published private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController?

    /// Whether this build carries a public update key (set by CI from the signing setup).
    static var isConfigured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !key.isEmpty && !key.hasPrefix("__")
    }

    override init() {
        status = Self.isConfigured ? "Checks for updates daily" : "Updates off in this build"
        super.init()
        guard Self.isConfigured, Bundle.main.bundleURL.pathExtension == "app" else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        canCheck = true
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let v = item.displayVersionString
        Task { @MainActor in self.status = "Version \(v) is available" }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.status = "Up to date" }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let text = (error as NSError).localizedDescription
        Task { @MainActor in self.status = "Update check failed: \(text)" }
    }
}
