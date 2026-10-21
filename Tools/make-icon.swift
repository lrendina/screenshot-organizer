// Renders the 1024px app icon: fanned screenshot cards on a gradient with a sparkle.
import AppKit
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let colors = [NSColor(red: 0.27, green: 0.36, blue: 0.98, alpha: 1).cgColor, NSColor(red: 0.62, green: 0.29, blue: 0.96, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
let tints: [NSColor] = [.systemGreen, .systemOrange, .white]
for (i, angle) in [-16.0, 0.0, 16.0].enumerated() {
    ctx.saveGState()
    ctx.translateBy(x: size / 2 + CGFloat(i - 1) * 120, y: size / 2 - 40)
    ctx.rotate(by: CGFloat(angle) * .pi / 180 * -1)
    let card = CGRect(x: -150, y: -310, width: 300, height: 620)
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: 46, cornerHeight: 46, transform: nil))
    ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0)
    // content bars
    ctx.setFillColor(tints[i].withAlphaComponent(i == 2 ? 0 : 0.85).cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: -110, y: 150, width: 220, height: 110), cornerWidth: 22, cornerHeight: 22, transform: nil)); ctx.fillPath()
    ctx.setFillColor(NSColor(white: 0.86, alpha: 1).cgColor)
    for row in 0..<4 { ctx.addPath(CGPath(roundedRect: CGRect(x: -110, y: 80 - CGFloat(row) * 60, width: row % 2 == 0 ? 220 : 160, height: 28), cornerWidth: 14, cornerHeight: 14, transform: nil)) }
    ctx.fillPath()
    ctx.restoreGState()
}
// sparkle
if let sparkle = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 260, weight: .bold)) {
    let tinted = NSImage(size: sparkle.size, flipped: false) { rect in
        sparkle.draw(in: rect); NSColor.systemYellow.set(); rect.fill(using: .sourceAtop); return true
    }
    tinted.draw(in: CGRect(x: 640, y: 690, width: tinted.size.width, height: tinted.size.height))
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
