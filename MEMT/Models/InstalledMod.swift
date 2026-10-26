import Foundation

/// A non-official DLC folder found in a game's `BioGame/DLC` directory.
nonisolated struct InstalledMod: Identifiable, Sendable, Hashable {
    /// Disabled DLC folders are prefixed with `x` (M3 convention), which the game ignores.
    static let disabledPrefix = "x"

    let folderURL: URL
    let meta: MetaCMM?
    let mountPriority: Int?

    var id: URL { folderURL }
    var folderName: String { folderURL.lastPathComponent }
    var isEnabled: Bool { !folderName.hasPrefix(Self.disabledPrefix) }

    /// The folder name without the disabled prefix, e.g. `DLC_MOD_LE1CP`.
    var dlcName: String { isEnabled ? folderName : String(folderName.dropFirst(Self.disabledPrefix.count)) }

    var displayName: String { meta?.modName ?? dlcName }
    var version: String { meta?.version ?? "" }
    var installTime: Date? { meta?.installTime }
    var hasModManagerMetadata: Bool { meta != nil }

    static func == (lhs: InstalledMod, rhs: InstalledMod) -> Bool {
        lhs.folderURL == rhs.folderURL && lhs.meta == rhs.meta && lhs.mountPriority == rhs.mountPriority
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(folderURL)
    }
}

/// Status of the files the games need to load Custom DLC mods.
nonisolated struct GameHealth: Sendable, Equatable {
    /// The bink2w64.dll proxy that disables the game's DLC signature check. Without it Custom DLC won't load.
    var hasBinkBypass: Bool
    var installedASIs: [String]

    var hasAutoTOC: Bool {
        installedASIs.contains { $0.localizedCaseInsensitiveContains("autotoc") }
    }

    /// The bundled AutoloadEnabler (v13+: its TLK override makes mod text work in menus, which
    /// LE1 Community Patch 2.0 needs). An older version counts as missing so it gets replaced.
    static let autoloadEnablerFile = "LE1AutoloadEnabler-v13.asi"
    var hasAutoloadEnabler: Bool {
        installedASIs.contains { $0.caseInsensitiveCompare(Self.autoloadEnablerFile) == .orderedSame }
    }

    /// Plain-language problems that stop mods from loading in `game`.
    func issues(for game: LEGame) -> [HealthIssue] {
        var issues: [HealthIssue] = []
        if !hasBinkBypass {
            issues.append(HealthIssue(
                title: "Mods won't load yet",
                detail: "\(game.displayName) needs the bink bypass, a small file that lets the game load mods. Install it once with ME3Tweaks Mod Manager, or copy bink2w64.dll and bink2w64_original.dll from a modded copy into Game/\(game.folderName)/Binaries/Win64."
            ))
        }
        if game == .le1 && !hasAutoloadEnabler {
            issues.append(HealthIssue(
                title: "Some Mass Effect mods may not load",
                detail: "The AutoloadEnabler ASI that ME3Tweaks Mod Manager normally installs for Mass Effect isn't in Binaries/Win64/ASI."
            ))
        }
        return issues
    }
}

nonisolated struct HealthIssue: Identifiable, Sendable, Hashable {
    var id: String { title }
    let title: String
    let detail: String
}
