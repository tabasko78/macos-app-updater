// Dessine l'icône 1024 px aux couleurs violine : swift outils/icone.swift <sortie.png>
import AppKit

func couleur(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let cadre = NSRect(x: 100, y: 100, width: 824, height: 824)
NSBezierPath(roundedRect: cadre, xRadius: 185, yRadius: 185).addClip()
NSGradient(colors: [couleur(0x1d1340), couleur(0x0f0a1e)])!.draw(in: cadre, angle: -90)
for (hex, a, x, y, r) in [(0xa78bfa, 0.55, 230.0, 900.0, 620.0), (0xff7ac6, 0.40, 900.0, 820.0, 520.0), (0x67e8f9, 0.25, 512.0, 60.0, 560.0)] {
    let c = NSPoint(x: x, y: y)
    NSGradient(colors: [couleur(UInt32(hex), a), couleur(UInt32(hex), 0)])!.draw(fromCenter: c, radius: 0, toCenter: c, radius: r, options: [])
}

let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    .applying(.init(paletteColors: [couleur(0x0f0a1e), couleur(0xece7fb)]))
if let s = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let t = s.size
    s.draw(in: NSRect(x: 512 - t.width / 2, y: 512 - t.height / 2, width: t.width, height: t.height))
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
