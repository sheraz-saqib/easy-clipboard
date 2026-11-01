// Renders app icon + menu bar template icon: `swift icon.swift AppIcon.png MenuIcon.png`
import AppKit

func render(_ px: Int, to path: String, _ draw: () -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.current?.flushGraphics()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func rounded(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }

/// Two stacked, tilted cards with a dot. Designed in a 1000-unit box. gap == nil → punch transparent (template icon).
func drawGlyph(in box: NSRect, color: NSColor, gap: NSColor?) {
    let ctx = NSGraphicsContext.current!
    ctx.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: box.minX, yBy: box.minY); t.scale(by: box.width / 1000)
    t.translateX(by: 500, yBy: 500); t.rotate(byDegrees: -9); t.translateX(by: -500, yBy: -500)
    t.concat()

    func cut(_ p: NSBezierPath) {
        if let gap { gap.setFill(); p.fill() }
        else { ctx.compositingOperation = .clear; p.fill(); ctx.compositingOperation = .sourceOver }
    }
    let front = NSRect(x: 225, y: 315, width: 460, height: 460)
    color.setFill(); rounded(front.offsetBy(dx: 90, dy: -90), 120).fill()  // back card
    cut(rounded(front.insetBy(dx: -28, dy: -28), 148))                      // gap between cards
    color.setFill(); rounded(front, 120).fill()                              // front card
    cut(NSBezierPath(ovalIn: NSRect(x: front.minX + 75, y: front.maxY - 200, width: 125, height: 125)))
    ctx.restoreGraphicsState()
}

let ink = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1)

// App icon: white squircle (Apple grid: 824 body in 1024 canvas)
render(1024, to: CommandLine.arguments[1]) {
    let bg = rounded(NSRect(x: 100, y: 100, width: 824, height: 824), 185)
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow(); s.shadowColor = .black.withAlphaComponent(0.3); s.shadowBlurRadius = 28; s.shadowOffset = NSSize(width: 0, height: -10); s.set()
    NSColor.white.setFill(); bg.fill()
    NSGraphicsContext.restoreGraphicsState()
    drawGlyph(in: NSRect(x: 62, y: 62, width: 900, height: 900), color: ink, gap: .white)
}

// Menu bar: 18pt @2x template (black + transparent; macOS tints it for light/dark)
render(36, to: CommandLine.arguments[2]) {
    drawGlyph(in: NSRect(x: -7, y: -7, width: 50, height: 50), color: .black, gap: nil)
}
