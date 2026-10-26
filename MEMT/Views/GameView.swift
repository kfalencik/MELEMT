import SwiftUI
import UniformTypeIdentifiers

/// Everything for one game: its status, installed mods (with on/off, updates and uninstall), and
/// downloaded mods for it that aren't installed yet.
struct GameView: View {
    @Environment(ModLibrary.self) private var library
    @Environment(DownloadManager.self) private var downloads
    let game: LEGame
    @Binding var isAddingMods: Bool
    @Binding var isChoosingGameFolder: Bool

    @State private var modsPendingUninstall: [InstalledMod] = []
    @State private var filesPendingRestore: [String]?
    @State private var isConfirmingRemoveAll = false
    @State private var isConfirmingRepair = false
    @State private var isShowingGameSettings = false
    @State private var isConfirmingRestoreBackup = false
    @State private var isChoosingBackupDestination = false
    @State private var isChoosingExistingBackup = false

    private var mods: [InstalledMod] { library.mods[game] ?? [] }

    /// Installed folders grouped by mod (folders installed together share their _metacmm name).
    private var modGroups: [[InstalledMod]] {
        var order: [String] = []
        var groups: [String: [InstalledMod]] = [:]
        for mod in mods {
            let key = mod.meta?.modName.lowercased() ?? "folder:" + mod.dlcName.lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(mod)
        }
        return order.compactMap { groups[$0] }
    }
    private var gameFileMods: [DownloadItem] { downloads.gameFileMods(for: game) }
    private var issues: [HealthIssue] { library.health[game]?.issues(for: game) ?? [] }
    private var notInstalled: [DownloadItem] {
        downloads.items(for: game).filter { !downloads.isInstalled($0) && !$0.isActive && !$0.isGameStageWork && !$0.isDownloadStage }
    }
    /// Downloaded mods for this game being unpacked or installed, or waiting for a decision.
    private var inProgress: [DownloadItem] {
        downloads.items.filter { $0.game == game && $0.isGameStageWork }
    }

