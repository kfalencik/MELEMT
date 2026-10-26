import SwiftUI
import UniformTypeIdentifiers

/// What's shown in the detail area.
enum SidebarItem: Hashable {
    case launch
    case game(LEGame)
    case downloads
    case settings
}

struct ContentView: View {
    @Environment(ModLibrary.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @State private var selection: SidebarItem? = .launch
    @State private var isAddingMods = false
    @State private var isChoosingGameFolder = false
    @State private var isDropTargeted = false
    @State private var isConnectingNexus = false

    var body: some View {
        @Bindable var library = library

        Group {
            if library.install == nil {
                SetupView(isChoosingGameFolder: $isChoosingGameFolder)
            } else {
                NavigationSplitView {
                    Sidebar(selection: $selection, isConnectingNexus: $isConnectingNexus)
                        .navigationSplitViewColumnWidth(230)
                } detail: {
                    switch selection {
                    case .launch:
                        LaunchView(selection: $selection)
                    case .game(let game):
                        GameView(game: game, isAddingMods: $isAddingMods, isChoosingGameFolder: $isChoosingGameFolder)
                    case .downloads:
                        DownloadsView(isAddingMods: $isAddingMods, isConnectingNexus: $isConnectingNexus)
                    case .settings:
                        SettingsView()
                            .frame(maxWidth: 680)
                            .frame(maxWidth: .infinity)
                            .navigationTitle("Settings")
                    case nil:
                        ContentUnavailableView("Choose a Game", systemImage: "gamecontroller")
                    }
                }
            }
        }
        .overlay {
            if isDropTargeted {
                DropOverlay()
            }
        }
        .overlay(alignment: .bottom) {
            if let activity = library.activity {
                ActivityToast(text: activity)
            }
        }
        .animation(.snappy, value: isDropTargeted)
        .animation(.snappy, value: library.activity)
        .dropDestination(for: URL.self) { urls, _ in
            guard library.install != nil, !urls.isEmpty else { return false }
            urls.forEach { downloads.add(fileURL: $0) }
            selection = .downloads
            return true
        } isTargeted: { isDropTargeted = $0 && library.install != nil }
        .fileImporter(isPresented: $isAddingMods, allowedContentTypes: Self.modContentTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            urls.forEach { downloads.add(fileURL: $0) }
            selection = .downloads
        }
        .fileImporter(isPresented: $isChoosingGameFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await library.selectGameFolder(url) }
            }
        }
        // Deliver "Mod Manager Download" links to this window instead of opening another one.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onOpenURL { url in
            // "Mod Manager Download" on nexusmods.com opens an nxm:// link in this app.
            downloads.handle(nxmURL: url)
            selection = .downloads
        }
        .sheet(isPresented: $isConnectingNexus) {
            NexusConnectView()
        }
        .sheet(item: Bindable(downloads).rebuild) { progress in
            RebuildProgressView(progress: progress) { downloads.rebuild = nil }
        }
        .sheet(item: Bindable(downloads).optionsRequest) { request in
            InstallOptionsView(request: request)
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })
        ) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
        .task {
            await library.locateGameIfNeeded()
            downloads.cleanUpUnpackFolder()
            await downloads.refreshNexusAccount()
            downloads.resumePendingDownloads()
            if downloads.hasAPIKey, !NXMHandler.isDefault {
                // Another copy (or Vortex/M3) is set to open Nexus links; claim them for this copy.
                await NXMHandler.makeDefault()
            }
            downloads.startWatchingDownloadsFolder()
            await downloads.checkForUpdates()
        }
    }

    static let modContentTypes: [UTType] = [.zip, .folder] + ["7z", "rar"].compactMap { UTType(filenameExtension: $0) }
}

// MARK: Sidebar

private struct Sidebar: View {
    @Environment(ModLibrary.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Binding var selection: SidebarItem?
    @Binding var isConnectingNexus: Bool

    var body: some View {
        List(selection: $selection) {
            Label("Launch", systemImage: "play.circle.fill")
                .tag(SidebarItem.launch)
            Section("Games") {
                ForEach(LEGame.allCases) { game in
                    GameSidebarRow(game: game)
                        .tag(SidebarItem.game(game))
                }
            }
            Section("Mods") {
                Label("Downloads", systemImage: "arrow.down.circle")
                    .badge(downloads.downloadCount)
                    .tag(SidebarItem.downloads)
            }
            Section("MELEMT") {
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
            }
        }
        .safeAreaInset(edge: .top) {
            HStack(alignment: .center, spacing: 10) {
                RelayEmblem(size: 44)
                MELEMTWordmark()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .safeAreaInset(edge: .bottom) {
            NexusStatus(isConnectingNexus: $isConnectingNexus)
                .padding(12)
        }
    }
}

private struct GameSidebarRow: View {
    @Environment(ModLibrary.self) private var library
    @Environment(DownloadManager.self) private var downloads
    let game: LEGame

    private var subtitle: String {
        guard library.isInstalled(game) else { return "Not installed" }
        let count = library.modCount(for: game) + downloads.gameFileMods(for: game).count
        return count == 1 ? "1 mod" : "\(count) mods"
    }

    private var hasIssues: Bool {
        library.isInstalled(game) && !(library.health[game]?.issues(for: game).isEmpty ?? true)
    }

    var body: some View {
        Label {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(game.displayName)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                let work = downloads.workCount(for: game)
                if work > 0 {
                    Text("\(work)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MEStyle.omniOrange, in: .capsule)
                        .help("Mods being installed or waiting for you on this game's page.")
                }
                if hasIssues {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("This game needs attention before mods will load.")
                }
            }
        } icon: {
            Image(systemName: game.symbolName)
        }
        .opacity(library.isInstalled(game) ? 1 : 0.5)
    }
}

/// Bottom-of-sidebar Nexus Mods account status.
private struct NexusStatus: View {
    @Environment(DownloadManager.self) private var downloads
    @Binding var isConnectingNexus: Bool

    var body: some View {
        if let user = downloads.nexusUser {
            Label {
                VStack(alignment: .leading, spacing: 0) {
                    Text(user.name).lineLimit(1)
                    Text(user.isPremium ? "Nexus Mods Premium" : "Nexus Mods")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(.green)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Button {
                isConnectingNexus = true
            } label: {
                Label("Connect Nexus Mods", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .help("Connect once so \"Mod Manager Download\" buttons on Nexus Mods download straight into this app.")
        }
    }
}

// MARK: Overlays

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background.opacity(0.6))
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 54, weight: .light))
                Text("Drop to Install")
                    .font(.title.bold())
                Text("Mod archives (.7z, .zip, .rar) or folders")
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            .glassEffect(in: .rect(cornerRadius: 28))
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

private struct ActivityToast: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .glassEffect()
        .padding(.bottom, 18)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: First run

/// Shown until the Legendary Edition folder is found.
private struct SetupView: View {
    @Environment(ModLibrary.self) private var library
    @Binding var isChoosingGameFolder: Bool

    var body: some View {
        VStack(spacing: 18) {
            RelayEmblem(size: 150)
            MELEMTWordmark(size: 40)
            N7Stripe()
            if library.isLocating {
                ProgressView("Looking for your game…")
            } else {
                Text("Couldn't find the game automatically. Choose your **Mass Effect Legendary Edition** folder (the one that contains the **Game** folder). It can be on an external drive or inside a CrossOver bottle.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
                HStack {
                    Button("Choose Game Folder…") { isChoosingGameFolder = true }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    Button("Search Again") {
                        Task { await library.locateGameIfNeeded() }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { SpaceBackdrop() }
    }
}
