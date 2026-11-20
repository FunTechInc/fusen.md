import AppKit

/// What a to-do shows in its marker column: Notion's checkbox (not started, done) or a signal. The two
/// signals are a pair: the same ring, as large as the checkbox and as faint as the app's dividers (so it
/// sits on every paper color), and on it one mark in the signal's color —
///  * waiting: a pause mark in the middle of the ring;
///  * in progress: a bold arc on the ring, which is what turns.
///
/// Everything here is in a coordinate system whose y axis points down, as in the (flipped) text view
/// and the layers above it. Sizes are for a 14-point icon and scale with it.
enum TaskSignalIcon {
    /// Which parts of the signal of a to-do in progress to draw: in a note the arc is a layer that turns
    /// (see TaskSpinnerOverlay), and only the ring under it is drawn with the text.
    enum Ring {
        case whole, track, arc
    }

    /// How much of the ink (the text color) the ring keeps: as much as a divider.
    static let ringAlpha: CGFloat = 0.16
    /// How far around the ring the arc reaches, from 12 o'clock clockwise.
    private static let arcSweep: CGFloat = 2 * .pi / 3

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

    /// Waiting: the pause mark, two bars with round ends in the middle of the ring.
    static func pauseBarsPath(in rect: CGRect) -> CGPath {
        let unit = rect.width / 14
        let width = 2.4 * unit, height = 6.6 * unit, gap = 2.2 * unit
        let path = CGMutablePath()
        for x in [rect.midX - gap / 2 - width, rect.midX + gap / 2] {
            path.addRoundedRect(in: CGRect(x: x, y: rect.midY - height / 2, width: width, height: height),
                                cornerWidth: width / 2, cornerHeight: width / 2)
        }
        return path
    }

    // MARK: Drawing

    /// Draws the checkbox or signal of `state` in `rect` (a square) of the current, flipped context.
    /// `ink` is the color of the empty checkbox and (fainter) of a signal's ring — the text color, unless
    /// the paper is dark; `alpha` fades the whole icon.
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
            strokeRing()
            context.addPath(pauseBarsPath(in: rect))
            context.setFillColor(theme.waitingColor.cgColor)
            context.fillPath()
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
