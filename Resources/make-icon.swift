// Generates Resources/AppIcon.icns. Run: swift Resources/make-icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // macOS template: 824pt rounded square on a 1024 canvas, soft shadow
    let box = R(100, 100, 824, 824)
    let shadow = NSShadow(); shadow.shadowBlurRadius = 24 * s; shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25); shadow.set()
    let bg = NSBezierPath(roundedRect: box, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(white: 0.99, alpha: 1), ending: NSColor(white: 0.93, alpha: 1))!.draw(in: bg, angle: -90)
    NSShadow().set()

    // four JSON records, one per line:  {  key  :  value  }
    let ink = NSColor(red: 0.16, green: 0.18, blue: 0.24, alpha: 1)
    let keyGray = NSColor(red: 0.62, green: 0.65, blue: 0.70, alpha: 1)
    let values: [(NSColor, CGFloat)] = [(.systemGreen, 190), (.systemBlue, 130), (.systemPurple, 160), (.systemOrange, 110)]
    let font = NSFont.monospacedSystemFont(ofSize: 150 * s, weight: .bold)
    let brace: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
    let rowH: CGFloat = 150, top: CGFloat = 700, x0: CGFloat = 200, barH: CGFloat = 56
    for (i, (color, w)) in values.enumerated() {
        let cy = top - CGFloat(i) * rowH
        var x = x0
        let open = NSAttributedString(string: "{", attributes: brace)
        open.draw(at: NSPoint(x: x * s, y: cy * s - open.size().height / 2)); x += 110
        keyGray.setFill(); NSBezierPath(roundedRect: R(x, cy - barH / 2, 150, barH), xRadius: barH / 2 * s, yRadius: barH / 2 * s).fill(); x += 150 + 30
        ink.setFill(); NSBezierPath(ovalIn: R(x, cy + 8, 22, 22)).fill(); NSBezierPath(ovalIn: R(x, cy - 30, 22, 22)).fill(); x += 22 + 30
        color.setFill(); NSBezierPath(roundedRect: R(x, cy - barH / 2, w, barH), xRadius: barH / 2 * s, yRadius: barH / 2 * s).fill(); x += w + 20
        let close = NSAttributedString(string: "}", attributes: brace)
        close.draw(at: NSPoint(x: x * s, y: cy * s - close.size().height / 2))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(name).png"))
}
print("iconset written")
