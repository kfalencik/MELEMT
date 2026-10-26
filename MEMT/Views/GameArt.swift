import SwiftUI

/// Original key art for each game, drawn in code. It borrows only each era's mood and colours
/// (no logos, characters or game imagery): ME1 a cold blue void with a pair of glowing eyes above a
/// planet, ME2 an orange sun behind a hex-plated derelict, ME3 a world burning under falling streaks.
struct GameArt: View {
    let game: LEGame

    var body: some View {
        Canvas { context, size in
            switch game {
            case .le1: drawLE1(&context, size)
            case .le2: drawLE2(&context, size)
            case .le3: drawLE3(&context, size)
            }
        }
        .background(Color.black)
        .accessibilityHidden(true)
    }

    // MARK: Shared pieces

    /// Deterministic pseudo-random numbers so the art is identical on every redraw.
    private struct Seeded {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    private func fill(_ context: inout GraphicsContext, _ size: CGSize, _ colors: [Color], start: UnitPoint = .top, end: UnitPoint = .bottom) {
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(colors: colors), startPoint: point(start, size), endPoint: point(end, size)))
    }

    private func point(_ unit: UnitPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: unit.x * size.width, y: unit.y * size.height)
    }

    private func stars(_ context: inout GraphicsContext, _ size: CGSize, seed: UInt64, count: Int, tint: Color) {
        var random = Seeded(state: seed)
        for _ in 0..<count {
            let x = random.next() * size.width
            let y = random.next() * size.height
            let r = 0.4 + random.next() * 1.3
            let alpha = 0.25 + random.next() * 0.75
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                         with: .color((random.next() < 0.15 ? tint : .white).opacity(alpha)))
        }
    }

    /// Soft radial light.
    private func glow(_ context: inout GraphicsContext, at center: CGPoint, radius: CGFloat, color: Color) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect),
                     with: .radialGradient(Gradient(colors: [color, color.opacity(0)]), center: center, startRadius: 0, endRadius: radius))
    }

    /// A planet whose top edge arcs across the bottom of the frame, with an atmosphere rim.
    private func planet(_ context: inout GraphicsContext, _ size: CGSize, centerX: CGFloat, top: CGFloat, radius: CGFloat,
                        body: [Color], rim: Color) {
        let center = CGPoint(x: centerX, y: top + radius)
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect.insetBy(dx: -radius * 0.04, dy: -radius * 0.04)),
                     with: .radialGradient(Gradient(colors: [rim.opacity(0), rim.opacity(0), rim.opacity(0.55), rim.opacity(0)]),
                                           center: center, startRadius: 0, endRadius: radius * 1.04))
        context.fill(Path(ellipseIn: rect),
                     with: .linearGradient(Gradient(colors: body), startPoint: CGPoint(x: center.x, y: top), endPoint: CGPoint(x: center.x, y: top + radius * 0.6)))
        context.stroke(Path(ellipseIn: rect), with: .color(rim.opacity(0.9)), lineWidth: 1.5)
    }

    // MARK: Mass Effect

    private func drawLE1(_ context: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        fill(&context, size, [Color(red: 0.01, green: 0.03, blue: 0.09), Color(red: 0.03, green: 0.10, blue: 0.24), Color(red: 0.02, green: 0.05, blue: 0.12)])
        stars(&context, size, seed: 1, count: Int(w * h / 900), tint: .cyan)

        // A looming dark mass across the top with two cold eyes.
        var mass = Path()
        mass.move(to: CGPoint(x: 0, y: 0))
        mass.addLine(to: CGPoint(x: w, y: 0))
        mass.addLine(to: CGPoint(x: w, y: h * 0.30))
        mass.addQuadCurve(to: CGPoint(x: w * 0.5, y: h * 0.46), control: CGPoint(x: w * 0.78, y: h * 0.50))
        mass.addQuadCurve(to: CGPoint(x: 0, y: h * 0.30), control: CGPoint(x: w * 0.22, y: h * 0.50))
        mass.closeSubpath()
        context.fill(mass, with: .linearGradient(Gradient(colors: [Color(red: 0.04, green: 0.07, blue: 0.14), Color(red: 0.08, green: 0.14, blue: 0.26).opacity(0.85)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: h * 0.46)))
        // Ridged plating lines.
        for i in 0..<9 {
            let x = w * (0.1 + Double(i) * 0.1)
            var ridge = Path()
            ridge.move(to: CGPoint(x: x, y: 0))
            ridge.addQuadCurve(to: CGPoint(x: w * 0.5 + (x - w * 0.5) * 0.55, y: h * 0.42), control: CGPoint(x: x, y: h * 0.3))
            context.stroke(ridge, with: .color(Color(red: 0.35, green: 0.55, blue: 0.85).opacity(0.10)), lineWidth: 2)
        }
        for side in [-1.0, 1.0] {
            let eye = CGPoint(x: w * 0.5 + side * w * 0.17, y: h * 0.22)
            glow(&context, at: eye, radius: min(w, h) * 0.20, color: Color(red: 0.25, green: 0.6, blue: 1.0).opacity(0.55))
            var slit = Path()
            slit.addEllipse(in: CGRect(x: eye.x - w * 0.055, y: eye.y - h * 0.012, width: w * 0.11, height: h * 0.024))
            context.fill(slit, with: .color(Color(red: 0.75, green: 0.92, blue: 1.0)))
        }

        // Planet with an orange sunrise flare on its rim.
        planet(&context, size, centerX: w * 0.5, top: h * 0.76, radius: w * 0.9,
               body: [Color(red: 0.10, green: 0.18, blue: 0.32), Color(red: 0.02, green: 0.04, blue: 0.08)],
               rim: Color(red: 0.45, green: 0.75, blue: 1.0))
        glow(&context, at: CGPoint(x: w * 0.5, y: h * 0.76), radius: w * 0.35, color: Color(red: 1.0, green: 0.55, blue: 0.15).opacity(0.75))
        glow(&context, at: CGPoint(x: w * 0.5, y: h * 0.76), radius: w * 0.08, color: .white.opacity(0.9))
    }

    // MARK: Mass Effect 2

    private func drawLE2(_ context: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        fill(&context, size, [Color(red: 0.03, green: 0.05, blue: 0.14), Color(red: 0.25, green: 0.10, blue: 0.06), Color(red: 0.55, green: 0.22, blue: 0.06)])
        stars(&context, size, seed: 2, count: Int(w * h / 1400), tint: .orange)

        // Sun low on the horizon.
        let sun = CGPoint(x: w * 0.28, y: h * 0.62)
        glow(&context, at: sun, radius: w * 0.55, color: Color(red: 1.0, green: 0.45, blue: 0.1).opacity(0.55))
        glow(&context, at: sun, radius: w * 0.12, color: Color(red: 1.0, green: 0.85, blue: 0.55))

        // Hex-plated derelict hull rising on the right.
        var hull = Path()
        hull.move(to: CGPoint(x: w * 0.55, y: h))
        hull.addLine(to: CGPoint(x: w * 0.68, y: h * 0.18))
        hull.addLine(to: CGPoint(x: w * 0.82, y: h * 0.10))
        hull.addLine(to: CGPoint(x: w, y: h * 0.22))
        hull.addLine(to: CGPoint(x: w, y: h))
        hull.closeSubpath()
        context.fill(hull, with: .linearGradient(Gradient(colors: [Color(red: 0.16, green: 0.10, blue: 0.07), Color(red: 0.05, green: 0.03, blue: 0.03)]),
                                                 startPoint: CGPoint(x: w * 0.6, y: 0), endPoint: CGPoint(x: w, y: h)))
        var honeycomb = context
        honeycomb.clip(to: hull)
        let r = max(w, h) * 0.035
        let dx = r * sqrt(3.0), dy = r * 1.5
        var row = 0
        var y = 0.0
        while y < h + r {
            var x = (row % 2 == 0 ? 0 : dx / 2)
            while x < w + dx {
                var hex = Path()
                for k in 0..<6 {
                    let angle = Double(k) * .pi / 3 + .pi / 6
                    let p = CGPoint(x: x + r * cos(angle), y: y + r * sin(angle))
                    if k == 0 { hex.move(to: p) } else { hex.addLine(to: p) }
                }
                hex.closeSubpath()
                honeycomb.stroke(hex, with: .color(Color(red: 1.0, green: 0.55, blue: 0.2).opacity(0.18)), lineWidth: 1)
                x += dx
            }
            y += dy
            row += 1
        }
        context.stroke(hull, with: .color(Color(red: 1.0, green: 0.6, blue: 0.25).opacity(0.5)), lineWidth: 1.5)

        // Broken ground in the foreground.
        var ground = Path()
        ground.move(to: CGPoint(x: 0, y: h * 0.88))
        ground.addLine(to: CGPoint(x: w * 0.18, y: h * 0.82))
        ground.addLine(to: CGPoint(x: w * 0.34, y: h * 0.90))
        ground.addLine(to: CGPoint(x: w * 0.6, y: h * 0.84))
        ground.addLine(to: CGPoint(x: w, y: h * 0.92))
        ground.addLine(to: CGPoint(x: w, y: h))
        ground.addLine(to: CGPoint(x: 0, y: h))
        ground.closeSubpath()
        context.fill(ground, with: .color(Color(red: 0.06, green: 0.03, blue: 0.02)))
    }

    // MARK: Mass Effect 3

    private func drawLE3(_ context: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        fill(&context, size, [Color(red: 0.01, green: 0.02, blue: 0.05), Color(red: 0.06, green: 0.04, blue: 0.10), Color(red: 0.20, green: 0.04, blue: 0.03)])
        stars(&context, size, seed: 3, count: Int(w * h / 1100), tint: .red)

        // A world seen from orbit, its night side burning.
        planet(&context, size, centerX: w * 0.35, top: h * 0.45, radius: w * 1.1,
               body: [Color(red: 0.10, green: 0.22, blue: 0.40), Color(red: 0.05, green: 0.06, blue: 0.10)],
               rim: Color(red: 0.55, green: 0.80, blue: 1.0))
        var random = Seeded(state: 33)
        for _ in 0..<26 {
            let x = w * (0.05 + random.next() * 0.9)
            let y = h * (0.62 + random.next() * 0.38)
            glow(&context, at: CGPoint(x: x, y: y), radius: w * (0.03 + random.next() * 0.07), color: Color(red: 1.0, green: 0.35 + random.next() * 0.25, blue: 0.08).opacity(0.55))
        }

        // Falling streaks.
        for i in 0..<9 {
            let startX = w * (0.15 + Double(i) * 0.1 + random.next() * 0.05)
            let length = h * (0.35 + random.next() * 0.35)
            let start = CGPoint(x: startX, y: -h * 0.05)
            let end = CGPoint(x: startX - length * 0.35, y: length)
            var streak = Path()
            streak.move(to: start)
            streak.addLine(to: end)
            context.stroke(streak, with: .linearGradient(Gradient(colors: [Color.orange.opacity(0), Color(red: 1.0, green: 0.7, blue: 0.3).opacity(0.9)]), startPoint: start, endPoint: end),
                           style: StrokeStyle(lineWidth: 1.5 + random.next() * 2.5, lineCap: .round))
            glow(&context, at: end, radius: w * 0.025, color: Color(red: 1.0, green: 0.85, blue: 0.6))
        }
        glow(&context, at: CGPoint(x: w * 0.85, y: h * 0.15), radius: w * 0.3, color: Color(red: 0.8, green: 0.1, blue: 0.05).opacity(0.35))
    }
}

#Preview("Game art") {
    HStack(spacing: 12) {
        ForEach(LEGame.allCases) { game in
            GameArt(game: game).frame(width: 260, height: 300).clipShape(.rect(cornerRadius: 16))
        }
    }
    .padding()
    .background(.black)
}
