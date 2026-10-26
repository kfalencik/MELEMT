import SwiftUI
import UniformTypeIdentifiers

/// App settings: game folder, Nexus Mods account, and install behavior.
struct SettingsView: View {
    @Environment(ModLibrary.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppUpdater.self) private var updater
    @AppStorage(DownloadManager.autoInstallKey) private var autoInstall = true
    @AppStorage(DownloadManager.watchDownloadsKey) private var watchDownloads = true
    @AppStorage(GameLauncher.preferredMethodKey) private var launchMethod = ""
    @AppStorage(GameLauncher.skipLauncherKey) private var skipLauncher = true
    @AppStorage(GameLauncher.hideOtherAppsKey) private var hideOtherApps = true
    @State private var isChoosingGameFolder = false
    @State private var isConnectingNexus = false
    @State private var handlesNexusLinks = NXMHandler.isDefault

    var body: some View {
        Form {
            Section("Game") {
                LabeledContent("Legendary Edition folder") {
                    Text(library.install?.root.path ?? "Not found")
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Change…") { isChoosingGameFolder = true }
                    if let install = library.install {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([install.root]) }
                    }
                }
            }

            Section("Nexus Mods") {
                if let user = downloads.nexusUser {
                    LabeledContent("Signed in as") {
                        Text("\(user.name)\(user.isPremium ? " (Premium)" : "")")
                    }
                    Button("Sign Out", role: .destructive) { downloads.disconnectNexus() }
                } else {
                    LabeledContent("Account") { Text("Not connected").foregroundStyle(.secondary) }
                    Button("Connect Nexus Mods…") { isConnectingNexus = true }
                }
                LabeledContent("\"Mod Manager Download\" links") {
                    if handlesNexusLinks {
                        Label("Open in this app", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open in This App") {
                            Task {
                                await NXMHandler.makeDefault()
                                handlesNexusLinks = NXMHandler.isDefault
                            }
                        }
                    }
                }
            }

            Section("Playing") {
                let methods = GameLauncher.availableMethods()
                if methods.isEmpty {
                    LabeledContent("Start games with") {
                        Text("Steam not found").foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Start games with", selection: $launchMethod) {
                        Text("Automatic (\(methods[0].displayName))").tag("")
                        ForEach(methods, id: \.self) { method in
                            Text(method.displayName).tag(method.storageValue)
                        }
                    }
                }
                Toggle("Skip the Legendary Edition launcher", isOn: $skipLauncher)
                    .help("On: Play boots straight into the chosen game. Off: the Legendary Edition launcher opens and you pick the game there.")
                Toggle("Hide Steam, the EA app and MELEMT when a game starts", isOn: $hideOtherApps)
                    .help("Only the game stays on screen. Click MELEMT in the Dock to bring it back.")
            }

            Section {
                Toggle("Install mods automatically after downloading", isOn: $autoInstall)
                Toggle("Pick up mods saved to the Downloads folder", isOn: $watchDownloads)
                    .onChange(of: watchDownloads) { _, watch in
                        if watch { downloads.startWatchingDownloadsFolder() } else { downloads.stopWatchingDownloadsFolder() }
                    }
            } header: {
                Text("Installing")
            } footer: {
                Text("Mods always go into the game their moddesc.ini names. Anything with warnings, missing requirements or several options waits for you in Downloads.")
            }

            Section("Updates") {
                @Bindable var updater = updater
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isChoosingGameFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await library.selectGameFolder(url) }
            }
        }
        .sheet(isPresented: $isConnectingNexus) {
            NexusConnectView()
        }
        .onAppear { handlesNexusLinks = NXMHandler.isDefault }
        .preferredColorScheme(.dark)
    }
}
