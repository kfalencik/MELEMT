import Foundation
import Observation
import Sparkle

/// Owns Sparkle's updater. Sparkle reads the feed (SUFeedURL) and signing key (SUPublicEDKey) from
/// Info.plist, checks for new versions in the background, and shows its own update window.
@Observable
final class AppUpdater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// False while a check is already running, so the menu item can be disabled.
    private(set) var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            Task { @MainActor [weak self] in self?.canCheckForUpdates = canCheck }
        }
    }

    /// Whether Sparkle checks for updates on its own (shown in Settings).
    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
