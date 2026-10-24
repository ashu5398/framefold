// Draws the FrameFold app icon into an .iconset folder: swift make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // macOS icon grid: 824 pt body centred in 1024 with a soft shadow.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSGradient(colors: [NSColor(red: 0.13, green: 0.47, blue: 1, alpha: 1), NSColor(red: 0.45, green: 0.3, blue: 0.95, alpha: 1)])!
        .draw(in: shape, angle: -60)
    NSGraphicsContext.restoreGraphicsState()

    // Three fanned photo frames, folding into each other.
    let colors: [NSColor] = [
        NSColor.white.withAlphaComponent(0.45),
        NSColor.white.withAlphaComponent(0.7),
        NSColor.white,
    ]
    let angles: [CGFloat] = [-16, -6, 5]
    for (i, angle) in angles.enumerated() {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: 512 * s, yBy: 500 * s)
        transform.rotate(byDegrees: angle)
        transform.concat()
        let frame = NSRect(x: -230 * s, y: -190 * s, width: 460 * s, height: 380 * s)
        let card = NSBezierPath(roundedRect: frame, xRadius: 38 * s, yRadius: 38 * s)
        let cardShadow = NSShadow()
        cardShadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        cardShadow.shadowBlurRadius = 18 * s
        cardShadow.shadowOffset = NSSize(width: 0, height: -6 * s)
        cardShadow.set()
        colors[i].setFill()
        card.fill()
        if i == angles.count - 1 {
            NSShadow().set()
            // Photo: sun and mountains.
            let inner = frame.insetBy(dx: 30 * s, dy: 30 * s)
            let clip = NSBezierPath(roundedRect: inner, xRadius: 18 * s, yRadius: 18 * s)
            clip.addClip()
            NSGradient(colors: [NSColor(red: 0.62, green: 0.82, blue: 1, alpha: 1), NSColor(red: 0.85, green: 0.93, blue: 1, alpha: 1)])!
                .draw(in: inner, angle: 90)
            NSColor(red: 1, green: 0.78, blue: 0.2, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: inner.maxX - 130 * s, y: inner.maxY - 120 * s, width: 70 * s, height: 70 * s)).fill()
            let mountains = NSBezierPath()
            mountains.move(to: NSPoint(x: inner.minX, y: inner.minY))
            mountains.line(to: NSPoint(x: inner.minX + 120 * s, y: inner.minY + 170 * s))
            mountains.line(to: NSPoint(x: inner.minX + 210 * s, y: inner.minY + 80 * s))
            mountains.line(to: NSPoint(x: inner.minX + 290 * s, y: inner.minY + 200 * s))
            mountains.line(to: NSPoint(x: inner.maxX, y: inner.minY + 40 * s))
            mountains.line(to: NSPoint(x: inner.maxX, y: inner.minY))
            mountains.close()
            NSColor(red: 0.2, green: 0.55, blue: 0.35, alpha: 1).setFill()
            mountains.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(px).write(to: out.appendingPathComponent(name))
    }
}
print(out.path)
