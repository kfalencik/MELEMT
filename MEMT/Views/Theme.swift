import SwiftUI

/// Mass Effect–inspired styling: N7 red, a color per game, wide uppercase headings and the
/// angled "N7 stripe". (No official logos or artwork; those are trademarks.)
nonisolated enum MEStyle {
    /// N7 red (also the app's accent color in the asset catalog).
    static let n7Red = Color(red: 0.82, green: 0.11, blue: 0.18)
    /// Omni-tool orange.
    static let omniOrange = Color(red: 0.98, green: 0.55, blue: 0.16)
    /// Systems Alliance blue.
    static let allianceBlue = Color(red: 0.25, green: 0.58, blue: 0.92)
    static let panel = Color(white: 0.11)

    static func tint(for game: LEGame) -> Color {
        switch game {
        case .le1: allianceBlue
        case .le2: omniOrange
        case .le3: n7Red
        }
    }

    /// Short codename shown on game cards.
    static func codename(for game: LEGame) -> String {
        switch game {
        case .le1: "ME1"
        case .le2: "ME2"
        case .le3: "ME3"
        }
    }
}

extension View {
    /// Wide, heavy, uppercase heading in the style of the games' menus.
    func meHeading(size: CGFloat = 28) -> some View {
        font(.system(size: size, weight: .heavy))
            .fontWidth(.expanded)
            .textCase(.uppercase)
            .tracking(size > 20 ? 2 : 1)
    }

    /// Small wide uppercase label.
    func meLabel() -> some View {
        font(.caption.weight(.semibold))
            .fontWidth(.expanded)
            .textCase(.uppercase)
            .tracking(1.2)
    }
}

/// The angled red-and-white stripe from the N7 armor.
struct N7Stripe: View {
    var color: Color = MEStyle.n7Red
    var height: CGFloat = 6

