import AppKit

/// Shows Markdown the way Notion does: syntax (`.mdMarker`, set by MarkdownStyler) is never shown, also
/// on the line being edited — "## " turns the line into a heading and disappears. (「Markdown記号をすべて
/// 表示」 turns concealing off to edit the raw text.) Concealed:
///  * a bullet ("- "), a to-do prefix ("- [ ] ") and a quote prefix ("> ") become a box (`.mdConcealBox`)
///    holding Notion's bullet (•, ◦, ▪ by depth), checkbox or quote bar, so their text starts at the
///    same place as a numbered item's;
///  * a thematic break ("---") becomes a thin line;
///  * other syntax (heading #, emphasis delimiters, link brackets and URLs, code backticks, escapes)
///    takes no space.
/// Fenced code blocks always get a full-width background. Only glyphs change, never characters, so
/// undo, IME composition and the exported Markdown are unaffected; ConcealedEditing keeps the caret
/// out of hidden syntax.
///
/// TextKit 1 on purpose: hiding characters needs glyph-level control (null and control glyphs), which
/// TextKit 2 does not offer.
final class ConcealingLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    let theme: MarkdownTheme
    /// When false, nothing is concealed (all Markdown shown as typed).
    var concealsMarkdown = true {
        didSet {
            guard concealsMarkdown != oldValue, let length = textStorage?.length else { return }
            invalidate(NSRange(location: 0, length: length))
        }
    }

    init(theme: MarkdownTheme) {
        self.theme = theme
        super.init()
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func isConcealed(at index: Int) -> Bool { concealsMarkdown }

    private func invalidate(_ range: NSRange) {
        guard let length = textStorage?.length else { return }
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        guard clipped.length > 0 else { return }
        invalidateGlyphs(forCharacterRange: clipped, changeInLength: 0, actualCharacterRange: nil)
        invalidateLayout(forCharacterRange: clipped, actualCharacterRange: nil)
        invalidateDisplay(forCharacterRange: clipped)
    }

    // MARK: Glyphs

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard concealsMarkdown, let storage = textStorage else { return 0 }
        let count = glyphRange.length
        let newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
        var newProps = Array(UnsafeBufferPointer(start: props, count: count))
        var changed = false
        for i in 0..<count {
            let index = charIndexes[i]
            guard index < storage.length, isConcealed(at: index),
                  storage.attribute(.mdMarker, at: index, effectiveRange: nil) != nil else { continue }
            if storage.attribute(.mdConcealBox, at: index, effectiveRange: nil) != nil {
                newProps[i] = .controlCharacter // sized and drawn below
            } else {
                newProps[i] = .null
            }
            changed = true
        }
        guard changed else { return 0 }
        newGlyphs.withUnsafeBufferPointer { g in
            newProps.withUnsafeBufferPointer { p in
                layoutManager.setGlyphs(g.baseAddress!, properties: p.baseAddress!, characterIndexes: charIndexes,
                                        font: aFont, forGlyphRange: glyphRange)
            }
        }
        return count
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard isConcealed(at: charIndex),
              textStorage?.attribute(.mdConcealBox, at: charIndex, effectiveRange: nil) != nil else { return action }
        return .whitespace
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
                       for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect,
                       glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let width = textStorage?.attribute(.mdConcealBox, at: charIndex, effectiveRange: nil) as? CGFloat ?? 0
        return NSRect(x: glyphPosition.x, y: 0, width: width, height: proposedRect.height)
    }

    // MARK: Drawing

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var codeRects: [NSRect] = []

        storage.enumerateAttribute(.mdLine, in: characters) { value, run, _ in
            guard let kind = (value as? String).flatMap(MarkdownLine.init) else { return }
            switch kind {
            case .code, .fence:
                forEachLineFragment(in: run) { rect, _ in
                    codeRects.append(rect.insetBy(dx: container.lineFragmentPadding, dy: 0))
                }
            case .rule where concealsMarkdown:
                forEachParagraph(in: run, storage) { paragraph in
                    guard isConcealed(at: paragraph.location), paragraph.length > 0 else { return }
                    // The "---" glyphs are null and may sit on the previous line fragment; the line
                    // belongs to the fragment of the paragraph's last character (its newline).
                    let last = glyphIndexForCharacter(at: NSMaxRange(paragraph) - 1)
                    let rect = lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
                    let line = NSRect(x: rect.minX + container.lineFragmentPadding, y: rect.midY.rounded(.down),
                                      width: rect.width - 2 * container.lineFragmentPadding, height: 1)
                    theme.dividerColor.setFill()
                    line.offsetBy(dx: origin.x, dy: origin.y).fill()
                }
            case .quote where concealsMarkdown:
                forEachParagraph(in: run, storage) { paragraph in
                    guard isConcealed(at: paragraph.location), let box = concealBox(in: paragraph, storage) else { return }
                    let barX = boxRect(forCharacterAt: box, in: container).minX
                    // Full line height, so consecutive quote lines make one bar, as in Notion.
                    forEachLineFragment(in: paragraph) { rect, _ in
                        let bar = NSRect(x: barX, y: rect.minY, width: 3, height: rect.height)
                        theme.textColor.setFill()
                        bar.offsetBy(dx: origin.x, dy: origin.y).fill()
                    }
                }
            default:
                break
            }
        }

        // One rounded background per run of adjacent code lines, spanning the full line width.
        var blocks: [NSRect] = []
        for rect in codeRects {
            if let last = blocks.last, abs(last.maxY - rect.minY) < 1 {
                blocks[blocks.count - 1] = last.union(rect)
            } else {
                blocks.append(rect)
            }
        }
        theme.codeBackground.setFill()
        for block in blocks {
            NSBezierPath(roundedRect: block.offsetBy(dx: origin.x, dy: origin.y), xRadius: 4, yRadius: 4).fill()
        }

        // Inline code: a rounded background as tall as the text, not the whole line.
        storage.enumerateAttribute(.mdInlineCode, in: characters) { value, run, _ in
            guard value != nil, let font = storage.attribute(.font, at: run.location, effectiveRange: nil) as? NSFont
            else { return }
            let runGlyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            var glyph = runGlyphs.location
            while glyph < NSMaxRange(runGlyphs) {
                var fragmentGlyphs = NSRange()
                let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragmentGlyphs)
                let piece = NSIntersectionRange(runGlyphs, fragmentGlyphs)
                guard piece.length > 0 else { break }
                let bounds = boundingRect(forGlyphRange: piece, in: container)
                let baseline = fragment.minY + location(forGlyphAt: piece.location).y
                let rect = NSRect(x: bounds.minX - 2, y: baseline - font.ascender - 1.5,
                                  width: bounds.width + 4, height: font.ascender - font.descender + 3)
                theme.codeBackground.setFill()
                NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y), xRadius: 3, yRadius: 3).fill()
                glyph = NSMaxRange(piece)
            }
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard concealsMarkdown, let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.mdConcealBox, in: characters) { value, run, _ in
            guard value != nil, isConcealed(at: run.location) else { return }
            let box = boxRect(forCharacterAt: run.location, in: container)
            let glyph = glyphIndexForCharacter(at: run.location)
            if let check = storage.attribute(.mdTaskToggle, at: run.location, effectiveRange: nil) as? Int,
               check < storage.length {
                let isChecked = (storage.string as NSString).character(at: check) != 0x20
                drawCheckbox(checked: isChecked, in: box, glyph: glyph, origin: origin)
            } else if let depth = storage.attribute(.mdBullet, at: run.location, effectiveRange: nil) as? Int {
                drawBullet(depth: depth, in: box, glyph: glyph, origin: origin)
            } else if let ordinal = storage.attribute(.mdOrdinal, at: run.location, effectiveRange: nil) as? String {
                drawOrdinal(ordinal, in: box, glyph: glyph, origin: origin)
            }
        }
    }

    /// The vertical centre of the first line's text (between the x-height and the cap height).
    private func textCenterY(glyph: Int) -> CGFloat {
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = fragment.minY + location(forGlyphAt: glyph).y
        let font = theme.bodyFont
        return baseline - (font.capHeight + font.xHeight) / 4
    }

    /// Notion's bullets: a disc, then a circle, then a square, centred in the marker column.
    private func drawBullet(depth: Int, in box: NSRect, glyph: Int, origin: NSPoint) {
        let size = (theme.fontSize * 0.36).rounded(.toNearestOrAwayFromZero)
        let center = NSPoint(x: box.minX + theme.listMarkerColumn / 2, y: textCenterY(glyph: glyph))
        let rect = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            .offsetBy(dx: origin.x, dy: origin.y)
        theme.textColor.set()
        switch depth % 3 {
        case 0:
            NSBezierPath(ovalIn: rect).fill()
        case 1:
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            circle.lineWidth = 1
            circle.stroke()
        default:
            NSBezierPath(rect: rect.insetBy(dx: 0.25, dy: 0.25)).fill()
        }
    }

    /// Notion's numbers: centred in the marker column (or at its start when wider), on the text's baseline.
    private func drawOrdinal(_ ordinal: String, in box: NSRect, glyph: Int, origin: NSPoint) {
        let font = theme.bodyFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.textColor]
        let width = (ordinal as NSString).size(withAttributes: attributes).width
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = fragment.minY + location(forGlyphAt: glyph).y
        let x = box.minX + max((theme.listMarkerColumn - width) / 2, 0)
        (ordinal as NSString).draw(at: NSPoint(x: x + origin.x, y: baseline - font.ascender + origin.y), withAttributes: attributes)
    }

    /// Notion's checkbox: 1em square with a 1.3px border, centred in the marker column; checked, a
    /// blue fill with a white check.
    private func drawCheckbox(checked: Bool, in box: NSRect, glyph: Int, origin: NSPoint) {
        let size = theme.fontSize.rounded()
        let centerY = textCenterY(glyph: glyph)
        let rect = NSRect(x: (box.minX + (theme.listMarkerColumn - size) / 2).rounded(), y: (centerY - size / 2).rounded(),
                          width: size, height: size)
            .offsetBy(dx: origin.x, dy: origin.y)
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
            theme.textColor.setStroke()
            path.stroke()
        }
    }

    // MARK: Geometry helpers

    private func boxRect(forCharacterAt index: Int, in container: NSTextContainer) -> NSRect {
        boundingRect(forGlyphRange: NSRange(location: glyphIndexForCharacter(at: index), length: 1), in: container)
    }

    private func concealBox(in paragraph: NSRange, _ storage: NSTextStorage) -> Int? {
        var found: Int?
        storage.enumerateAttribute(.mdConcealBox, in: paragraph) { value, run, stop in
            if value != nil { found = run.location; stop.pointee = true }
        }
        return found
    }

    private func forEachParagraph(in range: NSRange, _ storage: NSTextStorage, _ body: (NSRange) -> Void) {
        let ns = storage.string as NSString
        var location = range.location
        while location < NSMaxRange(range) {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            body(paragraph)
            location = NSMaxRange(paragraph)
        }
    }

    private func forEachLineFragment(in characters: NSRange, _ body: (_ rect: NSRect, _ used: NSRect) -> Void) {
        let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        // The block is imported as escaping but only runs during this call.
        withoutActuallyEscaping(body) { body in
            enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, _, _ in body(rect, used) }
        }
    }
}