    var body: some View {
        Group {
            if !library.isInstalled(game) {
                notInstalledView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        GameBanner(game: game, subtitle: statusText, statusColor: issues.isEmpty ? .green : .orange) {
                            HStack {
                                Link(destination: NexusClient.legendaryEditionModsURL) {
                                    Label("Get Mods", systemImage: "safari")
                                }
                                .buttonStyle(.glass)
                                .tint(.white.opacity(0.12))
                                Button("Add Mod", systemImage: "plus") { isAddingMods = true }
                                    .buttonStyle(.glass)
                                    .tint(.white.opacity(0.12))
                                Button("Game Settings", systemImage: "slider.horizontal.3") { isShowingGameSettings = true }
                                    .buttonStyle(.glass)
                                    .tint(.white.opacity(0.12))
                                Button {
                                    Task { await library.launch(game, resume: false) }
                                } label: {
                                    Label("Play", systemImage: "play.fill")
                                        .fontWidth(.expanded)
                                        .textCase(.uppercase)
                                }
                                .buttonStyle(.glassProminent)
                                .tint(MEStyle.tint(for: game))
                                .disabled(library.activity != nil)
                            }
                            .controlSize(.large)
                        }

                        VStack(alignment: .leading, spacing: 22) {
                            if !issues.isEmpty {
                                SetupCard(game: game, issues: issues)
                            }
                            if !inProgress.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    SectionHeader(title: "Installing", tint: MEStyle.omniOrange)
                                    ForEach(inProgress) { DownloadCard(item: $0) }
                                }
                            }
                            installedSection
                            if !notInstalled.isEmpty {
                                librarySection
                            }
                            MaintenanceCard(
                                game: game,
                                backUp: { isChoosingBackupDestination = true },
                                restore: { isConfirmingRestoreBackup = true },
                                findBackup: { isChoosingExistingBackup = true },
                                removeAll: { isConfirmingRemoveAll = true },
                                rebuild: { isConfirmingRepair = true }
                            )
                        }
                        .padding(24)
                    }
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .navigationTitle(game.displayName)
        .toolbar {
            ToolbarItem {
                Menu("Game Options", systemImage: "ellipsis.circle") {
                    Button("Check for Updates", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await downloads.checkForUpdates() }
                    }
                    .disabled(!downloads.hasAPIKey)
                    Button("Show Game Folder in Finder", systemImage: "folder") {
                        if let install = library.install {
                            NSWorkspace.shared.activateFileViewerSelecting([install.gameDirectory(game)])
                        }
                    }
                    Divider()
                    Button("Restore Original Game Files…", systemImage: "arrow.uturn.backward") {
                        Task {
                            let files = await library.backedUpFiles(for: game)
                            if files.isEmpty {
                                library.errorMessage = "This app hasn't changed any of \(game.displayName)'s own files, so there's nothing to restore."
                            } else {
                                filesPendingRestore = files
                            }
                        }
                    }
                    Button("Rebuild Mods…", systemImage: "wrench.and.screwdriver") { isConfirmingRepair = true }
                    Divider()
                    Button("Back Up Game…", systemImage: "externaldrive.badge.timemachine") { isChoosingBackupDestination = true }
                    Button("Restore From Backup…", systemImage: "clock.arrow.circlepath") { isConfirmingRestoreBackup = true }
                        .disabled(library.gameBackup(for: game) == nil)
                    Button("Remove All Mods…", systemImage: "trash", role: .destructive) { isConfirmingRemoveAll = true }
                    Divider()
                    Button("Change Game Folder…", systemImage: "externaldrive") { isChoosingGameFolder = true }
                }
                .disabled(library.activity != nil)
            }
        }
        .confirmationDialog(
            uninstallTitle,
            isPresented: Binding(get: { !modsPendingUninstall.isEmpty }, set: { if !$0 { modsPendingUninstall = [] } })
        ) {
            Button("Uninstall", role: .destructive) {
                let targets = modsPendingUninstall
                Task { await library.uninstall(targets, game: game) }
            }
        } message: {
            Text("The mod is moved to the Trash, and stays in your library so you can reinstall it. Changes it made to the game's own files stay until you restore the original game files.")
        }
        .sheet(isPresented: $isShowingGameSettings) {
            GameSettingsView(game: game)
        }
        .confirmationDialog("Rebuild \(game.displayName) Mods?", isPresented: $isConfirmingRepair) {
            Button("Rebuild Mods") {
                Task { await downloads.rebuildMods(for: game) }
            }
        } message: {
            Text("Puts the game's own files back to original, then reinstalls your mods one by one in load order with the options you chose, so every merge is redone cleanly. Use this if a mod's menus or text look wrong.")
        }
        .confirmationDialog(
            "Restore Original Game Files?",
            isPresented: Binding(get: { filesPendingRestore != nil }, set: { if !$0 { filesPendingRestore = nil } })
        ) {
            Button("Restore \(filesPendingRestore?.count ?? 0) Files", role: .destructive) {
                Task {
                    await library.restoreOriginalFiles(for: game)
                    downloads.forgetGameFileMods(for: game)
                }
            }
        } message: {
            Text("Puts back the game's own files as they were before this app first changed them. Mods that edit game files (merge mods, text merges) will need reinstalling. Custom DLC mods stay installed.")
        }
        .confirmationDialog("Remove All \(game.displayName) Mods?", isPresented: $isConfirmingRemoveAll) {
            Button("Remove All Mods", role: .destructive) {
                Task {
                    await library.removeAllMods(for: game)
                    downloads.forgetGameFileMods(for: game)
                }
            }
        } message: {
            Text("Every mod is moved to the Trash and the game's own files are put back as they were before this app changed them. Your downloaded mods stay in the library, so you can reinstall any of them.")
        }
        .confirmationDialog("Restore \(game.displayName) From Backup?", isPresented: $isConfirmingRestoreBackup) {
            Button("Restore", role: .destructive) {
                Task {
                    await library.restoreGame(game)
                    downloads.forgetGameFileMods(for: game)
                }
            }
        } message: {
            if let backup = library.gameBackup(for: game) {
                Text("Puts \(game.displayName) back exactly as it was on \(backup.created.formatted(date: .abbreviated, time: .shortened)). Anything installed since, including mods, is removed. Only changed files are copied, so this is usually quick.")
            }
        }
        .fileImporter(isPresented: $isChoosingBackupDestination, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result {
                Task { await library.backUpGame(game, to: folder) }
            }
        }
        .fileDialogMessage("Choose where to keep the backup of \(game.displayName), for example an external drive.")
        .fileImporter(isPresented: $isChoosingExistingBackup, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result {
                _ = library.useBackup(at: folder, for: game)
            }
        }
    }

    private var statusText: String {
        let count = modGroups.count + gameFileMods.count
        let installed = count == 0 ? "No mods installed" : count == 1 ? "1 mod installed" : "\(count) mods installed"
        return issues.isEmpty ? "Ready for mods · \(installed)" : "Needs attention · \(installed)"
    }

    // MARK: Sections

    @ViewBuilder
    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Installed", tint: MEStyle.tint(for: game))
            if mods.isEmpty && gameFileMods.isEmpty {
                EmptyDropZone(game: game, isAddingMods: $isAddingMods)
            } else {
                VStack(spacing: 0) {
                    ForEach(modGroups, id: \.first?.id) { group in
                        InstalledModRow(mods: group, game: game) { modsPendingUninstall = group }
                        if group.first?.id != modGroups.last?.first?.id || !gameFileMods.isEmpty { Divider().padding(.leading, 64) }
                    }
                    ForEach(gameFileMods) { item in
                        GameFileModRow(item: item, game: game)
                        if item.id != gameFileMods.last?.id { Divider().padding(.leading, 64) }
                    }
                }
                .background(MEStyle.panel, in: .rect(cornerRadius: 14))
            }
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "In Your Library", tint: .secondary)
            VStack(spacing: 0) {
                ForEach(notInstalled) { item in
                    LibraryItemRow(item: item)
                    if item.id != notInstalled.last?.id { Divider().padding(.leading, 64) }
                }
            }
            .background(MEStyle.panel, in: .rect(cornerRadius: 14))
        }
    }

    private var notInstalledView: some View {
        ContentUnavailableView {
            Label("\(game.displayName) Isn't Installed", systemImage: "questionmark.folder")
        } description: {
            Text("No \(game.folderName) folder was found in your Legendary Edition folder.")
        } actions: {
            Button("Choose Game Folder…") { isChoosingGameFolder = true }
        }
    }

    private var uninstallTitle: String {
        Set(modsPendingUninstall.map(\.displayName)).count == 1
            ? "Uninstall \(modsPendingUninstall[0].displayName)?"
            : "Uninstall \(modsPendingUninstall.count) mods?"
    }
}

