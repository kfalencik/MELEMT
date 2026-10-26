import Foundation

/// Looks for Legendary Edition in the usual places on a Mac: Steam libraries on mounted drives,
/// and Steam/EA installs inside CrossOver bottles.
nonisolated enum GameLocator {
    private static let folderName = "Mass Effect Legendary Edition"

    @concurrent
    static func locate() async -> GameInstall? {
        candidates().lazy.compactMap(GameInstall.validated(from:)).first
    }

    private static func candidates() -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []

        // Steam libraries at the root of any mounted volume.
        let volumes = (try? fm.contentsOfDirectory(at: URL(filePath: "/Volumes"), includingPropertiesForKeys: nil)) ?? []
        for volume in volumes {
            results.append(volume.appending(path: "SteamLibrary/steamapps/common/\(folderName)"))
            results.append(volume.appending(path: "steamapps/common/\(folderName)"))
        }

        // CrossOver bottles: default Steam/EA install paths, plus any extra Steam libraries the bottle knows about.
        let bottlesDirectory = fm.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/CrossOver/Bottles")
        let bottles = (try? fm.contentsOfDirectory(at: bottlesDirectory, includingPropertiesForKeys: nil)) ?? []
        for bottle in bottles {
            let driveC = bottle.appending(path: "drive_c")
            let steam = driveC.appending(path: "Program Files (x86)/Steam")
            results.append(steam.appending(path: "steamapps/common/\(folderName)"))
            results.append(driveC.appending(path: "Program Files/EA Games/\(folderName)"))
            for library in steamLibraries(in: steam, bottle: bottle) {
                results.append(library.appending(path: "steamapps/common/\(folderName)"))
            }
        }
        return results
    }

    /// Reads Steam's `libraryfolders.vdf` and maps its Windows paths (e.g. `D:\\SteamLibrary`)
    /// to macOS paths via the bottle's `dosdevices` drive symlinks.
    private static func steamLibraries(in steam: URL, bottle: URL) -> [URL] {
        let vdf = steam.appending(path: "steamapps/libraryfolders.vdf")
        guard let text = try? String(contentsOf: vdf, encoding: .utf8) else { return [] }
        let pattern = /"path"\s+"([A-Za-z]):((?:[^"\\]|\\.)*)"/
        return text.matches(of: pattern).map { match in
            let drive = match.output.1.lowercased()
            let rest = match.output.2
                .replacingOccurrences(of: "\\\\", with: "/")
                .replacingOccurrences(of: "\\", with: "/")
            return bottle.appending(path: "dosdevices/\(drive):").resolvingSymlinksInPath().appending(path: rest)
        }
    }
}
