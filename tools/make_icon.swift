import Cocoa

// paster icon: rounded teal gradient + stacked clipboard cards glyph.

let out = CommandLine.arguments[1]
for s in [16, 32, 64, 128, 256, 512, 1024] {
    let f = CGFloat(s)
    let img = NSImage(size: NSSize(width: f, height: f))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { continue }

    let r = CGRect(x: f*0.03, y: f*0.03, width: f*0.94, height: f*0.94)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: f*0.22, cornerHeight: f*0.22,
                       transform: nil))
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red: 0.05, green: 0.75, blue: 0.75, alpha: 1),
                 CGColor(red: 0.1, green: 0.45, blue: 0.95, alpha: 1)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: f, y: f), options: [])
    ctx.restoreGState()

    // two stacked "cards" (clipboard history metaphor)
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.35))
    let back = CGRect(x: f*0.32, y: f*0.22, width: f*0.42, height: f*0.5)
    ctx.addPath(CGPath(roundedRect: back, cornerWidth: f*0.05, cornerHeight: f*0.05, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.95))
    let front = CGRect(x: f*0.24, y: f*0.16, width: f*0.42, height: f*0.5)
    ctx.addPath(CGPath(roundedRect: front, cornerWidth: f*0.05, cornerHeight: f*0.05, transform: nil))
    ctx.fillPath()
    // text lines on front card
    ctx.setFillColor(CGColor(red: 0.1, green: 0.45, blue: 0.7, alpha: 1))
    for i in 0..<3 {
        let ly = front.maxY - f*0.1 - CGFloat(i) * f*0.09
        ctx.fill(CGRect(x: front.minX + f*0.06, y: ly,
                        width: front.width - f*0.12 - CGFloat(i)*f*0.06, height: f*0.035))
    }

    img.unlockFocus()
    if let t = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: t),
       let png = rep.representation(using: .png, properties: [:]) {
        let name = s == 1024 ? "icon_512x512@2x.png" : "icon_\(s)x\(s).png"
        try? png.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    }
}