// MARK: Rows

/// One installed mod. Mods that install several DLC folders (e.g. LE3 Community Patch) are one row;
/// switching, updating and uninstalling act on all their folders.
private struct InstalledModRow: View {
    @Environment(ModLibrary.self) private var library
    @Environment(DownloadManager.self) private var downloads
    let mods: [InstalledMod]
    let game: LEGame
    let uninstall: () -> Void

    private var mod: InstalledMod { mods[0] }
    private var isEnabled: Bool { mods.allSatisfy(\.isEnabled) }
    private var knownFix: ModService.KnownFix? {
        ModService.knownFixes.first { fix in
            fix.game == game && mods.contains { $0.dlcName.caseInsensitiveCompare(fix.folder) == .orderedSame && fix.versions.contains($0.meta?.version ?? "") }
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Toggle("Enabled", isOn: Binding(
                get: { isEnabled },
                set: { enabled in Task { await library.setEnabled(enabled, mods: mods, game: game) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(MEStyle.tint(for: game))
            .disabled(library.activity != nil)
            .help(isEnabled ? "Turn this mod off without uninstalling it" : "Turn this mod back on")

            VStack(alignment: .leading, spacing: 3) {
                Text(mod.displayName)
                    .font(.headline)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let fix = knownFix {
                    Label("Patched by MELEMT", systemImage: "bandage.fill")
                        .font(.caption)
                        .foregroundStyle(MEStyle.omniOrange)
                        .help(fix.reason)
                }
            }

            Spacer()

            if let update = mods.lazy.compactMap({ downloads.update(for: $0) }).first {
                Button {
                    Task { await downloads.downloadUpdate(update) }
                } label: {
                    Label("Update to \(update.latestVersion)", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.glassProminent)
                .tint(MEStyle.omniOrange)
                .help(downloads.nexusUser?.isPremium == true
                      ? "Downloads and installs the latest version."
                      : "Opens the mod's Files page. Click \"Mod Manager Download\" there and it installs here.")
            }

            Menu {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting(mods.map(\.folderURL))
                }
                Button("Change Options…", systemImage: "slider.horizontal.3") {
                    downloads.changeOptions(for: mod, game: game)
                }
                .disabled(downloads.libraryItem(for: mod, game: game) == nil || library.activity != nil)
                Button("Reinstall", systemImage: "arrow.clockwise") {
                    if let item = downloads.libraryItem(for: mod, game: game) { downloads.install(item) }
                }
                .disabled(downloads.libraryItem(for: mod, game: game) == nil || library.activity != nil)
                if let modID = mod.meta?.nexusUpdateCode, modID > 0 {
                    Button("Open on Nexus Mods", systemImage: "safari") {
                        NSWorkspace.shared.open(NexusClient.filesPageURL(modID: modID))
                    }
                }
                Divider()
                Button("Uninstall…", systemImage: "trash", role: .destructive, action: uninstall)
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .contextMenu {
            Button(isEnabled ? "Turn Off" : "Turn On") {
                Task { await library.setEnabled(!isEnabled, mods: mods, game: game) }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(mods.map(\.folderURL)) }
            Divider()
            Button("Uninstall…", role: .destructive, action: uninstall)
        }
    }

    private var details: String {
        var parts: [String] = []
        if !mod.version.isEmpty { parts.append("v\(mod.version)") }
        if !isEnabled { parts.append("Off") }
        if let date = mod.installTime { parts.append("Installed \(date.formatted(date: .abbreviated, time: .omitted))") }
        if !mod.hasModManagerMetadata { parts.append("Installed manually") }
        parts.append(mods.count == 1 ? mod.dlcName : "\(mods.count) folders")
        return parts.joined(separator: " · ")
    }
}

/// An installed mod that only changes the game's own files, so it has no folder to switch off.
private struct GameFileModRow: View {
    let item: DownloadItem
    let game: LEGame

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.title2)
                .foregroundStyle(MEStyle.tint(for: game))
                .frame(width: 38)
                .help("This mod changes the game's own files, so it can't be switched off on its own.")
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Changes game files")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(MEStyle.tint(for: game).opacity(0.2), in: .capsule)
                .foregroundStyle(MEStyle.tint(for: game))
                .help("To remove it, use Restore Original Game Files in the ••• menu.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var details: String {
        var parts: [String] = []
        if let subtitle = item.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        if let date = item.installedAt { parts.append("Installed \(date.formatted(date: .abbreviated, time: .omitted))") }
        return parts.joined(separator: " · ")
    }
}

/// Full game backup status and the bulk "start over" actions.
private struct MaintenanceCard: View {
    @Environment(ModLibrary.self) private var library
    let game: LEGame
    let backUp: () -> Void
    let restore: () -> Void
    let findBackup: () -> Void
    let removeAll: () -> Void
    let rebuild: () -> Void

    var body: some View {
        let backup = library.gameBackup(for: game)
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Maintenance", tint: .secondary)
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: backup == nil ? "externaldrive.badge.exclamationmark" : "externaldrive.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(backup == nil ? MEStyle.omniOrange : .green)
                    .frame(width: 38)
                VStack(alignment: .leading, spacing: 4) {
                    if let backup {
                        Text("Backed up \(backup.created.formatted(date: .abbreviated, time: .shortened))").font(.headline)
                        Text(backup.folder?.path ?? "")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Text(backup.modsInstalled == 0 ? "A clean backup with no mods." : "Includes \(backup.modsInstalled) mod folders that were installed at the time.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No full backup yet").font(.headline)
                        Text("A full backup lets you put \(game.displayName) back exactly as it is now, whatever happens. For a clean one, back up before installing mods.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("I already have a backup…", action: findBackup)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button(backup == nil ? "Back Up Game…" : "Back Up Again…", systemImage: "externaldrive.badge.timemachine", action: backUp)
                        .buttonStyle(.glass)
                    if backup != nil {
                        Button("Restore From Backup…", systemImage: "clock.arrow.circlepath", action: restore)
                            .buttonStyle(.glass)
                    }
                    Button("Rebuild Mods…", systemImage: "wrench.and.screwdriver", action: rebuild)
                        .buttonStyle(.glass)
                        .disabled(library.modCount(for: game) == 0)
                        .help("Puts the original game files back, then reinstalls every mod one by one in load order.")
                    Button("Remove All Mods…", systemImage: "trash", role: .destructive, action: removeAll)
                        .buttonStyle(.glass)
                        .disabled(library.modCount(for: game) == 0)
                }
                .disabled(library.activity != nil)
            }
            .padding(16)
            .background(MEStyle.panel, in: .rect(cornerRadius: 14))
        }
    }
}

/// A downloaded mod that isn't installed in its game.
struct LibraryItemRow: View {
    @Environment(DownloadManager.self) private var downloads
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 14) {
            ModThumbnail(url: item.imageURL, game: item.game)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                if case .failed(let message) = item.phase {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Button(item.installedAt == nil ? "Install" : "Reinstall") { downloads.install(item) }
                .buttonStyle(.glass)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: Pieces

struct SectionHeader: View {
    let title: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(tint).frame(width: 3, height: 14)
            Text(title).meLabel().foregroundStyle(.secondary)
        }
    }
}

struct ModThumbnail: View {
    let url: URL?
    let game: LEGame?
    var width: CGFloat = 64
    var height: CGFloat = 40

    var body: some View {
        let tint = game.map(MEStyle.tint(for:)) ?? .gray
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                LinearGradient(colors: [tint.opacity(0.5), tint.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(game.map(MEStyle.codename(for:)) ?? "MOD")
                    .font(.caption2.weight(.heavy))
                    .fontWidth(.expanded)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: 6))
    }
}

/// Shown only if automatic game setup failed, with a retry.
private struct SetupCard: View {
    @Environment(ModLibrary.self) private var library
    let game: LEGame
    let issues: [HealthIssue]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.title2)
                .foregroundStyle(MEStyle.omniOrange)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(game.displayName) isn't set up to load mods yet").font(.headline)
                ForEach(issues) { issue in
                    Text("• \(issue.title)").font(.callout).foregroundStyle(.secondary)
                }
                Text("The app sets this up automatically, but it didn't finish this time. It installs the same loader files ME3Tweaks Mod Manager uses (the bink bypass, AutoTOC\(game == .le1 ? " and AutoloadEnabler" : "")).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Try Again") {
                Task { await library.prepareGame(game) }
            }
            .buttonStyle(.glassProminent)
            .tint(MEStyle.omniOrange)
            .controlSize(.large)
            .disabled(library.activity != nil)
        }
        .padding(16)
        .background(MEStyle.omniOrange.opacity(0.12), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(MEStyle.omniOrange.opacity(0.35)))
    }
}

private struct EmptyDropZone: View {
    let game: LEGame
    @Binding var isAddingMods: Bool

    var body: some View {
        VStack(spacing: 10) {
            RelayEmblem(size: 80)
            Text("No mods yet").font(.title3.bold())
            Text("On Nexus Mods, click **Mod Manager Download** on a mod's Files page and it installs here automatically. You can also drag a mod archive onto this window.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            HStack {
                Link("Browse Nexus Mods", destination: NexusClient.legendaryEditionModsURL)
                    .buttonStyle(.glass)
                Button("Choose a File…") { isAddingMods = true }
                    .buttonStyle(.glass)
            }
            .padding(.top, 4)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(.secondary.opacity(0.5))
        )
    }
}
