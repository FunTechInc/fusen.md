// Renders the app icon (a yellow sticky with the Markdown mark) to a 1024 px PNG.
// Used by scripts/make-icon.sh; run: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // Paper with a soft shadow, inside the standard macOS icon grid (~80% of the canvas).
    let inset: CGFloat = 100
    let paper = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let fold: CGFloat = 150

    let shape = NSBezierPath()
    shape.move(to: NSPoint(x: paper.minX, y: paper.maxY))
    shape.line(to: NSPoint(x: paper.maxX, y: paper.maxY))
    shape.line(to: NSPoint(x: paper.maxX, y: paper.minY + fold))
    shape.line(to: NSPoint(x: paper.maxX - fold, y: paper.minY))
    shape.line(to: NSPoint(x: paper.minX, y: paper.minY))
    shape.close()

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -14)
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
    NSRect(x: paper.minX, y: paper.maxY - 90, width: paper.width, height: 90).fill()

    // Markdown mark: "M" and a down arrow.
    let ink = NSColor(white: 0.18, alpha: 1)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 360, weight: .heavy),
        .foregroundColor: ink,
    ]
    let m = NSAttributedString(string: "M", attributes: attributes)
    let mSize = m.size()
    let baseY = paper.midY - mSize.height / 2 - 40
    m.draw(at: NSPoint(x: paper.minX + 140, y: baseY))

    let arrowX = paper.minX + 140 + mSize.width + 130
    let arrowTop = baseY + mSize.height * 0.78
    let arrowBottom = baseY + mSize.height * 0.2
    let arrow = NSBezierPath()
    arrow.lineWidth = 56
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: arrowX, y: arrowTop))
    arrow.line(to: NSPoint(x: arrowX, y: arrowBottom))
    arrow.move(to: NSPoint(x: arrowX - 80, y: arrowBottom + 80))
    arrow.line(to: NSPoint(x: arrowX, y: arrowBottom))
    arrow.line(to: NSPoint(x: arrowX + 80, y: arrowBottom + 80))
    ink.setStroke()
    arrow.stroke()
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not render icon")
}
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
