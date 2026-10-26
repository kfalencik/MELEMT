import Foundation
import Observation

/// App state: the selected game install, the installed mods for each game, and install/uninstall.
/// Downloading and unpacking mods is handled by `DownloadManager`.
@Observable
final class ModLibrary {
    private static let gamePathKey = "gameInstallPath"

    private(set) var install: GameInstall?
    private(set) var mods: [LEGame: [InstalledMod]] = [:]
    private(set) var health: [LEGame: GameHealth] = [:]
    private(set) var isLocating = false

    /// Status text while extracting or installing; non-nil means busy.
    private(set) var activity: String?
    var errorMessage: String?

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.gamePathKey) {
            install = GameInstall.validated(from: URL(filePath: path))
        }
    }

    // MARK: Game location

    func locateGameIfNeeded() async {
        guard install == nil else {
            await refresh()
            return
        }
        isLocating = true
        defer { isLocating = false }
        if let found = await GameLocator.locate() {
            await setInstall(found)
        }
    }

    /// Returns false if `url` isn't a Legendary Edition folder.
    @discardableResult
    func selectGameFolder(_ url: URL) async -> Bool {
        guard let install = GameInstall.validated(from: url) else {
            errorMessage = "\(url.lastPathComponent) doesn't look like a Mass Effect Legendary Edition folder. Choose the folder that contains the Game folder."
            return false
        }
        await setInstall(install)
        return true
    }

    private func setInstall(_ install: GameInstall) async {
        self.install = install
        UserDefaults.standard.set(install.root.path, forKey: Self.gamePathKey)
        await refresh()
    }

    /// Number of installed mods for `game` (a mod with several DLC folders counts once).
    func modCount(for game: LEGame, enabledOnly: Bool = false) -> Int {
        let folders = (mods[game] ?? []).filter { !enabledOnly || $0.isEnabled }
        return Set(folders.map { $0.meta?.modName.lowercased() ?? "folder:" + $0.dlcName.lowercased() }).count
    }

    func isInstalled(_ game: LEGame) -> Bool {
        install?.isInstalled(game) ?? false
    }

    // MARK: Installed mods

    func refresh() async {
        guard let install else { return }
        for game in LEGame.allCases where install.isInstalled(game) {
            mods[game] = await ModService.installedMods(for: game, in: install)
            health[game] = await ModService.health(for: game, in: install)
        }
        await setUpGamesIfNeeded()
    }

    /// Games this launch already tried to set up, so a failure doesn't retry on every refresh.
    @ObservationIgnored private var setupAttempted = Set<LEGame>()

    /// Installs the bink bypass and ASIs into any game missing them, without asking: they're
    /// required for every mod, bundled with the app, and the original bink file is backed up.
    private func setUpGamesIfNeeded() async {
        guard let install, activity == nil else { return }
        for game in LEGame.allCases where install.isInstalled(game) && !setupAttempted.contains(game) {
            guard await ModService.needsSetup(game, in: install) else { continue }
            setupAttempted.insert(game)
            activity = "Setting up \(game.displayName) for mods…"
            do {
                try await ModService.prepareGame(game, in: install, progress: progressHandler)
            } catch {
                errorMessage = "Couldn't set up \(game.displayName) for mods: \(error.localizedDescription)"
            }
            activity = nil
            health[game] = await ModService.health(for: game, in: install)
        }
        await rerunMergesIfHelperChanged()
    }

    /// Bump when LEModHelper's merge output changes (e.g. a bug fix), so games merged by an older
    /// helper are re-merged once. 2: fixed LE1 config merge dropping BIOUI.ini (crash at main menu).
    /// 3: per-mod config delta / texture override merges (M3 does these at install) and M3's merge DLC.
    /// 5: undid the LE1 Community Patch menu "fix" (its menus do work; it turned them off).
    private static let mergeVersion = 5

    /// Re-runs the post-install merges for games that have mods and were merged by an older helper.
    private func rerunMergesIfHelperChanged() async {
        guard let install, activity == nil else { return }
        for game in LEGame.allCases where install.isInstalled(game) {
            let key = "mergeVersion.\(game.rawValue)"
            guard UserDefaults.standard.integer(forKey: key) < Self.mergeVersion else { continue }
            guard !(mods[game] ?? []).isEmpty else {
                UserDefaults.standard.set(Self.mergeVersion, forKey: key)
                continue
            }
            activity = "Updating \(game.displayName)'s mod merges…"
            do {
                if UserDefaults.standard.integer(forKey: key) < 3 {
                    try await ModService.applyMissedDLCMerges(for: game, in: install, progress: progressHandler)
                }
                try await ModService.runPostInstall(for: game, in: install, progress: progressHandler)
                UserDefaults.standard.set(Self.mergeVersion, forKey: key)
            } catch {
                errorMessage = "Couldn't update \(game.displayName)'s mod merges: \(error.localizedDescription)"
            }
            activity = nil
        }
    }

    func setEnabled(_ enabled: Bool, mods selection: [InstalledMod], game: LEGame) async {
        activity = enabled ? "Enabling…" : "Disabling…"
        await perform {
            for mod in selection { try await ModService.setEnabled(enabled, mod: mod) }
            try await self.runPostInstall(for: game)
        }
    }

    func uninstall(_ selection: [InstalledMod], game: LEGame) async {
        activity = "Uninstalling…"
        await perform {
            for mod in selection { try await ModService.uninstall(mod) }
            try await self.runPostInstall(for: game)
        }
    }

    /// Starts `game` straight from the app (skipping the Legendary Edition launcher's game picker).
    func launch(_ game: LEGame) async {
        guard activity == nil else {
            errorMessage = "Wait for the current task to finish before starting the game."
            return
        }
        guard let install else { return }
        guard let method = GameLauncher.currentMethod() else {
            errorMessage = "Couldn't find Steam or a CrossOver bottle with Steam to start the game. Install Steam (or set up CrossOver), then try again."
            return
        }
        activity = "Starting \(game.displayName) through \(method.displayName)…"
        do {
            try await GameLauncher.launch(game, using: method, install: install, progress: progressHandler)
            try? await Task.sleep(for: .seconds(3))
        } catch {
            errorMessage = error.localizedDescription
        }
        activity = nil
    }

    /// Installs the bink bypass and required ASIs so the game can load mods.
    func prepareGame(_ game: LEGame) async {
        guard let install else { return }
        activity = "Setting up \(game.displayName) for mods…"
        let progress = progressHandler
        await perform {
            try await ModService.prepareGame(game, in: install, progress: progress)
        }
    }

    // MARK: Bulk maintenance

    /// Uninstalls every mod for `game` and puts back its original game files.
    func removeAllMods(for game: LEGame) async {
        guard let install else { return }
        activity = "Removing all \(game.displayName) mods…"
        let progress = progressHandler
        await perform {
            try await ModService.removeAllMods(for: game, in: install, progress: progress)
        }
    }

    /// Base game files backed up for `game` (shown in the restore confirmation).
    func backedUpFiles(for game: LEGame) async -> [String] {
        guard let install else { return [] }
        return await ModService.backedUpFiles(for: game, in: install)
    }

    /// Puts back the original base game files this app replaced or edited, then re-merges the
    /// installed Custom DLC mods.
    func restoreOriginalFiles(for game: LEGame) async {
        guard let install else { return }
        activity = "Restoring original game files…"
        let progress = progressHandler
        await perform {
            try await ModService.restoreOriginalFiles(for: game, in: install, progress: progress)
        }
    }

    private func runPostInstall(for game: LEGame) async throws {
        guard let install else { return }
        try await ModService.runPostInstall(for: game, in: install, progress: progressHandler)
    }

    /// Shows status lines from long-running steps, ignoring any that arrive after the step finished.
    private var progressHandler: @Sendable (String) -> Void {
        let box = WeakLibrary(self)
        return { message in
            Task { @MainActor in
                if let library = box.library, library.activity != nil { library.activity = message }
            }
        }
    }

    /// Lets progress callbacks from background work reach the library without keeping it alive.
    private final class WeakLibrary: @unchecked Sendable {
        weak var library: ModLibrary?
        init(_ library: ModLibrary) { self.library = library }
    }

    // MARK: Installing

    /// Folders that `package` would replace, so the install sheet can say what will be overwritten.
    func existingInstalls(replacedBy package: ModPackage) -> [InstalledMod] {
        guard let game = package.game else { return [] }
        let names = package.jobs.map(\.destinationName) + package.outdatedDLC
        return (mods[game] ?? []).filter { mod in
            names.contains { $0.caseInsensitiveCompare(mod.dlcName) == .orderedSame }
        }
    }

    /// DLC folders named in `requireddlc` that aren't installed and enabled.
    /// Requirement folders that aren't installed (or are installed but don't meet a version/option
    /// condition), so they can be fetched. For a `?` "any of" list, the first entry stands in for it.
    func missingRequirements(for package: ModPackage) -> [String] {
        guard let game = package.game, let install else { return [] }
        let installed = ModService.installedDLC(for: game, in: install)
        var missing = package.requiredDLC.filter { !$0.isMet(installed) }.map(\.folder)
        if let first = package.optionalRequiredDLC.first, !package.optionalRequiredDLC.contains(where: { $0.isMet(installed) }) {
            missing.append(first.folder)
        }
        return missing
    }

    /// Installed and enabled DLC folders that the mod says it's incompatible with.
    func incompatibilities(for package: ModPackage) -> [String] {
        guard let game = package.game, let install else { return [] }
        let installed = installedDLCNames(for: game, in: install)
        return package.incompatibleDLC.filter { listed in installed.contains { $0.caseInsensitiveCompare(listed) == .orderedSame } }
    }

    private func installedDLCNames(for game: LEGame, in install: GameInstall) -> [String] {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: install.dlcDirectory(game).path)) ?? []
        return folders.filter { !$0.hasPrefix(InstalledMod.disabledPrefix) }
    }

    /// Installs `package` with the chosen options. Errors are returned rather than shown via
    /// `errorMessage` so the caller can show them next to the mod.
    func install(_ package: ModPackage, choices: [String: Bool] = [:], replacing previousFolders: [String] = []) async -> Result<ModService.InstallResult, ModService.ModError> {
        guard let install else { return .failure(ModService.ModError(message: "No game folder is selected.")) }
        activity = "Installing \(package.name)…"
        let result: Result<ModService.InstallResult, ModService.ModError>
        do {
            result = .success(try await ModService.install(package, choices: choices, replacing: previousFolders, into: install, progress: progressHandler))
        } catch {
            result = .failure(ModService.ModError(message: error.localizedDescription))
        }
        activity = nil
        await refresh()
        return result
    }

    /// Option states for `package` in its game right now, for the install options window.
    func optionStates(for package: ModPackage, choices: [String: Bool]) -> [String: ModOptionState] {
        guard let install else { return [:] }
        return ModService.optionStates(for: package, choices: choices, in: install)
    }

    /// Runs a file operation, reports any error, and rescans the game folders afterward.
    private func perform(_ operation: () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
        activity = nil
        await refresh()
    }
}
