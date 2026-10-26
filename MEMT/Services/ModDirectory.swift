import Foundation

/// ME3Tweaks' third-party mod identification service: maps mod DLC folder names (e.g.
/// `DLC_MOD_LE2PATCH`) to the mod's name and Nexus Mods page. Used to offer a download when a mod
/// needs another mod first. Cached on disk and refreshed once a day.
nonisolated enum ModDirectory {
    struct Entry: Sendable {
        let name: String
        let developer: String?
        let nexusModID: Int?
    }

    private static let serviceURL = URL(string: "https://me3tweaks.com/modmanager/services/thirdpartyidentificationservice?highprioritysupport=true&allgames=true")!
    private static var cacheFile: URL {
        URL.applicationSupportDirectory.appending(path: "LEModManager/ModDirectory.json")
    }

    private struct RawEntry: Decodable {
        let modname: String?
        let moddev: String?
        let modsite: String?
    }

    /// Looks up a DLC folder for `game`, e.g. `("DLC_MOD_LE2PATCH", .le2)` → Unofficial LE2 Patch, Nexus mod 8.
    static func entry(for dlcFolder: String, game: LEGame) async -> Entry? {
        guard let all = await load(), let raw = all[game.rawValue]?.first(where: { $0.key.caseInsensitiveCompare(dlcFolder) == .orderedSame })?.value,
              let name = raw.modname else { return nil }
        let nexusID = raw.modsite.flatMap { site -> Int? in
            guard site.contains("nexusmods.com/masseffectlegendaryedition"),
                  let match = site.firstMatch(of: /mods\/(\d+)/) else { return nil }
            return Int(match.output.1)
        }
        return Entry(name: name, developer: raw.moddev, nexusModID: nexusID)
    }

    private static func load() async -> [String: [String: RawEntry]]? {
        let fm = FileManager.default
        let age = (try? fm.attributesOfItem(atPath: cacheFile.path)[.modificationDate] as? Date).map { Date.now.timeIntervalSince($0) }
        if let age, age < 24 * 60 * 60, let cached = decode(try? Data(contentsOf: cacheFile)) {
            return cached
        }
        if let (data, response) = try? await URLSession.shared.data(from: serviceURL),
           (response as? HTTPURLResponse)?.statusCode == 200, let fresh = decode(data) {
            try? fm.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
            return fresh
        }
        // Offline: an older cache is better than nothing.
        return decode(try? Data(contentsOf: cacheFile))
    }

    private static func decode(_ data: Data?) -> [String: [String: RawEntry]]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([String: [String: RawEntry]].self, from: data)
    }
}
