import AppKit

// Keep the original three-book identity, with selectable color treatments.
let root = URL(fileURLWithPath: "CWA/Assets.xcassets")
let palettes: [(String, String, String, String)] = [
    ("Books", "FFAA00", "F5750B", "FFFFFF"),
    ("Podcasts", "B968E6", "6625AC", "FFFFFF"),
    ("Music", "EE7084", "E53240", "FFFFFF"),
    ("Barbie", "F77DBC", "EE3098", "FFFFFF"),
    ("Monochrome", "FFFFFF", "E4E4E7", "141414"),
    ("Plex", "262626", "101010", "E7B300"),
    ("Telegram", "D780EB", "538FF5", "FFFFFF"),
    ("Warp", "FF8B45", "884ADF", "FFFFFF"),
    ("ATP", "3B3F41", "252728", "54C783")
]
func color(_ hex: String) -> NSColor {
    let value = Int(hex, radix: 16)!
    return NSColor(srgbRed: CGFloat((value >> 16) & 255)/255, green: CGFloat((value >> 8) & 255)/255, blue: CGFloat(value & 255)/255, alpha: 1)
}
func writeAsset(_ name: String, _ data: Data, icon: Bool) throws {
    let dir = root.appendingPathComponent(name + (icon ? ".appiconset" : ".imageset"))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try data.write(to: dir.appendingPathComponent("image.png"))
    var image: [String: Any] = ["filename": "image.png", "idiom": "universal"]
    if icon { image["platform"] = "ios"; image["size"] = "1024x1024" }
    let json: [String: Any] = ["images": [image], "info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: dir.appendingPathComponent("Contents.json"))
}
let original = try Data(contentsOf: root.appendingPathComponent("AppIcon.appiconset/AppIcon.png"))
try writeAsset("PreviewDefault", original, icon: false)
for (name, top, bottom, ink) in palettes {
    let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    NSGradient(starting: color(bottom), ending: color(top))!.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: 90)
    for (i, rect) in [NSRect(x: 215, y: 252, width: 152, height: 512), NSRect(x: 390, y: 252, width: 162, height: 557), NSRect(x: 590, y: 252, width: 162, height: 477)].enumerated() {
        (name == "ATP" ? [color("F4BA32"), color("E94861"), color("379EDD")][i] : color(ink)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 28, yRadius: 28).fill()
        color(bottom).withAlphaComponent(0.8).setFill()
        for y in [rect.minY + 58, rect.maxY - 79] {
            NSBezierPath(roundedRect: NSRect(x: rect.minX + 24, y: y, width: rect.width - 48, height: 19), xRadius: 9, yRadius: 9).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    let rendered = context.makeImage()!
    let bitmap = NSBitmapImageRep(cgImage: rendered)
    // Fail the build if drawing produced a blank image again.
    let background = bitmap.colorAt(x: 50, y: 50)!
    let book = bitmap.colorAt(x: 450, y: 500)!
    precondition(background != book, "Blank generated icon: \(name)")
    let png = bitmap.representation(using: .png, properties: [:])!
    try writeAsset(name, png, icon: true)
    try writeAsset("Preview" + name, png, icon: false)
}
print("Generated nine alternate CWA icons and ten previews.")

// Export a contact sheet for visual review of the exact generated image bytes.
let sheet = CGContext(data: nil, width: 1000, height: 420, bitsPerComponent: 8, bytesPerRow: 4000,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
sheet.setFillColor(CGColor(gray: 0.12, alpha: 1)); sheet.fill(CGRect(x: 0, y: 0, width: 1000, height: 420))
for (index, name) in (["Default"] + palettes.map { $0.0 }).enumerated() {
    let bytes = try Data(contentsOf: root.appendingPathComponent("Preview\(name).imageset/image.png"))
    let image = NSBitmapImageRep(data: bytes)!.cgImage!
    sheet.draw(image, in: CGRect(x: (index % 5) * 200 + 10, y: (1 - index / 5) * 210 + 15, width: 180, height: 180))
}
try NSBitmapImageRep(cgImage: sheet.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon-preview.png"))
