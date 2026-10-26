import AppKit

/// Mass Effect Legendary Edition artwork from the user's own Steam library cache (Steam keeps
/// the store art for installed games on disk). Nothing is bundled with the app; if Steam's cache
/// isn't found, the views fall back to the app's own drawn artwork.
nonisolated enum SteamArt {
    /// Steam app ID for Mass Effect Legendary Edition.
    private static let appID = "1328670"

    enum Kind: String {
        /// Wide key art (blue Earth fading to red); used behind the game banners.
        case hero = "library_hero.jpg"
        /// "MASS EFFECT / LEGENDARY EDITION" logo with transparency.
        case logo = "logo.png"
    }

    static func image(_ kind: Kind) -> NSImage? {
        cache[kind.rawValue].flatMap(\.self)
    }

    /// Loaded once per launch.
    private static let cache: [String: NSImage?] = {
        var images: [String: NSImage?] = [:]
        for kind in [Kind.hero, .logo] {
            images[kind.rawValue] = folders.lazy
                .map { $0.appending(path: kind.rawValue) }
                .compactMap { NSImage(contentsOf: $0) }
                .first
        }
        return images
    }()

    /// Native Steam for Mac, then Steam inside any CrossOver bottle.
    private static var folders: [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var result = [home.appending(path: "Library/Application Support/Steam/appcache/librarycache/\(appID)")]
        let bottles = home.appending(path: "Library/Application Support/CrossOver/Bottles")
        for bottle in (try? fm.contentsOfDirectory(at: bottles, includingPropertiesForKeys: nil)) ?? [] {
            result.append(bottle.appending(path: "drive_c/Program Files (x86)/Steam/appcache/librarycache/\(appID)"))
        }
        return result
    }
}
