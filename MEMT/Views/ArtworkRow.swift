import SwiftUI
import UniformTypeIdentifiers

/// A settings row for choosing a custom cover or banner for a game, with a preview and a reset.
struct ArtworkRow: View {
    @Environment(CustomArtwork.self) private var artwork
    let game: LEGame
    let kind: CustomArtwork.Kind
    @State private var isChoosing = false
    @State private var errorMessage: String?

    private var detail: String {
        switch kind {
        case .cover: "Shown on the game's card on the Launch screen."
        case .banner: "Shown across the top of the game's page."
        }
    }

    private var previewSize: CGSize {
        switch kind {
        case .cover: CGSize(width: 54, height: 60)
        case .banner: CGSize(width: 132, height: 30)
        }
    }

    var body: some View {
        let custom = artwork.image(for: game, kind)
        LabeledContent {
            HStack(spacing: 10) {
                Group {
                    if let custom {
                        ArtworkImage(image: custom)
                    } else {
                        GameArt(game: game)
                    }
                }
                .frame(width: previewSize.width, height: previewSize.height)
                .clipShape(.rect(cornerRadius: 4))
                Button("Choose…") { isChoosing = true }
                if custom != nil {
                    Button("Reset") { artwork.reset(game, kind) }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(errorMessage ?? detail)
                    .font(.caption)
                    .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
            }
        }
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            do {
                try artwork.setImage(from: url, for: game, kind)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .fileDialogMessage("Choose a \(kind.title.lowercased()) picture for \(game.displayName).")
    }
}

/// A chosen picture filling its frame, cropped rather than stretched. The frame comes from the
/// parent, so the picture's own size never affects layout.
struct ArtworkImage: View {
    let image: NSImage

    var body: some View {
        Color.black
            .overlay {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
    }
}
