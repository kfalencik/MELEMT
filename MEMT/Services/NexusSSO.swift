import Foundation

/// "Log in with Nexus Mods" using Nexus's single sign-on: the app opens a WebSocket to
/// sso.nexusmods.com, sends the user to an authorize page in their browser, and receives an API
/// key once they approve.
///
/// SSO needs an application "slug" that Nexus Mods staff issue on request (email
/// support@nexusmods.com with a build, name, description and logo). Put it in Info.plist under
/// `NexusApplicationSlug`; until then the app uses the in-app API key page instead.
nonisolated enum NexusSSO {
    struct SSOError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var applicationSlug: String? {
        guard let slug = Bundle.main.object(forInfoDictionaryKey: "NexusApplicationSlug") as? String,
              !slug.isEmpty else { return nil }
        return slug
    }

    static var isAvailable: Bool { applicationSlug != nil }

    private struct Message: Decodable {
        struct Payload: Decodable {
            let apiKey: String?
            let connectionToken: String?
            enum CodingKeys: String, CodingKey {
                case apiKey = "api_key"
                case connectionToken = "connection_token"
            }
        }
        let success: Bool
        let data: Payload?
        let error: String?
    }

    /// Returns the user's API key. `openAuthorizePage` is called with the URL to open in the browser.
    static func logIn(openAuthorizePage: @escaping @Sendable (URL) -> Void) async throws -> String {
        guard let slug = applicationSlug else {
            throw SSOError(message: "Nexus Mods sign-in isn't set up for this app yet.")
        }
        let requestID = UUID().uuidString.lowercased()
        let socket = URLSession.shared.webSocketTask(with: URL(string: "wss://sso.nexusmods.com")!)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let hello = try JSONSerialization.data(withJSONObject: ["id": requestID, "token": NSNull(), "protocol": 2])
        try await socket.send(.string(String(decoding: hello, as: UTF8.self)))
        openAuthorizePage(URL(string: "https://www.nexusmods.com/sso?id=\(requestID)&application=\(slug)")!)

        // Keep the connection alive while the user signs in.
        let keepAlive = Task {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(30))
                socket.sendPing { _ in }
            }
        }
        defer { keepAlive.cancel() }

        while true {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: continue
            }
            let decoded = try JSONDecoder().decode(Message.self, from: data)
            if !decoded.success {
                throw SSOError(message: decoded.error ?? "Nexus Mods sign-in failed.")
            }
            if let key = decoded.data?.apiKey {
                return key
            }
            // The first reply only carries a connection token; keep waiting for the key.
        }
    }
}
