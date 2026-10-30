// Draws Fleet's app icon from its menu-bar glyph: swift make-icon.swift [out.icns]
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Fleet.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // Apple's macOS icon grid: an 824 pt tile with a 185 pt corner, centred on a 1024 canvas.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.25, blue: 0.28, alpha: 1),
               ending: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1))!.draw(in: shape, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: 400 * s, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    let plane = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    let size = plane.size
    plane.draw(in: NSRect(x: (CGFloat(px) - size.width) / 2, y: (CGFloat(px) - size.height) / 2,
                          width: size.width, height: size.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for pt in [16, 32, 128, 256, 512] {
    try! png(pt).write(to: tmp.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try! png(pt * 2).write(to: tmp.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", out]
try! p.run()
p.waitUntilExit()
exit(p.terminationStatus)
