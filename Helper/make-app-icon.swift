import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt rounded square centred in 1024.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.5).cgColor)
ctx.addPath(tilePath)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

// Deep space background.
let space = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(red: 0.03, green: 0.05, blue: 0.12, alpha: 1).cgColor,
    NSColor(red: 0.07, green: 0.09, blue: 0.22, alpha: 1).cgColor,
    NSColor(red: 0.16, green: 0.04, blue: 0.08, alpha: 1).cgColor,
] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(space, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])

// Stars (deterministic).
var seed: UInt64 = 0x5EED
func rand() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1) }
for _ in 0..<220 {
    let x = tile.minX + rand() * tile.width, y = tile.minY + rand() * tile.height
    let r = 0.6 + rand() * 2.2
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.25 + rand() * 0.6).cgColor)
    ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
}

let center = CGPoint(x: size / 2, y: size / 2 + 70)

// Galaxy-map orbit rings.
ctx.setLineWidth(3)
for (i, radius) in [210.0, 290.0, 370.0].enumerated() {
    ctx.setStrokeColor(NSColor(red: 0.4, green: 0.7, blue: 1, alpha: 0.10 + 0.04 * CGFloat(i)).cgColor)
    ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius * 0.42, width: radius * 2, height: radius * 0.84))
}

// Core glow.
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(red: 0.75, green: 0.92, blue: 1, alpha: 1).cgColor,
    NSColor(red: 0.25, green: 0.6, blue: 1, alpha: 0.75).cgColor,
    NSColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 0).cgColor,
] as CFArray, locations: [0, 0.25, 1])!
ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 230, options: [])

// Relay arms: two tapered prongs rising from a hub below the core, tips apart.
func blade(flip: CGFloat) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: center.x - 60 * flip, y: center.y - 300))
    p.addCurve(to: CGPoint(x: center.x - 190 * flip, y: center.y + 330),
               control1: CGPoint(x: center.x - 360 * flip, y: center.y - 210),
               control2: CGPoint(x: center.x - 340 * flip, y: center.y + 210))
    p.addCurve(to: CGPoint(x: center.x - 12 * flip, y: center.y - 300),
               control1: CGPoint(x: center.x - 255 * flip, y: center.y + 170),
               control2: CGPoint(x: center.x - 250 * flip, y: center.y - 190))
    p.closeSubpath()
    ctx.saveGState()
    ctx.addPath(p)
    ctx.clip()
    let metal = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(white: 0.95, alpha: 1).cgColor,
        NSColor(white: 0.6, alpha: 1).cgColor,
        NSColor(white: 0.28, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(metal, start: CGPoint(x: center.x - 200 * flip, y: center.y + 330), end: CGPoint(x: center.x, y: center.y - 300), options: [])
    ctx.restoreGState()
    ctx.addPath(p)
    ctx.setStrokeColor(NSColor(red: 0.6, green: 0.85, blue: 1, alpha: 0.75).cgColor)
    ctx.setLineWidth(3)
    ctx.strokePath()
}
blade(flip: 1)
blade(flip: -1)

// Hub joining the prongs.
let hub = CGRect(x: center.x - 80, y: center.y - 330, width: 160, height: 56)
ctx.addPath(CGPath(roundedRect: hub, cornerWidth: 22, cornerHeight: 22, transform: nil))
ctx.setFillColor(NSColor(white: 0.45, alpha: 1).cgColor)
ctx.fillPath()
ctx.addPath(CGPath(roundedRect: hub, cornerWidth: 22, cornerHeight: 22, transform: nil))
ctx.setStrokeColor(NSColor(red: 0.6, green: 0.85, blue: 1, alpha: 0.75).cgColor)
ctx.setLineWidth(3)
ctx.strokePath()

// Bright core.
ctx.setFillColor(NSColor(red: 0.9, green: 0.97, blue: 1, alpha: 1).cgColor)
ctx.fillEllipse(in: CGRect(x: center.x - 30, y: center.y - 30, width: 60, height: 60))

// N7-style stripe across the lower third: red band, thin white band, short red tail.
func slanted(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x + h * 0.6, y: y + h))
    p.addLine(to: CGPoint(x: x + w + h * 0.6, y: y + h))
    p.addLine(to: CGPoint(x: x + w, y: y))
    p.addLine(to: CGPoint(x: x, y: y))
    p.closeSubpath()
    ctx.addPath(p)
    ctx.setFillColor(color.cgColor)
    ctx.fillPath()
}
let stripeY = tile.minY + 120
slanted(tile.minX - 40, stripeY, 520, 54, NSColor(red: 0.82, green: 0.11, blue: 0.18, alpha: 1))
slanted(tile.minX + 505, stripeY, 46, 54, NSColor(white: 0.95, alpha: 1))
slanted(tile.minX + 570, stripeY, 330, 54, NSColor(red: 0.82, green: 0.11, blue: 0.18, alpha: 0.65))

ctx.restoreGState()

// Subtle tile edge highlight.
ctx.addPath(tilePath)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
ctx.setLineWidth(4)
ctx.strokePath()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
