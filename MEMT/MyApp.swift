import SwiftUI

@main struct MyApp: App {
    @State private var library: ModLibrary
    @State private var downloads: DownloadManager
    @State private var updater = AppUpdater()
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        let library = ModLibrary()
        _library = State(initialValue: library)
        _downloads = State(initialValue: DownloadManager(library: library))
    }

    var body: some Scene {
        Window("MELEMT", id: "main") {
            ContentView()
                .environment(library)
                .environment(downloads)
                // Fixed size that fits every Mac with a 1440×900 or larger display.
                .frame(width: 1100, height: 740)
                .preferredColorScheme(.dark)
                .tint(MEStyle.n7Red)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        Settings {
            SettingsView()
                .environment(library)
                .environment(downloads)
                .environment(updater)
        }
    }
}

/// Keeps MELEMT to one running copy. macOS can start a second copy for a "Mod Manager Download"
/// link (for example when the app was rebuilt or exists in more than one place); that copy hands
/// the link to the one already running and quits, so the download joins the existing list.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runningCopy: NSRunningApplication?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let me = NSRunningApplication.current
        guard let bundleID = Bundle.main.bundleIdentifier,
              let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { $0.processIdentifier != me.processIdentifier && !$0.isTerminated })
        else { return }
        runningCopy = other
        NSApp.setActivationPolicy(.prohibited)
        // Take over link events before SwiftUI does, so this copy never opens a window for them.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let other = runningCopy else { return }
        // Opened without a link (e.g. from the Dock): just bring the running copy forward.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            other.activate()
            NSApp.terminate(nil)
        }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let other = runningCopy, let appURL = other.bundleURL else { return }
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
