import AppKit

/// What a to-do shows in its marker column: Notion's checkbox (not started, done) or a signal — a
/// pause mark (waiting) or a ring open over its top-left quarter (in progress). The signals follow the
/// Figma, where they are drawn on a 19-unit square: two bars 6 wide, and a ring 2.66 thick.
///
/// Everything here is in a coordinate system whose y axis points down, as in the (flipped) text view
/// and the layers above it.
enum TaskSignalIcon {
    static func ringLineWidth(in rect: CGRect) -> CGFloat { rect.width * 2.66 / 19 }

    /// The ring's centre line, from 12 o'clock clockwise to 9 o'clock; stroked with butt caps.
    static func ringPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        // y points down, so growing angles go clockwise on screen.
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: (rect.width - ringLineWidth(in: rect)) / 2,
                    startAngle: -.pi / 2, endAngle: .pi, clockwise: false)
        return path
    }

    static func pausePath(in rect: CGRect) -> CGPath {
        let bar = rect.width * 6 / 19
        let path = CGMutablePath()
        path.addRect(CGRect(x: rect.minX, y: rect.minY, width: bar, height: rect.height))
        path.addRect(CGRect(x: rect.maxX - bar, y: rect.minY, width: bar, height: rect.height))
        return path
    }

    /// Draws the checkbox or signal of `state` in `rect` (a square) of the current, flipped context.
    /// `ink` is the color of the empty checkbox (the text color); `alpha` fades the whole icon.
    static func draw(_ state: TaskState, in rect: NSRect, theme: MarkdownTheme, ink: NSColor? = nil, alpha: CGFloat = 1) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(alpha)
        switch state {
        case .todo, .done:
            drawCheckbox(checked: state == .done, in: rect, theme: theme, ink: ink ?? theme.textColor)
        case .waiting:
            context.addPath(pausePath(in: rect))
            context.setFillColor(theme.waitingColor.cgColor)
            context.fillPath()
        case .doing:
            context.addPath(ringPath(in: rect))
            context.setStrokeColor(theme.doingColor.cgColor)
            context.setLineWidth(ringLineWidth(in: rect))
            context.setLineCap(.butt)
            context.strokePath()
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

    /// The icon as an image (menus, the note's buttons).
    @MainActor
    static func image(_ state: TaskState, theme: MarkdownTheme, size: CGFloat? = nil, alpha: CGFloat = 1) -> NSImage {
        let side = size ?? theme.fontSize.rounded()
        return NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            draw(state, in: rect, theme: theme, alpha: alpha)
            return true
        }
    }
}
