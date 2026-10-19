import Cocoa

// Generates AppIcon.iconset PNGs: rounded blue gradient with a
// viewfinder bracket glyph. Usage: swift make_icon.swift <outdir>

let outdir = CommandLine.arguments[1]
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in sizes {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // Rounded-rect gradient background (blue → cyan), macOS icon shape.
    let inset = s * 0.02
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = s * 0.22
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [CGColor(red: 0.15, green: 0.45, blue: 0.95, alpha: 1),
                  CGColor(red: 0.10, green: 0.75, blue: 0.90, alpha: 1)]
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.restoreGState()

    // Viewfinder brackets: white strokes at 4 corners.
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.setLineWidth(max(1, s * 0.06))
    ctx.setLineCap(.round)
    let arm = s * 0.18, m = s * 0.22
    let corners: [(CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: m, y: m + arm), CGPoint(x: m, y: m), CGPoint(x: m + arm, y: m)),
        (CGPoint(x: s - m - arm, y: m), CGPoint(x: s - m, y: m), CGPoint(x: s - m, y: m + arm)),
        (CGPoint(x: m, y: s - m - arm), CGPoint(x: m, y: s - m), CGPoint(x: m + arm, y: s - m)),
        (CGPoint(x: s - m - arm, y: s - m), CGPoint(x: s - m, y: s - m), CGPoint(x: s - m, y: s - m - arm)),
    ]
    for (a, c, b) in corners {
        ctx.move(to: a); ctx.addLine(to: c); ctx.addLine(to: b)
        ctx.strokePath()
    }
    // Center dot.
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.fillEllipse(in: CGRect(x: s / 2 - s * 0.05, y: s / 2 - s * 0.05,
                               width: s * 0.10, height: s * 0.10))

    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(outdir)/\(name).png"))
}
print("iconset written to \(outdir)")
