import Foundation

/// A game config value MELEMT can change. Legendary Edition keeps these in each game's compiled
/// config (Coalesced); MELEMT applies changes as a config delta on top, so they survive mod installs.
nonisolated struct GameTweak: Identifiable, Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case toggle
        case choice([String])
    }

    let id: String
    let title: String
    let detail: String
    let file: String
    let section: String
    let key: String
    let kind: Kind
    let group: String

    /// "File.ini|Section|Key", the helper's config-read format.
    var entry: String { "\(file)|\(section)|\(key)" }

    /// Settings offered for every game; the settings window only shows the ones a game's config has.
    static let all: [GameTweak] = [
        GameTweak(id: "mouseSmoothing", title: "Mouse smoothing", detail: "Smooths mouse movement. Off gives more direct aiming.",
                  file: "BIOInput.ini", section: "Engine.PlayerInput", key: "bEnableMouseSmoothing", kind: .toggle, group: "Controls"),
        GameTweak(id: "consoleKey", title: "Developer console key", detail: "Opens the full developer console.",
                  file: "BIOInput.ini", section: "Engine.Console", key: "ConsoleKey", kind: .choice(["Tilde", "F10", "Insert", "Home", "PageUp"]), group: "Controls"),
        GameTweak(id: "typeKey", title: "Mini console key", detail: "Opens the one-line developer console.",
                  file: "BIOInput.ini", section: "Engine.Console", key: "TypeKey", kind: .choice(["Tab", "F9", "Delete", "End", "PageDown"]), group: "Controls"),
        GameTweak(id: "vsync", title: "VSync", detail: "Syncs frames to the display to avoid tearing.",
                  file: "BIOEngine.ini", section: "SystemSettings", key: "UseVsync", kind: .toggle, group: "Graphics"),
        GameTweak(id: "anisotropy", title: "Anisotropic filtering", detail: "Sharper textures at an angle.",
                  file: "BIOEngine.ini", section: "SystemSettings", key: "MaxAnisotropy", kind: .choice(["1", "2", "4", "8", "16"]), group: "Graphics"),
        GameTweak(id: "motionBlur", title: "Motion blur", detail: "Blurs fast camera movement.",
                  file: "BIOEngine.ini", section: "SystemSettings", key: "MotionBlur", kind: .toggle, group: "Graphics"),
        GameTweak(id: "depthOfField", title: "Depth of field", detail: "Blurs the background in conversations and cutscenes.",
                  file: "BIOEngine.ini", section: "SystemSettings", key: "DepthOfField", kind: .toggle, group: "Graphics"),
        GameTweak(id: "bloom", title: "Bloom", detail: "Glow around bright light.",
                  file: "BIOEngine.ini", section: "SystemSettings", key: "Bloom", kind: .toggle, group: "Graphics"),
        GameTweak(id: "lensFlares", title: "Lens flares", detail: "Flares from bright light sources.",
                  file: "BIOEngine.ini", section: "SystemSettings", key: "LensFlares", kind: .toggle, group: "Graphics"),
        GameTweak(id: "ambientOcclusion", title: "Ambient occlusion", detail: "Soft shadows where surfaces meet.",
                  file: "BIOEngine.ini", section: "SystemSettings", key: "AmbientOcclusion", kind: .toggle, group: "Graphics"),
        GameTweak(id: "dynamicShadows", title: "Dynamic shadows", detail: "Shadows from moving lights and characters.",
                  file: "BIOEngine.ini", section: "SystemSettings", key: "DynamicShadows", kind: .toggle, group: "Graphics"),
    ]
}

/// The user's chosen values per game, saved by MELEMT and applied to the game's config.
nonisolated enum GameSettingsStore {
    private static func key(_ game: LEGame) -> String { "gameSettings.\(game.rawValue)" }

    static func overrides(for game: LEGame) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key(game)) as? [String: String] ?? [:]
    }

    static func save(_ overrides: [String: String], for game: LEGame) {
        UserDefaults.standard.set(overrides, forKey: key(game))
    }

    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "LEModManager/GameSettings", directoryHint: .isDirectory)
    }

    /// The config delta (M3's .m3cd format) for the chosen values. ">" sets a value, replacing the game's.
    static func delta(for game: LEGame) -> String {
        let overrides = overrides(for: game)
        var sections: [String: [String]] = [:]
        var order: [String] = []
        for tweak in GameTweak.all {
            guard let value = overrides[tweak.id] else { continue }
            let header = "[\(tweak.file) \(tweak.section)]"
            if sections[header] == nil { order.append(header) }
            sections[header, default: []].append(">\(tweak.key)=\(value)")
        }
        return order.map { ([$0] + sections[$0]!).joined(separator: "\n") }.joined(separator: "\n\n")
    }

    /// Writes the delta and has the helper apply it to the game's config (or restore the game's own
    /// values when nothing is chosen). Safe to run any time; it always starts from a clean copy.
    @concurrent
    static func apply(for game: LEGame, in install: GameInstall, progress: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let deltaFile = folder.appending(path: "\(game.rawValue).m3cd")
        let stateDir = folder.appending(path: "\(game.rawValue)-state", directoryHint: .isDirectory)
        let text = delta(for: game)
        // Nothing chosen and never applied: leave the game's config alone.
        if text.isEmpty && !fm.fileExists(atPath: stateDir.path) { return }
        try text.write(to: deltaFile, atomically: true, encoding: .utf8)
        try await HelperRunner.run("apply-settings", arguments: [
            "game": game.rawValue,
            "gamedir": install.gameDirectory(game).path,
            "backupdir": HelperRunner.backupDirectory(for: game, in: install).path,
            "statedir": stateDir.path,
            "delta": deltaFile.path,
        ], progress: progress)
    }
}

/// The Legendary Edition launcher's own settings file (shared by all three games).
nonisolated struct LauncherSettings: Sendable, Equatable {
    var language = "en_US"
    var englishVoiceOver = false
    var subtitleSize = 20
    var rumble = true

    static let languages: [(code: String, name: String)] = [
        ("en_US", "English"), ("fr_FR", "French"), ("de_DE", "German"), ("it_IT", "Italian"),
        ("es_ES", "Spanish"), ("pl_PL", "Polish"), ("ru_RU", "Russian"), ("ja_JP", "Japanese"),
    ]
    static let subtitleSizes = [16, 20, 24, 28]

    init() {}

    init(contentsOf url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "language": language = parts[1]
            case "englishvoenabled": englishVoiceOver = parts[1].lowercased() == "true"
            case "subtitlesize": subtitleSize = Int(parts[1]) ?? subtitleSize
            case "rumbleenabled": rumble = parts[1].lowercased() == "true"
            default: break
            }
        }
    }

    /// Updates only these four values in the file, keeping everything else the launcher wrote.
    func write(to url: URL) throws {
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? "[Main]\n"
        let values = ["Language": language, "EnglishVOEnabled": englishVoiceOver ? "true" : "false",
                      "SubtitleSize": String(subtitleSize), "RumbleEnabled": rumble ? "true" : "false"]
        for (key, value) in values {
            var lines = text.components(separatedBy: "\n")
            if let index = lines.firstIndex(where: { $0.lowercased().hasPrefix(key.lowercased() + "=") }) {
                lines[index] = "\(key)=\(value)"
            } else {
                let insertAt = (lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "[Main]" }).map { $0 + 1 } ?? lines.count
                lines.insert("\(key)=\(value)", at: insertAt)
            }
            text = lines.joined(separator: "\n")
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
