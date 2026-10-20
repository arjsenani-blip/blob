// Renders the app icon: white brain on the violet→pink brand gradient.
// Usage: swift scripts/make_icon.swift <output-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func render(size: CGFloat, inset: CGFloat, corner: CGFloat, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

    if inset > 0 {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = size * 0.03
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
        shadow.set()
        NSColor.black.setFill()
        path.fill()
    }
    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    let gradient = NSGradient(colors: [
        NSColor(red: 0.40, green: 0.30, blue: 0.98, alpha: 1),
        NSColor(red: 0.62, green: 0.33, blue: 0.95, alpha: 1),
        NSColor(red: 1.0, green: 0.40, blue: 0.62, alpha: 1),
    ])!
    gradient.draw(in: rect, angle: -50)
    // Soft highlight
    NSColor.white.withAlphaComponent(0.12).setFill()
    NSBezierPath(ovalIn: NSRect(x: rect.minX - rect.width * 0.2, y: rect.midY, width: rect.width * 1.1, height: rect.height * 0.9)).fill()

    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.52, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let s = symbol.size
        let r = NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height)
        let glow = NSShadow()
        glow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        glow.shadowBlurRadius = size * 0.02
        glow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
        glow.set()
        symbol.draw(in: r)
    }
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// macOS icons have transparent padding and their own rounded shape; iOS icons are full-bleed squares.
render(size: 1024, inset: 100, corner: 185, to: out.appendingPathComponent("mac-1024.png"))
render(size: 1024, inset: 0, corner: 0, to: out.appendingPathComponent("ios-1024.png"))
print("ok")
