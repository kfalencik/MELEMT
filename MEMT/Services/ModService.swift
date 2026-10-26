import Foundation

/// File-system operations on a game's DLC folder. All work runs off the main actor
/// because mods are often several gigabytes and live on external drives.
nonisolated enum ModService {
    struct ModError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Scanning

    @concurrent
    static func installedMods(for game: LEGame, in install: GameInstall) async -> [InstalledMod] {
        let dlcDirectory = install.dlcDirectory(game)
        let folders = (try? FileManager.default.contentsOfDirectory(at: dlcDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return folders
            .filter { PathResolver.isDirectory($0) }
            .compactMap { folder -> InstalledMod? in
                let name = folder.lastPathComponent
                let dlcName = name.hasPrefix(InstalledMod.disabledPrefix) ? String(name.dropFirst()) : name
                guard dlcName.uppercased().hasPrefix("DLC_"), !game.isOfficialDLC(dlcName) else { return nil }
                return InstalledMod(
                    folderURL: folder,
                    meta: MetaCMM(contentsOf: folder.appending(path: MetaCMM.fileName)),
                    mountPriority: mountPriority(of: folder, game: game)
                )
            }
            .sorted { ($0.mountPriority ?? 0, $0.dlcName) < ($1.mountPriority ?? 0, $1.dlcName) }
    }

    /// LE1 stores mount priority in `AutoLoad.ini` (`[ME1DLCMOUNT] ModMount=`). LE2/LE3 keep it in the
    /// binary `Mount.dlc`, whose layout isn't documented in this source, so it isn't shown for those games.
    private static func mountPriority(of folder: URL, game: LEGame) -> Int? {
        guard game == .le1,
              let autoLoad = PathResolver.resolve("AutoLoad.ini", in: folder),
              let text = try? String(contentsOf: autoLoad, encoding: .utf8) else { return nil }
        return IniFile(text: text).value("ME1DLCMOUNT", "ModMount").flatMap { Int($0) }
    }

    @concurrent
    static func health(for game: LEGame, in install: GameInstall) async -> GameHealth {
        let binaries = install.binariesDirectory(game)
        let fm = FileManager.default
        let asis = (try? fm.contentsOfDirectory(atPath: binaries.appending(path: "ASI").path)) ?? []
        return GameHealth(
            hasBinkBypass: hasBinkBypass(in: binaries),
            installedASIs: asis.filter { $0.lowercased().hasSuffix(".asi") }.sorted()
        )
    }

    /// The bypass is in place when bink2w64.dll matches the bundled bypass and the original DLL it
    /// forwards to (bink2w64_original.dll) is next to it.
    private static func hasBinkBypass(in binaries: URL) -> Bool {
        let fm = FileManager.default
        let proxy = binaries.appending(path: "bink2w64.dll")
        guard fm.fileExists(atPath: binaries.appending(path: "bink2w64_original.dll").path),
              let installed = fm.contents(atPath: proxy.path) else { return false }
        guard let bundled = Bundle.main.url(forResource: "bink2w64-bypass.dll", withExtension: nil),
              let expected = fm.contents(atPath: bundled.path) else { return true }
        return installed == expected
    }

    /// Finds every moddesc.ini under `folder`. Archives can contain several mods, each rooted at its moddesc.ini.
    @concurrent
    static func findMods(in folder: URL) async -> [Result<ModPackage, Error>] {
        findModsSynchronously(in: folder)
    }

    // NSDirectoryEnumerator iteration isn't allowed directly in async contexts.
    private static func findModsSynchronously(in folder: URL) -> [Result<ModPackage, Error>] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var results: [Result<ModPackage, Error>] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == "__MACOSX" {
                enumerator.skipDescendants()
                continue
            }
            if url.lastPathComponent.caseInsensitiveCompare("moddesc.ini") == .orderedSame {
                results.append(Result { try ModPackage(moddescURL: url) })
            }
        }
        return results
    }

    // MARK: Changing installed mods

    /// Enables or disables a mod by adding or removing the `x` folder prefix the game ignores.
    @concurrent
    static func setEnabled(_ enabled: Bool, mod: InstalledMod) async throws {
        guard enabled != mod.isEnabled else { return }
        let newName = enabled ? mod.dlcName : InstalledMod.disabledPrefix + mod.dlcName
        let destination = mod.folderURL.deletingLastPathComponent().appending(path: newName)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw ModError(message: "Can't \(enabled ? "enable" : "disable") \(mod.displayName) because a folder named \(newName) already exists.")
        }
        try FileManager.default.moveItem(at: mod.folderURL, to: destination)
    }

    /// Uninstalls by moving the folder to the Trash, so it can be recovered.
    @concurrent
    static func uninstall(_ mod: InstalledMod) async throws {
        try FileManager.default.trashItem(at: mod.folderURL, resultingItemURL: nil)
    }

    // MARK: Installing

    /// What an install put where, so the library can tell later whether it's installed and offer
    /// the same choices again.
    struct InstallResult: Sendable {
        let dlcFolders: [String]
        let selectedOptionIDs: [String]
    }

    /// Lowercased names of the enabled DLC folders in `game` (official and mods), for option conditions.
    static func enabledDLC(for game: LEGame, in install: GameInstall) -> Set<String> {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: install.dlcDirectory(game).path)) ?? []
        return Set(folders.filter { $0.uppercased().hasPrefix("DLC_") }.map { $0.lowercased() })
    }

    /// Enabled DLC folders with their `_metacmm.txt`, for checking `requireddlc` conditions.
    static func installedDLC(for game: LEGame, in install: GameInstall) -> InstalledDLC {
        var result = InstalledDLC()
        let directory = install.dlcDirectory(game)
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where folder.uppercased().hasPrefix("DLC_") {
            result.names.insert(folder.lowercased())
            if let meta = MetaCMM(contentsOf: directory.appending(path: folder).appending(path: MetaCMM.fileName)) {
                result.metas[folder.lowercased()] = meta
            }
        }
        return result
    }

    /// Why `package` can't be installed with the DLC installed now (M3's SharedInstaller checks), or nil.
    static func requirementProblem(for package: ModPackage, in install: GameInstall) -> String? {
        guard let game = package.game else { return nil }
        let installed = installedDLC(for: game, in: install)
        for requirement in package.requiredDLC {
            if let reason = requirement.check(installed) { return reason }
        }
        if !package.optionalRequiredDLC.isEmpty && !package.optionalRequiredDLC.contains(where: { $0.isMet(installed) }) {
            return "\(package.name) needs at least one of: \(package.optionalRequiredDLC.map(\.folder).joined(separator: ", "))."
        }
        let conflicts = package.incompatibleDLC.filter { installed.contains($0) }
        if !conflicts.isEmpty {
            return "\(package.name) can't be installed together with \(conflicts.joined(separator: ", ")). Remove or disable it first."
        }
        return nil
    }

    /// Resolves `package`'s optional components for the game as it is now and the user's `choices`.
    static func optionStates(for package: ModPackage, choices: [String: Bool], in install: GameInstall) -> [String: ModOptionState] {
        guard let game = package.game else { return [:] }
        let resolver = ModOptionResolver(options: package.options, installedDLC: enabledDLC(for: game, in: install), gameDirectory: install.gameDirectory(game))
        return resolver.resolve(choices: choices)
    }

    /// Installs `package` with the chosen options, following M3's steps: remove outdated folders,
    /// replace any existing copy of each Custom DLC (enabled or disabled), copy the planned files
    /// and write `_metacmm.txt`, install [BASEGAME] files, apply merge mods and the LE1 TLK merge,
    /// install requested ASIs, then run the post-install merges.
    @concurrent
    @discardableResult
    static func install(_ package: ModPackage, choices: [String: Bool] = [:], replacing previousFolders: [String] = [], into install: GameInstall, progress: @escaping @Sendable (String) -> Void) async throws -> InstallResult {
        guard package.canInstall, let game = package.game else {
            throw ModError(message: package.blockingIssues.first ?? "\(package.name) can't be installed.")
        }
        if package.targetsLauncher {
            try installLauncherFiles(package, homeGame: game, in: install, progress: progress)
            return InstallResult(dlcFolders: [], selectedOptionIDs: [])
        }
        guard install.isInstalled(game) else {
            throw ModError(message: "\(game.displayName) isn't installed in the selected game folder.")
        }
        if let problem = requirementProblem(for: package, in: install) {
            throw ModError(message: problem)
        }
        let fm = FileManager.default
        let dlcDirectory = install.dlcDirectory(game)
        try fm.createDirectory(at: dlcDirectory, withIntermediateDirectories: true)

        if await needsSetup(game, in: install) {
            try await prepareGame(game, in: install, progress: progress)
        }

        let states = optionStates(for: package, choices: choices, in: install)
        let plan = try InstallPlan(package: package, states: states)

        // Reinstalling with different options: remove folders the previous choices installed that
        // the new choices don't (e.g. switching between pick-one styles).
        for previous in previousFolders where !plan.dlcFolders.contains(where: { $0.caseInsensitiveCompare(previous) == .orderedSame }) {
            for existing in existingFolders(named: previous, in: dlcDirectory) {
                progress("Removing \(existing.lastPathComponent) from the previous options…")
                try fm.trashItem(at: existing, resultingItemURL: nil)
            }
        }

        var meta = MetaCMM(
            modName: package.name,
            version: package.metaVersion,
            featureLevel: package.featureLevel,
            sourceModdescHash: package.moddescHash,
            nexusUpdateCode: package.nexusCode,
            installTime: .now
        )
        meta.installOptions = plan.selectedOptionNames
        meta.optionKeys = package.options.filter { states[$0.id]?.selected == true }.map(\.id)

        for folder in plan.dlcFolders {
            try Task.checkCancellation()
            progress("Copying \(folder)…")
            // Build the folder in a hidden staging folder so a failed copy never leaves a half-installed mod.
            let staging = dlcDirectory.appending(path: ".\(folder).installing")
            try? fm.removeItem(at: staging)
            do {
                for (relative, source) in plan.dlcFiles where relative.hasPrefix(folder + "/") {
                    let destination = staging.appending(path: String(relative.dropFirst(folder.count + 1)))
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: source, to: destination)
                }
                try meta.write(to: staging.appending(path: MetaCMM.fileName))
                // Archives can carry read-only files; later merges must be able to save into them (M3 CopyDir clears it too).
                makeWritable(staging)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
            for existing in existingFolders(named: folder, in: dlcDirectory) {
                try fm.removeItem(at: existing)
            }
            try fm.moveItem(at: staging, to: dlcDirectory.appending(path: folder))
        }

        // From here on the mod's folders are in place. If a later step fails, still run the
        // post-install merges so the game matches what's installed (as M3 does), then report the error.
        let gameDirectory = install.gameDirectory(game)
        let backupDirectory = HelperRunner.backupDirectory(for: game, in: install)
        do {
            try await installAfterCopying(package, plan: plan, game: game, gameDirectory: gameDirectory, backupDirectory: backupDirectory, dlcDirectory: dlcDirectory, progress: progress)
        } catch {
            try? await runPostInstall(for: game, in: install, progress: progress)
            throw error
        }

        try await runPostInstall(for: game, in: install, progress: progress)
        return InstallResult(
            dlcFolders: plan.dlcFolders,
            selectedOptionIDs: package.options.filter { states[$0.id]?.selected == true }.map(\.id)
        )
    }

    /// The install steps after the DLC folders are copied, in M3's order (ModInstaller.cs): per-DLC
    /// config/texture merges, [BASEGAME] files, merge mods and TLK merge, ASIs, then outdated folders.
    private static func installAfterCopying(_ package: ModPackage, plan: InstallPlan, game: LEGame, gameDirectory: URL, backupDirectory: URL, dlcDirectory: URL, progress: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        let cmmver = package.featureLevel.isEmpty ? "9.0" : package.featureLevel

        // Config deltas (LE2/LE3) and texture overrides (moddesc 9.2+) are merged into each folder.
        for folder in plan.dlcFolders {
            try await HelperRunner.run("dlc-merge", arguments: [
                "game": game.rawValue,
                "gamedir": gameDirectory.path,
                "dlcfolder": folder,
                "cmmver": cmmver,
                "backupdir": backupDirectory.path,
            ], progress: progress)
        }

        // Base game file replacements. Originals are backed up the first time they're overwritten.
        for (relative, source) in plan.basegameFiles.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            progress("Installing \(source.lastPathComponent)…")
            let destination = PathResolver.resolve(relative, in: gameDirectory) ?? gameDirectory.appending(path: relative)
            try backUpOriginal(destination, gameDirectory: gameDirectory, backupDirectory: backupDirectory)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: try temporaryCopy(of: source, nextTo: destination))
            } else {
                try fm.copyItem(at: source, to: destination)
            }
            makeWritable(destination)
        }

        // Package-editing steps (merge mods, LE1 TLK merge) run in LEModHelper.
        if !plan.mergeMods.isEmpty || package.usesTLKMerge {
            var arguments = [
                "game": game.rawValue,
                "gamedir": gameDirectory.path,
                "backupdir": backupDirectory.path,
                "mod": package.rootURL.path,
                "modname": package.name,
                "cmmver": cmmver,
                "tlkmerge": package.usesTLKMerge ? "true" : "false",
            ]
            if !plan.mergeMods.isEmpty {
                arguments["mergemods"] = plan.mergeMods.joined(separator: ";")
            }
            if !plan.tlkOptionKeys.isEmpty {
                arguments["tlkoptions"] = plan.tlkOptionKeys.joined(separator: ";")
            }
            try await HelperRunner.run("merges", arguments: arguments, progress: progress)
        }

        if !package.asiMods.isEmpty {
            try await HelperRunner.run("install-asi", arguments: [
                "game": game.rawValue,
                "gamedir": gameDirectory.path,
                "asimods": package.asiMods.map(\.helperArgument).joined(separator: ";"),
            ], progress: progress)
        }

        // M3 removes outdated folders after installing, by exact name (ModInstaller.cs).
        for outdated in package.outdatedDLC where !plan.dlcFolders.contains(where: { $0.caseInsensitiveCompare(outdated) == .orderedSame }) {
            let existing = dlcDirectory.appending(path: outdated)
            if fm.fileExists(atPath: existing.path) {
                progress("Removing outdated \(outdated)…")
                try fm.trashItem(at: existing, resultingItemURL: nil)
            }
        }
    }

    /// Clears read-only flags under `url` (file or folder).
    private static func makeWritable(_ url: URL) {
        let fm = FileManager.default
        func fix(_ item: URL) {
            guard let attributes = try? fm.attributesOfItem(atPath: item.path) else { return }
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            var changes: [FileAttributeKey: Any] = [:]
            if permissions & 0o200 == 0 { changes[.posixPermissions] = NSNumber(value: permissions | 0o200) }
            if (attributes[.immutable] as? NSNumber)?.boolValue == true { changes[.immutable] = false }
            if !changes.isEmpty { try? fm.setAttributes(changes, ofItemAtPath: item.path) }
        }
        fix(url)
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let item as URL in enumerator { fix(item) }
        }
    }

    /// Copies an LELAUNCHER mod's files into Game/Launcher, backing up the launcher's originals
    /// alongside `homeGame`'s backups so restoring that game's original files puts them back.
    private static func installLauncherFiles(_ package: ModPackage, homeGame: LEGame, in install: GameInstall, progress: @escaping @Sendable (String) -> Void) throws {
        let fm = FileManager.default
        let launcher = install.launcherDirectory
        guard fm.fileExists(atPath: launcher.path) else {
            throw ModError(message: "The Legendary Edition launcher folder (Game/Launcher) is missing.")
        }
        let backupDirectory = launcherBackupDirectory(for: homeGame, in: install)
        for file in package.launcherFiles {
            try Task.checkCancellation()
            progress("Installing \(file.sourceURL.lastPathComponent) into the launcher…")
            let destination = PathResolver.resolve(file.gameRelativePath, in: launcher) ?? launcher.appending(path: file.gameRelativePath)
            try backUpOriginal(destination, gameDirectory: launcher, backupDirectory: backupDirectory)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try replaceFile(destination, with: file.sourceURL)
        }
    }

    /// Where originals of launcher files changed by `game`'s launcher mods are kept.
    static func launcherBackupDirectory(for game: LEGame, in install: GameInstall) -> URL {
        let gameBackups = HelperRunner.backupDirectory(for: game, in: install)
        return gameBackups.deletingLastPathComponent().appending(path: "\(game.rawValue)-Launcher", directoryHint: .isDirectory)
    }

    /// Installs what the game needs to load mods, as M3 does before every install: the bink bypass
    /// (signature bypass + ASI loader) and the AutoTOC / LE1 AutoloadEnabler ASIs. The files ship
    /// in the app (MEMT/GameSetup), so this works offline. The game's own bink2w64.dll is backed up
    /// so Restore Original Game Files can put it back.
    @concurrent
    static func prepareGame(_ game: LEGame, in install: GameInstall, progress: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        let gameDirectory = install.gameDirectory(game)
        let binaries = install.binariesDirectory(game)
        guard fm.fileExists(atPath: binaries.path) else {
            throw ModError(message: "\(game.displayName)'s Binaries/Win64 folder is missing.")
        }
        func bundled(_ name: String) throws -> URL {
            guard let url = Bundle.main.url(forResource: name, withExtension: nil) else {
                throw ModError(message: "The app is missing its setup file \(name). Reinstall the app.")
            }
            return url
        }

        let health = await health(for: game, in: install)
        if !health.hasBinkBypass {
            progress("Setting up \(game.displayName) to load mods…")
            let bink = binaries.appending(path: "bink2w64.dll")
            try backUpOriginal(bink, gameDirectory: gameDirectory, backupDirectory: HelperRunner.backupDirectory(for: game, in: install))
            try replaceFile(bink, with: bundled("bink2w64-bypass.dll"))
            try replaceFile(binaries.appending(path: "bink2w64_original.dll"), with: bundled("bink2w64-original.dll"))
        }

        let asiFolder = binaries.appending(path: "ASI")
        try fm.createDirectory(at: asiFolder, withIntermediateDirectories: true)
        if !health.hasAutoTOC {
            try replaceFile(asiFolder.appending(path: "AutoTOCLE-v2.asi"), with: bundled("AutoTOCLE-v2.asi"))
        }
        if game == .le1 && !health.hasAutoloadEnabler {
            // Only one AutoloadEnabler may be loaded: remove older versions, as M3 does when updating an ASI.
            let existing = (try? fm.contentsOfDirectory(atPath: asiFolder.path)) ?? []
            for old in existing where old.localizedCaseInsensitiveContains("autoloadenabler") && old.lowercased().hasSuffix(".asi") {
                try fm.removeItem(at: asiFolder.appending(path: old))
            }
            try replaceFile(asiFolder.appending(path: GameHealth.autoloadEnablerFile), with: bundled(GameHealth.autoloadEnablerFile))
        }
        try installVCRuntime(into: binaries)
    }

    /// The Microsoft C++ runtime (VC++ 14.5) that ASI mods are built against. Wine setups (CrossOver,
    /// NotProton) often have an older one (e.g. 14.34), and ASIs built with Visual Studio 2022 17.10+
    /// crash on it at startup with a null read in msvcp140.dll — the LE1 AutoloadEnabler then never
    /// mounts mods. Like M3 under Wine (ASIWine.ExtractVC145ToTargetAsync), the runtime is copied next to
    /// the game executable, which Windows searches before system32.
    static let vcRuntimeFiles = [
        "msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll", "msvcp140_atomic_wait.dll", "msvcp140_codecvt_ids.dll",
        "vcruntime140.dll", "vcruntime140_1.dll", "vcruntime140_threads.dll", "concrt140.dll",
    ]

    private static func installVCRuntime(into binaries: URL) throws {
        let fm = FileManager.default
        for name in vcRuntimeFiles {
            guard let source = Bundle.main.url(forResource: name, withExtension: nil) else {
                throw ModError(message: "The app is missing its setup file \(name). Reinstall the app.")
            }
            let destination = binaries.appending(path: name)
            if fm.contentsEqual(atPath: source.path, andPath: destination.path) { continue }
            try replaceFile(destination, with: source)
        }
    }

    static func hasVCRuntime(_ game: LEGame, in install: GameInstall) -> Bool {
        let binaries = install.binariesDirectory(game)
        return vcRuntimeFiles.allSatisfy { name in
            guard let source = Bundle.main.url(forResource: name, withExtension: nil) else { return true }
            return FileManager.default.contentsEqual(atPath: source.path, andPath: binaries.appending(path: name).path)
        }
    }

    /// Copies `source` over `destination`, replacing it if it exists.
    private static func replaceFile(_ destination: URL, with source: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: try temporaryCopy(of: source, nextTo: destination))
        } else {
            try fm.copyItem(at: source, to: destination)
        }
    }

    /// Whether `game` is missing any of the files `prepareGame` installs.
    @concurrent
    static func needsSetup(_ game: LEGame, in install: GameInstall) async -> Bool {
        let health = await health(for: game, in: install)
        return !health.hasBinkBypass || !health.hasAutoTOC || (game == .le1 && !health.hasAutoloadEnabler) || !hasVCRuntime(game, in: install)
    }

    /// The merges M3 runs after any change to a game's mods (PlotManager sync, LE1 Coalesced and 2DA
    /// merges, shader merge), then AutoTOC so the game sees every file's current size. They depend
    /// on the set of enabled DLC, so this also runs after enabling, disabling or uninstalling.
    @concurrent
    static func runPostInstall(for game: LEGame, in install: GameInstall, progress: @escaping @Sendable (String) -> Void) async throws {
        try await HelperRunner.run("post-install", arguments: [
            "game": game.rawValue,
            "gamedir": install.gameDirectory(game).path,
            "backupdir": HelperRunner.backupDirectory(for: game, in: install).path,
        ], progress: progress)
        // The merges can rebuild the config file; put the user's game settings back on top.
        try await GameSettingsStore.apply(for: game, in: install, progress: progress)
    }

    /// Base game files this app has backed up for `game`, as game-relative paths.
    @concurrent
    static func backedUpFiles(for game: LEGame, in install: GameInstall) async -> [String] {
        files(under: HelperRunner.backupDirectory(for: game, in: install))
    }

    /// Paths of the files under `folder`, relative to it.
    private static func files(under folder: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.allObjects.compactMap { item -> String? in
            guard let url = item as? URL, !PathResolver.isDirectory(url) else { return nil }
            return String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
        }
    }

    /// Copies every backed-up original back into the game, then reruns the post-install merges so the
    /// still-installed Custom DLC mods are merged into the restored files. Changes that mods made with
    /// merge mods, TLK merges or [BASEGAME] files are undone.
    @concurrent
    static func restoreOriginalFiles(for game: LEGame, in install: GameInstall, progress: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        let gameDirectory = install.gameDirectory(game)
        let backupDirectory = HelperRunner.backupDirectory(for: game, in: install)
        for relativePath in await backedUpFiles(for: game, in: install) {
            progress("Restoring \(relativePath)…")
            let destination = gameDirectory.appending(path: relativePath)
            let restored = try temporaryCopy(of: backupDirectory.appending(path: relativePath), nextTo: destination)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: restored)
            } else {
                try fm.moveItem(at: restored, to: destination)
            }
        }
        // The restored files include the game's own bink2w64.dll; put the mod loader back so mods still load.
        try await prepareGame(game, in: install, progress: progress)
        let launcherBackups = launcherBackupDirectory(for: game, in: install)
        for relativePath in files(under: launcherBackups) {
            progress("Restoring the launcher's \((relativePath as NSString).lastPathComponent)…")
            let destination = install.launcherDirectory.appending(path: relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try replaceFile(destination, with: launcherBackups.appending(path: relativePath))
        }
        try await runPostInstall(for: game, in: install, progress: progress)
    }

    // MARK: Bulk maintenance

    /// Uninstalls every mod for `game` (to the Trash) and puts back the original game files the
    /// app changed, then re-runs the post-install merges on the clean game.
    @concurrent
    static func removeAllMods(for game: LEGame, in install: GameInstall, progress: @escaping @Sendable (String) -> Void) async throws {
        for mod in await installedMods(for: game, in: install) {
            progress("Removing \(mod.displayName)…")
            try FileManager.default.trashItem(at: mod.folderURL, resultingItemURL: nil)
        }
        try await restoreOriginalFiles(for: game, in: install, progress: progress)
    }

    /// Copies `file` to the backup folder unless a backup already exists, so the backup always holds
    /// the file as it was before this app first changed it.
    private static func backUpOriginal(_ file: URL, gameDirectory: URL, backupDirectory: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return }
        let relativePath = String(file.standardizedFileURL.path.dropFirst(gameDirectory.standardizedFileURL.path.count + 1))
        let backup = backupDirectory.appending(path: relativePath)
        guard !fm.fileExists(atPath: backup.path) else { return }
        try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: file, to: backup)
    }

    /// A copy of `source` in the destination's folder, so it can replace the destination atomically.
    private static func temporaryCopy(of source: URL, nextTo destination: URL) throws -> URL {
        let copy = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    /// Existing folders for `dlcName` (enabled or `x`-disabled), matched case-insensitively.
    static func existingFolders(named dlcName: String, in dlcDirectory: URL) -> [URL] {
        let names = [dlcName, InstalledMod.disabledPrefix + dlcName]
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dlcDirectory.path)) ?? []
        return contents
            .filter { item in names.contains { $0.caseInsensitiveCompare(item) == .orderedSame } }
            .map { dlcDirectory.appending(path: $0) }
    }
}
