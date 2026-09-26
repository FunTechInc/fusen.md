// Renders the app icon (a yellow sticky on a white tile) to a 1024 px PNG.
// Used by scripts/make-icon.sh; run: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // The white tile: the macOS icon shape (824 px square, rounded, in the 1024 px canvas), so that
    // macOS does not put the icon on a gray tile of its own.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tileShape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    tileShadow.shadowBlurRadius = 20
    tileShadow.shadowOffset = NSSize(width: 0, height: -8)
    tileShadow.set()
    NSColor.white.setFill()
    tileShape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // The sticky, with a soft shadow on the tile.
    let inset: CGFloat = 232
    let paper = NSRect(x: inset, y: inset + 12, width: size - 2 * inset, height: size - 2 * inset)
    let fold: CGFloat = 104

    let shape = NSBezierPath()
    shape.move(to: NSPoint(x: paper.minX, y: paper.maxY))
    shape.line(to: NSPoint(x: paper.maxX, y: paper.maxY))
    shape.line(to: NSPoint(x: paper.maxX, y: paper.minY + fold))
    shape.line(to: NSPoint(x: paper.maxX - fold, y: paper.minY))
    shape.line(to: NSPoint(x: paper.minX, y: paper.minY))
    shape.close()

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor(srgbRed: 1.00, green: 0.93, blue: 0.45, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Folded corner.
    let corner = NSBezierPath()
    corner.move(to: NSPoint(x: paper.maxX, y: paper.minY + fold))
    corner.line(to: NSPoint(x: paper.maxX - fold, y: paper.minY + fold))
    corner.line(to: NSPoint(x: paper.maxX - fold, y: paper.minY))
    corner.close()
    NSColor(srgbRed: 0.93, green: 0.80, blue: 0.25, alpha: 1).setFill()
    corner.fill()

    // Top band like a Stickies title bar.
    NSColor(srgbRed: 0.98, green: 0.86, blue: 0.30, alpha: 1).setFill()
    NSRect(x: paper.minX, y: paper.maxY - 62, width: paper.width, height: 62).fill()
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not render icon")
}
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
