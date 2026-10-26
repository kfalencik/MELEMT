import Foundation

/// The three games in Mass Effect Legendary Edition.
nonisolated enum LEGame: String, CaseIterable, Identifiable, Sendable {
    case le1 = "LE1"
    case le2 = "LE2"
    case le3 = "LE3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .le1: "Mass Effect"
        case .le2: "Mass Effect 2"
        case .le3: "Mass Effect 3"
        }
    }

    var symbolName: String {
        switch self {
        case .le1: "1.circle"
        case .le2: "2.circle"
        case .le3: "3.circle"
        }
    }

    /// Folder under `<LE root>/Game/` that holds this game.
    var folderName: String {
        switch self {
        case .le1: "ME1"
        case .le2: "ME2"
        case .le3: "ME3"
        }
    }

    /// Value of `game=` in moddesc.ini, matched case-insensitively.
    init?(moddescValue: String) {
        self.init(rawValue: moddescValue.uppercased())
    }

    /// BioWare-shipped DLC folders. These are never treated as mods and can't be overwritten by a mod.
    var officialDLC: Set<String> {
        switch self {
        case .le1:
            return []
        case .le2:
            return [
                "DLC_00_Shared", "DLC_CER_01", "DLC_CER_02", "DLC_CER_Arc", "DLC_CON_Pack01", "DLC_CON_Pack02",
                "DLC_DHME1", "DLC_EXP_Part01", "DLC_EXP_Part02", "DLC_HEN_MT", "DLC_HEN_VT", "DLC_MCR_01",
                "DLC_MCR_03", "DLC_METR_Patch01", "DLC_PRE_Cerberus", "DLC_PRE_Collectors", "DLC_PRE_DA",
                "DLC_PRE_General", "DLC_PRE_Incisor", "DLC_PRE_Terminus", "DLC_PRO_Gulp01", "DLC_PRO_Pepper01",
                "DLC_PRO_Pepper02", "DLC_UNC_Hammer01", "DLC_UNC_Moment01", "DLC_UNC_Pack01", "DLC_UPD_Patch01",
                "DLC_UPD_Patch02", "DLC_UPD_Patch03",
            ]
        case .le3:
            return [
                "DLC_CON_APP01", "DLC_CON_DH1", "DLC_CON_END", "DLC_CON_GUN01", "DLC_CON_GUN02", "DLC_CON_PRO1",
                "DLC_CON_PRO2", "DLC_CON_PRO3", "DLC_CON_PRO4", "DLC_CON_PRO5", "DLC_CON_PRO6", "DLC_EXP_Pack001",
                "DLC_EXP_Pack002", "DLC_EXP_Pack003", "DLC_EXP_Pack003_Base", "DLC_HEN_PR", "DLC_METR_Patch01",
                "DLC_OnlinePassHidCE", "DLC_UPD_Patch01", "DLC_UPD_Patch02",
            ]
        }
    }

    func isOfficialDLC(_ folderName: String) -> Bool {
        officialDLC.contains { $0.caseInsensitiveCompare(folderName) == .orderedSame }
    }
}

/// A Legendary Edition install on disk (the folder that contains `Game/ME1`, `Game/ME2`, `Game/ME3`).
nonisolated struct GameInstall: Sendable, Equatable {
    let root: URL

    /// The Legendary Edition launcher (Game/Launcher), which LELAUNCHER mods change.
    var launcherDirectory: URL {
        root.appending(path: "Game/Launcher", directoryHint: .isDirectory)
    }

    func gameDirectory(_ game: LEGame) -> URL {
        root.appending(path: "Game").appending(path: game.folderName)
    }

    func dlcDirectory(_ game: LEGame) -> URL {
        gameDirectory(game).appending(path: "BioGame/DLC")
    }

    func binariesDirectory(_ game: LEGame) -> URL {
        gameDirectory(game).appending(path: "Binaries/Win64")
    }

    func isInstalled(_ game: LEGame) -> Bool {
        FileManager.default.fileExists(atPath: gameDirectory(game).appending(path: "BioGame").path)
    }

    /// Accepts the LE root, its `Game` folder, or a single `Game/MEx` folder and normalizes it to the LE root.
    static func validated(from url: URL) -> GameInstall? {
        let candidates = [url, url.deletingLastPathComponent(), url.deletingLastPathComponent().deletingLastPathComponent()]
        return candidates
            .map { GameInstall(root: $0.standardizedFileURL) }
            .first { install in LEGame.allCases.contains { install.isInstalled($0) } }
    }
}
