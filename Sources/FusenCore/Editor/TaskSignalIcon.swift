import AppKit

/// What a to-do shows in its marker column: Notion's checkbox (not started, done) or a signal —
///  * waiting (to be done next, before the other to-dos): the checkbox with a star in it, both amber;
///  * in progress: a ring as large as the checkbox and as faint as the app's dividers (so it sits on
///    every paper color), and on it a bold blue arc, which is what turns.
///
/// Everything here is in a coordinate system whose y axis points down, as in the (flipped) text view
/// and the layers above it. Sizes are for a 14-point icon and scale with it.
enum TaskSignalIcon {
    /// Which parts of the signal of a to-do in progress to draw: in a note the arc is a layer that turns
    /// (see TaskSpinnerOverlay), and only the ring under it is drawn with the text.
    enum Ring {
        case whole, track, arc
    }

    /// How much of the ink (the text color) the ring under the arc keeps: as much as a divider.
    static let ringAlpha: CGFloat = 0.16
    /// How far around the ring the arc reaches, from 12 o'clock clockwise.
    private static let arcSweep: CGFloat = 2 * .pi / 3

    /// In progress: how wide the ring and the arc on it are drawn.
    static func ringLineWidth(in rect: CGRect) -> CGFloat { rect.width * 2 / 14 }

    private static func ringRadius(in rect: CGRect) -> CGFloat { (rect.width - ringLineWidth(in: rect)) / 2 }

    /// The ring's centre line.
    static func ringPath(in rect: CGRect) -> CGPath {
        let radius = ringRadius(in: rect)
        return CGPath(ellipseIn: CGRect(x: rect.midX - radius, y: rect.midY - radius, width: 2 * radius, height: 2 * radius), transform: nil)
    }

    /// In progress: the arc's centre line; stroked as wide as the ring, with round caps.
    static func arcPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        // y points down, so growing angles go clockwise on screen.
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: ringRadius(in: rect),
                    startAngle: -.pi / 2, endAngle: -.pi / 2 + arcSweep, clockwise: false)
        return path
    }

    /// Waiting: the checkbox's square (its border's centre line, as `drawCheckbox` draws it)…
    static func boxPath(in rect: CGRect) -> CGPath {
        let unit = rect.width / 14
        return CGPath(roundedRect: rect.insetBy(dx: 0.65 * unit, dy: 0.65 * unit), cornerWidth: 2.5 * unit, cornerHeight: 2.5 * unit,
                      transform: nil)
    }

    /// …and the five-pointed star in it, a hair below the middle (where a star looks centred).
    static func starPath(in rect: CGRect) -> CGPath {
        let unit = rect.width / 14
        let center = CGPoint(x: rect.midX, y: rect.minY + 7.15 * unit), outer = 3.9 * unit, inner = outer * 0.46
        let path = CGMutablePath()
        for i in 0..<10 {
            // y points down: the first point is the top one.
            let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5, radius = i % 2 == 0 ? outer : inner
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    // MARK: Drawing

    /// Draws the checkbox or signal of `state` in `rect` (a square) of the current, flipped context.
    /// `ink` is the color of the empty checkbox and (fainter) of the ring under the arc — the text color,
    /// unless the paper is dark; `alpha` fades the whole icon.
    static func draw(_ state: TaskState, in rect: NSRect, theme: MarkdownTheme, ink: NSColor? = nil, alpha: CGFloat = 1,
                     ring: Ring = .whole) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let ink = ink ?? theme.textColor
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(alpha)
        func strokeRing() {
            context.addPath(ringPath(in: rect))
            context.setStrokeColor(ink.withAlphaComponent(ink.alphaComponent * ringAlpha).cgColor)
            context.setLineWidth(ringLineWidth(in: rect))
            context.strokePath()
        }
        switch state {
        case .todo, .done:
            drawCheckbox(checked: state == .done, in: rect, theme: theme, ink: ink)
        case .waiting:
            let unit = rect.width / 14
            context.setStrokeColor(theme.waitingColor.cgColor)
            context.setFillColor(theme.waitingColor.cgColor)
            context.addPath(boxPath(in: rect))
            context.setLineWidth(1.3 * unit) // the checkbox's border
            context.strokePath()
            // The star, filled and outlined with round corners, so that its points are not needle-sharp.
            context.setLineJoin(.round)
            context.setLineWidth(0.9 * unit)
            context.addPath(starPath(in: rect))
            context.drawPath(using: .fillStroke)
        case .doing:
            if ring != .arc { strokeRing() }
            if ring != .track {
                context.addPath(arcPath(in: rect))
                context.setStrokeColor(theme.doingColor.cgColor)
                context.setLineWidth(ringLineWidth(in: rect))
                context.setLineCap(.round)
                context.strokePath()
            }
        }
    }

    /// Notion's checkbox: a square with a 1.3px border; checked, a blue fill with a white check.
    private static func drawCheckbox(checked: Bool, in rect: NSRect, theme: MarkdownTheme, ink: NSColor) {
        let size = rect.width
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.65, dy: 0.65), xRadius: 2.5, yRadius: 2.5)
        if checked {
            theme.checkboxFill.setFill()
            path.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + size * 0.24, y: rect.minY + size * 0.52))
            check.line(to: NSPoint(x: rect.minX + size * 0.43, y: rect.minY + size * 0.70))
            check.line(to: NSPoint(x: rect.minX + size * 0.77, y: rect.minY + size * 0.32))
            check.lineWidth = 1.8
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            path.lineWidth = 1.3
            ink.setStroke()
            path.stroke()
        }
    }

    /// The icon as an image (menus, the note's buttons). `ink` as for `draw`; in a menu it is the label
    /// color, which follows the menu's light or dark look when the image is drawn.
    @MainActor
    static func image(_ state: TaskState, theme: MarkdownTheme, size: CGFloat? = nil, ink: NSColor? = nil, alpha: CGFloat = 1) -> NSImage {
        let side = size ?? theme.fontSize.rounded()
        return NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            draw(state, in: rect, theme: theme, ink: ink, alpha: alpha)
            return true
        }
    }
}
