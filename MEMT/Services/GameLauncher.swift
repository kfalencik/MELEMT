import AppKit

/// How the Windows games are started on this Mac.
nonisolated enum LaunchMethod: Hashable, Sendable {
    /// The Mac Steam app (with a compatibility layer such as NotProton running the Windows game).
    case steam
    /// Steam installed inside a CrossOver bottle.
    case crossOver(bottle: String)

    var displayName: String {
        switch self {
        case .steam: "Steam"
        case .crossOver(let bottle): "CrossOver (\(bottle) bottle)"
        }
    }

    /// Stored in UserDefaults.
    var storageValue: String {
        switch self {
        case .steam: "steam"
        case .crossOver(let bottle): "crossover:\(bottle)"
        }
    }

    init?(storageValue: String) {
        if storageValue == "steam" {
            self = .steam
        } else if storageValue.hasPrefix("crossover:") {
            self = .crossOver(bottle: String(storageValue.dropFirst("crossover:".count)))
        } else {
            return nil
        }
    }
}

/// Starts Mass Effect 1, 2 or 3 directly, skipping the Legendary Edition launcher's game picker,
/// the way ME3Tweaks Mod Manager does: the bink bypass in Game/Launcher reads `-game N -autoterminate`
/// (from the command line, or from `HKCU\Software\ME3Tweaks\LEAutobootArgs`), boots that game
/// and closes the launcher. Launching always goes through Steam so its DRM is satisfied.
nonisolated enum GameLauncher {
    static let preferredMethodKey = "launchMethod"
    static let skipLauncherKey = "skipLELauncher"
    /// Steam app ID for Mass Effect Legendary Edition.
    private static let steamAppID = "1328670"

    struct LaunchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The ways to start the games that are set up on this Mac, best first.
    static func availableMethods() -> [LaunchMethod] {
        var methods: [LaunchMethod] = []
        if NSWorkspace.shared.urlForApplication(toOpen: URL(string: "steam://run/\(steamAppID)")!) != nil {
            methods.append(.steam)
        }
        if cxstartURL != nil {
            methods += crossOverSteamBottles().map { .crossOver(bottle: $0) }
        }
        return methods
    }

    /// The method from Settings if it's still available, otherwise the first available one.
    static func currentMethod() -> LaunchMethod? {
        let available = availableMethods()
        if let saved = UserDefaults.standard.string(forKey: preferredMethodKey).flatMap(LaunchMethod.init(storageValue:)),
           available.contains(saved) {
            return saved
        }
        return available.first
    }

    /// Launcher arguments: which game to boot.
    static func arguments(for game: LEGame) -> [String] {
        let number = switch game {
        case .le1: "1"
        case .le2: "2"
        case .le3: "3"
        }
        return ["-game", number, "-autoterminate"]
    }

    static func launch(_ game: LEGame, using method: LaunchMethod, install: GameInstall, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        // With the launcher not skipped, no autoboot arguments are set, so the launcher opens normally.
        let skip = UserDefaults.standard.object(forKey: skipLauncherKey) as? Bool ?? true
        let args = skip ? arguments(for: game) : []
        try installLauncherBypass(in: install)
        switch method {
        case .steam:
            // Mac Steam refuses `steam://run/<id>//<args>` for a Windows game ("Invalid platform"),
            // so the arguments go in the Wine prefix's registry for the launcher's bink bypass and
            // the game starts the same way as the Play button (which NotProton handles).
            let prefix = steamPrefix(for: install)
            try await ensureSteamHasNotProton(progress: progress)
            // The EA app sometimes fails to reach its own background service under Wine (see
            // clearStaleEAServicePort). Watch its log and retry instead of leaving its error up.
            let eaLog = prefix.appending(path: "drive_c/ProgramData/EA Desktop/Logs/EASteamLauncher.log")
            for attempt in 1...3 {
                try await clearStaleEAServicePort(prefix: prefix, progress: progress)
                try writeAutobootArguments(args, prefix: prefix)
                let logStart = fileSize(eaLog)
                guard let url = URL(string: "steam://rungameid/\(steamAppID)"), NSWorkspace.shared.open(url) else {
                    throw LaunchError(message: "Steam didn't open. Make sure Steam is installed and signed in.")
                }
                progress(attempt == 1 ? "Starting \(game.displayName) through the EA app…" : "Starting \(game.displayName) again (attempt \(attempt))…")
                switch try await waitForEALaunch(log: eaLog, from: logStart) {
                case .started, .noAnswer:
                    return
                case .couldNotConnect:
                    progress("The EA app didn't connect. Closing it and trying again…")
                    terminateEAApp()
                }
            }
            throw LaunchError(message: "The EA app couldn't start \(game.displayName) after 3 tries. Quit Steam, open it again, then press Play.")
        case .crossOver(let bottle):
            guard let cxstart = cxstartURL else {
                throw LaunchError(message: "CrossOver isn't installed.")
            }
            let process = Process()
            process.executableURL = cxstart
            process.arguments = ["--bottle", bottle, "--", #"C:\Program Files (x86)\Steam\steam.exe"#, "-applaunch", steamAppID] + args
            process.environment = gameEnvironment(adding: [:])
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw LaunchError(message: "CrossOver couldn't start Steam in the \(bottle) bottle: \(error.localizedDescription)")
            }
        }
    }

    // MARK: NotProton

    private static let notProtonLog = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/notproton/notproton.log")

    /// NotProton works by adding `DYLD_INSERT_LIBRARIES=…/notproton.dylib` to Steam.app's
    /// LSEnvironment, so it's only active in a Steam opened as an app. A Steam started any other
    /// way treats the game as Windows-only ("Invalid platform", only "Stream" offered). So if
    /// NotProton is set up and the running Steam doesn't have it, Steam is (re)opened with
    /// NotProton's environment. Without NotProton this does nothing.
    private static func ensureSteamHasNotProton(progress: @escaping @Sendable (String) -> Void) async throws {
        guard let steamApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.valvesoftware.steam"),
              let environment = Bundle(url: steamApp)?.object(forInfoDictionaryKey: "LSEnvironment") as? [String: String],
              let dylib = environment["DYLD_INSERT_LIBRARIES"], dylib.contains("notproton"),
              FileManager.default.fileExists(atPath: dylib) else { return }

        let running = runningSteamPIDs()
        if !running.isEmpty {
            if running.contains(where: notProtonLoaded(intoPID:)) { return }
            progress("Restarting Steam…")
            NSWorkspace.shared.open(URL(string: "steam://exit")!)
            for _ in 0..<60 where !runningSteamPIDs().isEmpty {
                try await Task.sleep(for: .seconds(1))
            }
            guard runningSteamPIDs().isEmpty else {
                throw LaunchError(message: "Steam is running without NotProton and didn't quit. Quit Steam, then press Play again.")
            }
        }

        progress("Starting Steam with NotProton…")
        let logStart = (try? FileManager.default.attributesOfItem(atPath: notProtonLog.path)[.size] as? Int) ?? 0
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = gameEnvironment(adding: environment)
        configuration.activates = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: steamApp, configuration: configuration)
        } catch {
            throw LaunchError(message: "Couldn't open Steam: \(error.localizedDescription)")
        }

        // Wait for NotProton's hooks (Steam may update and relaunch itself first), then give Steam
        // a moment to finish signing in.
        progress("Waiting for Steam to sign in…")
        for _ in 0..<240 {
            try await Task.sleep(for: .seconds(1))
            if newLogText(since: logStart).contains("install_thread: ready") {
                try await Task.sleep(for: .seconds(8))
                return
            }
        }
        throw LaunchError(message: "Steam opened but NotProton didn't load. Open Steam from the NotProton app, then press Play again.")
    }

    /// The environment Steam (and so the game) is started with: this app's, minus debugging
    /// settings that must not reach the game. When MELEMT runs from Xcode, Xcode turns on Metal
    /// API validation, which makes Mass Effect abort with a page fault while loading textures.
    private static func gameEnvironment(adding extra: [String: String]) -> [String: String] {
        let blockedPrefixes = ["MTL_", "METAL_", "DYLD_", "__XPC_", "OS_ACTIVITY", "NSZombie", "Malloc", "XCODE", "__XCODE"]
        var result = ProcessInfo.processInfo.environment.filter { key, _ in
            !blockedPrefixes.contains { key.hasPrefix($0) }
        }
        // Explicitly off, in case the launched app inherits anything anyway.
        result["MTL_DEBUG_LAYER"] = "0"
        result["METAL_DEVICE_WRAPPER_TYPE"] = "0"
        result["MTL_SHADER_VALIDATION"] = "0"
        result.merge(extra) { _, new in new }
        return result
    }

    /// Process IDs of the running Steam client (the Steam.app launcher and the client it starts).
    static func runningSteamPIDs() -> [pid_t] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-x", "steam_osx"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// NotProton logs "np_init: loaded into steam_osx (pid N)" each time it loads into Steam.
    static func notProtonLoaded(intoPID pid: pid_t) -> Bool {
        newLogText(since: 0).contains("loaded into steam_osx (pid \(pid))")
    }

    private static func newLogText(since offset: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: notProtonLog) else { return "" }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    // MARK: EA app

    /// The EA app's launcher reads the background service's port from backgroundservice.ini right
    /// after starting the service, and under Wine it often reads it before the new service has
    /// written it, so it connects to the previous run's port and fails with "Something went wrong".
    /// Without the file it waits for the new one. If the EA app is still closing from the last
    /// session, this waits for it first (the file is in use until then).
    private static func clearStaleEAServicePort(prefix: URL, progress: @escaping @Sendable (String) -> Void) async throws {
        let ini = prefix.appending(path: "drive_c/ProgramData/EA Desktop/backgroundservice.ini")
        guard FileManager.default.fileExists(atPath: ini.path) else { return }
        let eaProcesses = "EABackgroundService|EASteamLauncher|EADesktop|MassEffect"
        if isRunning(matching: eaProcesses) {
            progress("Waiting for the EA app to close from last time…")
            for _ in 0..<30 where isRunning(matching: eaProcesses) {
                try await Task.sleep(for: .seconds(1))
            }
            guard !isRunning(matching: eaProcesses) else {
                throw LaunchError(message: "Mass Effect or the EA app is still running. Close it, then press Play again.")
            }
        }
        try? FileManager.default.removeItem(at: ini)
    }

    private static func isRunning(matching pattern: String) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private enum EALaunchOutcome { case started, couldNotConnect, noAnswer }

    /// Follows the EA app's launcher log until it starts the game or reports it couldn't reach its service.
    private static func waitForEALaunch(log: URL, from offset: Int) async throws -> EALaunchOutcome {
        for _ in 0..<120 {
            try await Task.sleep(for: .seconds(1))
            let text = readText(of: log, from: offset)
            if text.contains("Game process created") || text.contains("Game process resumed") { return .started }
            if text.contains("Failed to connect to BGS") { return .couldNotConnect }
        }
        return .noAnswer
    }

    /// Closes the EA app's Steam launcher (and with it its error window); NotProton then tears down the prefix.
    private static func terminateEAApp() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pkill")
        process.arguments = ["-f", "EASteamLauncher"]
        try? process.run()
        process.waitUntilExit()
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private static func readText(of url: URL, from offset: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        // The EA app starts a new log each session; if the file is now shorter, read it from the top.
        let start = fileSize(url) < offset ? 0 : offset
        try? handle.seek(toOffset: UInt64(start))
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    // MARK: Launcher autoboot

    /// The launcher's bink2w64.dll must be the ME3Tweaks bypass, which does the autoboot.
    /// The launcher's own copy is kept as bink2w64_original.dll (which the bypass loads) and backed up.
    private static func installLauncherBypass(in install: GameInstall) throws {
        let fm = FileManager.default
        let launcher = install.launcherDirectory
        guard let bypass = Bundle.main.url(forResource: "bink2w64-bypass.dll", withExtension: nil),
              let original = Bundle.main.url(forResource: "bink2w64-original.dll", withExtension: nil) else {
            throw LaunchError(message: "The app is missing its setup files. Reinstall the app.")
        }
        let bink = launcher.appending(path: "bink2w64.dll")
        guard fm.fileExists(atPath: launcher.path), !fm.contentsEqual(atPath: bink.path, andPath: bypass.path) else { return }
        let backup = HelperRunner.backupDirectory(for: .le1, in: install).deletingLastPathComponent()
            .appending(path: "Launcher-Setup", directoryHint: .isDirectory)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        if fm.fileExists(atPath: bink.path), !fm.fileExists(atPath: backup.appending(path: "bink2w64.dll").path) {
            try fm.copyItem(at: bink, to: backup.appending(path: "bink2w64.dll"))
        }
        for (target, source) in [(bink, bypass), (launcher.appending(path: "bink2w64_original.dll"), original)] {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
        }
    }

    /// NotProton keeps the game's Wine prefix next to the game, in its Steam library's compatdata folder.
    static func steamPrefix(for install: GameInstall) -> URL {
        // <library>/steamapps/common/Mass Effect Legendary Edition → <library>/steamapps/compatdata/1328670/pfx
        install.root.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "compatdata/\(steamAppID)/pfx", directoryHint: .isDirectory)
    }

    /// Sets `HKCU\Software\ME3Tweaks\LEAutobootArgs` in the prefix's user.reg, as M3 does on Windows.
    /// If the prefix doesn't exist yet (the game has never run), the launcher simply shows its picker.
    static func writeAutobootArguments(_ args: [String], prefix: URL) throws {
        let file = prefix.appending(path: "user.reg")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        // The bypass expects a space before the arguments.
        let value = " " + args.joined(separator: " ")
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let valueLine = "\"LEAutobootArgs\"=\"\(escaped)\""
        var lines = text.components(separatedBy: "\n")
        if let header = lines.firstIndex(where: { $0.lowercased().hasPrefix("[software\\\\me3tweaks]") }) {
            var end = header + 1
            while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
            if let existing = (header + 1..<end).first(where: { lines[$0].lowercased().hasPrefix("\"leautobootargs\"=") }) {
                lines[existing] = valueLine
            } else {
                lines.insert(valueLine, at: header + 1)
            }
        } else {
            if lines.last == "" { lines.removeLast() }
            lines += ["", "[Software\\\\ME3Tweaks] \(Int(Date.now.timeIntervalSince1970))", valueLine, ""]
        }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// The Legendary Edition launcher's settings files (language, voice-over, subtitles, rumble):
    /// one in the Steam/NotProton Wine prefix and one in each CrossOver bottle with Steam, where present.
    static func launcherConfigFiles(for install: GameInstall) -> [URL] {
        let relative = "Documents/BioWare/Mass Effect Legendary Edition/LauncherConfig.cfg"
        var candidates = [steamPrefix(for: install).appending(path: "drive_c/users/steamuser/\(relative)")]
        let bottles = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/CrossOver/Bottles")
        for bottle in crossOverSteamBottles() {
            candidates.append(bottles.appending(path: "\(bottle)/drive_c/users/crossover/\(relative)"))
        }
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: CrossOver

    private static var cxstartURL: URL? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.codeweavers.CrossOver") else { return nil }
        let url = app.appending(path: "Contents/SharedSupport/CrossOver/bin/cxstart")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Bottles (in CrossOver's bottle folder and the default one) that have Steam installed.
    private static func crossOverSteamBottles() -> [String] {
        let fm = FileManager.default
        var folders = [fm.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/CrossOver/Bottles")]
        if let custom = UserDefaults(suiteName: "com.codeweavers.CrossOver")?.string(forKey: "BottleDir") {
            folders.insert(URL(filePath: custom), at: 0)
        }
        var bottles: [String] = []
        for folder in folders {
            for bottle in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                let steam = bottle.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
                if fm.fileExists(atPath: steam.path), !bottles.contains(bottle.lastPathComponent) {
                    bottles.append(bottle.lastPathComponent)
                }
            }
        }
        return bottles
    }
}
