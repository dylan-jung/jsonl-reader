// Generates Resources/AppIcon.icns. Run: swift Resources/make-icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a) }

    // macOS template: 824pt rounded square on a 1024 canvas, soft shadow, dark slate gradient + top sheen
    let shape = NSBezierPath(roundedRect: R(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    let shadow = NSShadow(); shadow.shadowBlurRadius = 20 * s; shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.set()
    hex(0x1E293B).setFill(); shape.fill()
    NSShadow().set()
    NSGradient(colors: [hex(0x334155), hex(0x1E293B), hex(0x0B1220)])!.draw(in: shape, angle: -60)
    NSGraphicsContext.saveGraphicsState(); shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!.draw(in: R(100, 512, 824, 412), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // { ≡ }: rounded braces around three records in the tree's syntax colors
    let glyphShadow = NSShadow(); glyphShadow.shadowBlurRadius = 12 * s; glyphShadow.shadowOffset = NSSize(width: 0, height: -6 * s)
    glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    let bold = NSFont.systemFont(ofSize: 480 * s, weight: .bold)
    let font = NSFont(descriptor: bold.fontDescriptor.withDesign(.rounded)!, size: 480 * s)!
    let brace: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: hex(0xE2E8F0), .shadow: glyphShadow]
    for (ch, cx) in [("{", 276.0), ("}", 748.0)] {
        let a = NSAttributedString(string: ch, attributes: brace), size = a.size()
        a.draw(at: NSPoint(x: cx * s - size.width / 2, y: 512 * s - size.height / 2 + 16 * s))
    }
    let barH: CGFloat = 54
    for (i, (color, w)) in [(hex(0x4ADE80), 240.0), (hex(0x60A5FA), 290.0), (hex(0xC084FC), 190.0)].enumerated() {
        let cy = 512 + 102 - CGFloat(i) * 102
        NSGraphicsContext.saveGraphicsState(); glyphShadow.set(); color.setFill()
        NSBezierPath(roundedRect: R(512 - w / 2, cy - barH / 2, w, barH), xRadius: barH / 2 * s, yRadius: barH / 2 * s).fill()
        NSGraphicsContext.restoreGraphicsState()
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
