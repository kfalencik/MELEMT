import AppKit
import Observation

/// Pictures people choose in place of the app's own artwork, like Steam's custom artwork: a cover
/// for each game's card on the Launch screen and a banner for the top of its page. A copy of each
/// picture is kept in Application Support, so the chosen file can be moved or deleted.
@Observable
final class CustomArtwork {
    enum Kind: String, CaseIterable {
        case cover
        case banner

        var title: String {
            switch self {
            case .cover: "Cover"
            case .banner: "Banner"
            }
        }
    }

    struct ArtworkError: LocalizedError {
        let errorDescription: String?
    }

    private struct Key: Hashable {
        let game: LEGame
        let kind: Kind
    }

    private var images: [Key: NSImage] = [:]

    private static let folder = URL.applicationSupportDirectory
        .appending(path: "LEModManager/Artwork", directoryHint: .isDirectory)

    init() {
        for game in LEGame.allCases {
            for kind in Kind.allCases {
                if let file = Self.files(for: game, kind).first {
                    images[Key(game: game, kind: kind)] = NSImage(contentsOf: file)
                }
            }
        }
    }

    /// The chosen picture, or nil to show the app's own artwork.
    func image(for game: LEGame, _ kind: Kind) -> NSImage? {
        images[Key(game: game, kind: kind)]
    }

    /// Uses the picture at `source` for `game`.
    func setImage(from source: URL, for game: LEGame, _ kind: Kind) throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: source), image.isValid else {
            throw ArtworkError(errorDescription: "\(source.lastPathComponent) isn't a picture MELEMT can open.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        removeFiles(for: game, kind)
        let fileExtension = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        try fm.copyItem(at: source, to: Self.folder.appending(path: "\(Self.baseName(game, kind)).\(fileExtension)"))
        images[Key(game: game, kind: kind)] = image
    }

    /// Goes back to the app's own artwork.
    func reset(_ game: LEGame, _ kind: Kind) {
        removeFiles(for: game, kind)
        images[Key(game: game, kind: kind)] = nil
    }

    private static func baseName(_ game: LEGame, _ kind: Kind) -> String {
        "\(game.rawValue)-\(kind.rawValue)"
    }

    private static func files(for game: LEGame, _ kind: Kind) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.deletingPathExtension().lastPathComponent == baseName(game, kind) }
    }

    private func removeFiles(for game: LEGame, _ kind: Kind) {
        for file in Self.files(for: game, kind) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