    var body: some View {
        HStack(spacing: 3) {
            Parallelogram().fill(color).frame(width: 120)
            Parallelogram().fill(.white.opacity(0.9)).frame(width: 14)
            Parallelogram().fill(color.opacity(0.6)).frame(width: 40)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct Parallelogram: Shape {
    func path(in rect: CGRect) -> Path {
        let slant = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + slant, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - slant, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Banner at the top of each game page: the banner picture the user chose, or the game's drawn art.
struct GameBanner<Trailing: View>: View {
    @Environment(CustomArtwork.self) private var artwork
    let game: LEGame
    let subtitle: String
    let statusColor: Color
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let tint = MEStyle.tint(for: game)
        ZStack(alignment: .bottomLeading) {
            if let banner = artwork.image(for: game, .banner) {
                ArtworkImage(image: banner)
            } else {
                GameArt(game: game)
                    .clipped()
            }
            // Darken toward the text so it stays readable over bright art.
            LinearGradient(
                colors: [.black.opacity(0.85), .black.opacity(0.35), .clear],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            )
            ScanLines()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Legendary Edition").meLabel().foregroundStyle(tint)
                    Text(game.displayName).meHeading(size: 30)
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(subtitle).font(.callout).foregroundStyle(.white.opacity(0.75))
                    }
                    N7Stripe(color: tint).padding(.top, 4)
                }
                Spacer()
                trailing
            }
            .padding(24)
        }
        .frame(height: 200)
        .clipped()
    }
}

/// Faint diagonal lines for a holographic UI-panel feel.
struct ScanLines: View {
    var body: some View {
        Canvas { context, size in
            var x: CGFloat = -size.height
            while x < size.width {
                var line = Path()
                line.move(to: CGPoint(x: x, y: size.height))
                line.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(line, with: .color(.white.opacity(0.035)), lineWidth: 1)
                x += 14
            }
        }
        .allowsHitTesting(false)
    }
}

/// Drawn deep-space backdrop: nebula glow, a starfield and galaxy-map orbit rings.
struct SpaceBackdrop: View {
    var tint: Color = MEStyle.allianceBlue

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.03, green: 0.05, blue: 0.12), Color(red: 0.07, green: 0.08, blue: 0.2), Color(red: 0.14, green: 0.04, blue: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(colors: [tint.opacity(0.45), .clear], center: .init(x: 0.7, y: 0.35), startRadius: 0, endRadius: 420)
            Canvas { context, size in
                // Deterministic starfield so it doesn't shimmer on redraw.
                var seed: UInt64 = 0x5EED
                func next() -> CGFloat {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
                }
                let count = Int(size.width * size.height / 1800)
                for _ in 0..<count {
                    let r = 0.4 + next() * 1.6
                    let star = CGRect(x: next() * size.width, y: next() * size.height, width: r, height: r)
                    context.fill(Path(ellipseIn: star), with: .color(.white.opacity(0.2 + next() * 0.6)))
                }
                // Galaxy-map orbit rings.
                let center = CGPoint(x: size.width * 0.72, y: size.height * 0.4)
                for (i, radius) in [120.0, 200.0, 290.0].enumerated() {
                    let ring = CGRect(x: center.x - radius, y: center.y - radius * 0.38, width: radius * 2, height: radius * 0.76)
                    context.stroke(Path(ellipseIn: ring), with: .color(tint.opacity(0.12 + 0.05 * Double(i))), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The app's mass relay emblem (same design as the app icon): two prongs around a glowing core.
struct RelayEmblem: View {
    var size: CGFloat = 120

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width / 1024
            let c = CGPoint(x: canvas.width / 2, y: canvas.height * 0.46)
            // Core glow.
            context.fill(
                Path(ellipseIn: CGRect(x: c.x - 230 * s, y: c.y - 230 * s, width: 460 * s, height: 460 * s)),
                with: .radialGradient(Gradient(colors: [Color(red: 0.75, green: 0.92, blue: 1), Color(red: 0.25, green: 0.6, blue: 1).opacity(0.6), .clear]),
                                      center: c, startRadius: 0, endRadius: 230 * s)
            )
            for flip in [1.0, -1.0] {
                var prong = Path()
                prong.move(to: CGPoint(x: c.x - 60 * s * flip, y: c.y + 300 * s))
                prong.addCurve(to: CGPoint(x: c.x - 190 * s * flip, y: c.y - 330 * s),
                               control1: CGPoint(x: c.x - 360 * s * flip, y: c.y + 210 * s),
                               control2: CGPoint(x: c.x - 340 * s * flip, y: c.y - 210 * s))
                prong.addCurve(to: CGPoint(x: c.x - 12 * s * flip, y: c.y + 300 * s),
                               control1: CGPoint(x: c.x - 255 * s * flip, y: c.y - 170 * s),
                               control2: CGPoint(x: c.x - 250 * s * flip, y: c.y + 190 * s))
                prong.closeSubpath()
                context.fill(prong, with: .linearGradient(Gradient(colors: [Color(white: 0.95), Color(white: 0.6), Color(white: 0.3)]),
                                                          startPoint: CGPoint(x: c.x, y: c.y - 330 * s), endPoint: CGPoint(x: c.x, y: c.y + 300 * s)))
                context.stroke(prong, with: .color(Color(red: 0.6, green: 0.85, blue: 1).opacity(0.75)), lineWidth: max(1, 3 * s))
            }
            let hub = Path(roundedRect: CGRect(x: c.x - 80 * s, y: c.y + 274 * s, width: 160 * s, height: 56 * s), cornerRadius: 22 * s)
            context.fill(hub, with: .color(Color(white: 0.45)))
            context.fill(Path(ellipseIn: CGRect(x: c.x - 30 * s, y: c.y - 30 * s, width: 60 * s, height: 60 * s)), with: .color(Color(red: 0.9, green: 0.97, blue: 1)))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The app's name. MELEMT already stands for Mass Effect Legendary Edition Mod Tool, so it isn't
/// spelled out again next to it.
struct MELEMTWordmark: View {
    var size: CGFloat = 20

    var body: some View {
        Text("MELEMT")
            .meHeading(size: size)
            .accessibilityLabel("MELEMT, Mass Effect Legendary Edition Mod Tool")
    }
}
