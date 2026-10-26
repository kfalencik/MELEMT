import Foundation
import Security

/// A "Mod Manager Download" link from nexusmods.com, e.g.
/// `nxm://masseffectlegendaryedition/mods/23/files/1234?key=…&expires=…&user_id=…`.
/// `key` and `expires` are one-time download credentials the website creates for each click;
/// they're what lets free accounts download through the API.
nonisolated struct NXMLink: Sendable, Hashable {
    let gameDomain: String
    let modID: Int
    let fileID: Int
    let key: String?
    let expires: String?

    /// A link for a file the API can download directly (Premium accounts don't need a one-time key),
    /// or a saved link being resumed.
    init(modID: Int, fileID: Int, key: String? = nil, expires: String? = nil) {
        self.gameDomain = NexusClient.legendaryEditionDomain
        self.modID = modID
        self.fileID = fileID
        self.key = key
        self.expires = expires
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "nxm", let host = url.host() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[0] == "mods", parts[2] == "files",
              let modID = Int(parts[1]), let fileID = Int(parts[3]) else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        self.gameDomain = host.lowercased()
        self.modID = modID
        self.fileID = fileID
        self.key = query.first { $0.name == "key" }?.value
        self.expires = query.first { $0.name == "expires" }?.value
    }

    var modPageURL: URL {
        URL(string: "https://www.nexusmods.com/\(gameDomain)/mods/\(modID)")!
    }
}

/// Minimal client for the Nexus Mods v1 REST API, authenticated with the user's personal API key.
nonisolated enum NexusClient {
    static let legendaryEditionDomain = "masseffectlegendaryedition"
    static let legendaryEditionModsURL = URL(string: "https://www.nexusmods.com/games/masseffectlegendaryedition/mods")!
    static let apiKeysPageURL = URL(string: "https://www.nexusmods.com/users/myaccount?tab=api")!

    struct NexusError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct User: Decodable, Sendable {
        let name: String
        let isPremium: Bool

        enum CodingKeys: String, CodingKey {
            case name
            case isPremium = "is_premium"
        }
    }

    struct ModInfo: Decodable, Sendable {
        let name: String?
        let summary: String?
        let author: String?
        let version: String?
        let pictureURL: URL?

        enum CodingKeys: String, CodingKey {
            case name, summary, author, version
            case pictureURL = "picture_url"
        }
    }

    struct FileInfo: Decodable, Sendable {
        let name: String?
        let fileName: String?
        let version: String?
        let sizeInBytes: Int64?

        enum CodingKeys: String, CodingKey {
            case name, version
            case fileName = "file_name"
            case sizeInBytes = "size_in_bytes"
        }
    }

    struct ModFile: Decodable, Sendable {
        let fileID: Int
        let name: String?
        let version: String?
        let categoryName: String?
        let isPrimary: Bool?
        let uploadedTimestamp: Int?

        enum CodingKeys: String, CodingKey {
            case name, version
            case fileID = "file_id"
            case categoryName = "category_name"
            case isPrimary = "is_primary"
            case uploadedTimestamp = "uploaded_timestamp"
        }
    }

    private struct FileList: Decodable {
        let files: [ModFile]
    }

    private struct DownloadLink: Decodable {
        let uri: URL
        enum CodingKeys: String, CodingKey { case uri = "URI" }
    }

    // MARK: Requests

    static func validate(apiKey: String) async throws -> User {
        try await get("/v1/users/validate.json", apiKey: apiKey)
    }

    static func modInfo(for link: NXMLink, apiKey: String) async throws -> ModInfo {
        try await get("/v1/games/\(link.gameDomain)/mods/\(link.modID).json", apiKey: apiKey)
    }

    static func fileInfo(for link: NXMLink, apiKey: String) async throws -> FileInfo {
        try await get("/v1/games/\(link.gameDomain)/mods/\(link.modID)/files/\(link.fileID).json", apiKey: apiKey)
    }

    static func modInfo(modID: Int, apiKey: String) async throws -> ModInfo {
        try await get("/v1/games/\(legendaryEditionDomain)/mods/\(modID).json", apiKey: apiKey)
    }

    /// All files on a mod's Files page (main, optional, old versions…).
    static func files(modID: Int, apiKey: String) async throws -> [ModFile] {
        let list: FileList = try await get("/v1/games/\(legendaryEditionDomain)/mods/\(modID)/files.json", apiKey: apiKey)
        return list.files
    }

    /// The newest file in the mod's MAIN category: what "update" means for most mods.
    static func latestMainFile(modID: Int, apiKey: String) async throws -> ModFile? {
        let list: FileList = try await get("/v1/games/\(legendaryEditionDomain)/mods/\(modID)/files.json", apiKey: apiKey)
        return list.files
            .filter { $0.categoryName?.uppercased() == "MAIN" }
            .max { ($0.uploadedTimestamp ?? 0) < ($1.uploadedTimestamp ?? 0) }
    }

    static func filesPageURL(modID: Int) -> URL {
        URL(string: "https://www.nexusmods.com/\(legendaryEditionDomain)/mods/\(modID)?tab=files")!
    }

    /// The CDN URL to download the file from. Free accounts need the link's one-time key.
    static func downloadURL(for link: NXMLink, apiKey: String) async throws -> URL {
        var query: [URLQueryItem] = []
        if let key = link.key, let expires = link.expires {
            query = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "expires", value: expires)]
        }
        let links: [DownloadLink] = try await get(
            "/v1/games/\(link.gameDomain)/mods/\(link.modID)/files/\(link.fileID)/download_link.json",
            query: query,
            apiKey: apiKey
        )
        guard let first = links.first else {
            throw NexusError(message: "Nexus Mods didn't return a download link for this file.")
        }
        return first.uri
    }

    private static func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], apiKey: String) async throws -> T {
        var components = URLComponents(string: "https://api.nexusmods.com")!
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LE Mod Manager for Mac", forHTTPHeaderField: "Application-Name")
        request.setValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0", forHTTPHeaderField: "Application-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return try JSONDecoder().decode(T.self, from: data)
        case 401:
            throw NexusError(message: "Nexus Mods didn't accept your API key. Check it in Settings.")
        case 403:
            throw NexusError(message: "Nexus Mods refused the download. Free accounts must start downloads with the \"Mod Manager Download\" button on the mod's Files page.")
        case 410:
            throw NexusError(message: "This download link has expired. Click \"Mod Manager Download\" on Nexus Mods again.")
        case 429:
            throw NexusError(message: "Nexus Mods is limiting requests right now. Try again in a few minutes.")
        default:
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["message"]
            throw NexusError(message: message ?? "Nexus Mods returned an error (HTTP \(status)).")
        }
    }
}

/// Stores the Nexus Mods API key in the login keychain.
nonisolated enum NexusKeychain {
    private static let service = "LEModManager.NexusMods"
    private static let account = "apikey"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) {
        delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
