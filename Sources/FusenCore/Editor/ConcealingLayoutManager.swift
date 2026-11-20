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

    /// Set by a text view that shows the arcs of the to-dos in progress itself, turning (see
    /// TaskSpinnerOverlay). Otherwise the arcs are drawn here, still, with their rings.
    var doingTasksAreAnimated = false {
        didSet {
            guard doingTasksAreAnimated != oldValue, let length = textStorage?.length else { return }
            invalidateDisplay(forCharacterRange: NSRange(location: 0, length: length))
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

    /// The lines around a row of cards show nothing when the Markdown is concealed: they take no height.
    /// A card's closing line is only the space under its text then; with the Markdown shown it gets the
    /// room its ":::" needs to stand inside the card. A card at the very start keeps the space above it.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = textStorage, glyphRange.length > 0 else { return false }
        let character = characterIndexForGlyph(at: glyphRange.location)
        guard character < storage.length else { return false }
        let kind = lineKind(at: character)
        if concealsMarkdown, kind == .rowOpen || kind == .rowClose {
            lineFragmentRect.pointee.size.height = 0
            lineFragmentUsedRect.pointee.size.height = 0
            baselineOffset.pointee = 0
            return true
        }
        // TextKit leaves out the space before the first paragraph of the text: a card that the note starts
        // with would lose the top of its frame, and its title would stick out above it.
        if kind == .cardOpen, character == 0,
           let style = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
            let missing = style.paragraphSpacingBefore - (lineFragmentUsedRect.pointee.minY - lineFragmentRect.pointee.minY)
            if missing > 0.5 {
                lineFragmentRect.pointee.size.height += missing
                lineFragmentUsedRect.pointee.origin.y += missing
                baselineOffset.pointee += missing
                return true
            }
        }
        if !concealsMarkdown, kind == .cardClose {
            let room = (theme.fontSize * 0.7).rounded()
            lineFragmentRect.pointee.size.height += room
            lineFragmentUsedRect.pointee.size.height += room
            baselineOffset.pointee += room - theme.cardGap - 2 // above the card's lower edge
            return true
        }
        return false
    }

    // MARK: Drawing

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // The cards first: they are opaque, and TextKit draws the selection (and the background of text
        // being composed) here, which has to show on them.
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        drawCards(in: characters, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        var codeRects: [(rect: NSRect, fade: CGFloat)] = []

        storage.enumerateAttribute(.mdLine, in: characters) { value, run, _ in
            guard let kind = (value as? String).flatMap(MarkdownLine.init) else { return }
            switch kind {
            case .code, .fence:
                forEachParagraph(in: run, storage) { paragraph in
                    let fade = fade(at: paragraph.location)
                    let inset = container.lineFragmentPadding + blockInset(at: paragraph.location)
                    forEachLineFragment(in: NSIntersectionRange(paragraph, run)) { rect, _ in
                        codeRects.append((rect.insetBy(dx: inset, dy: 0), fade))
                    }
                }
            case .rule where concealsMarkdown:
                forEachParagraph(in: run, storage) { paragraph in
                    guard isConcealed(at: paragraph.location), paragraph.length > 0 else { return }
                    // The "---" glyphs are null and may sit on the previous line fragment; the line
                    // belongs to the fragment of the paragraph's last character (its newline).
                    let last = glyphIndexForCharacter(at: NSMaxRange(paragraph) - 1)
                    let rect = lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
                    let inset = container.lineFragmentPadding + blockInset(at: paragraph.location)
                    let line = NSRect(x: rect.minX + inset, y: rect.midY.rounded(.down), width: rect.width - 2 * inset, height: 1)
                    // The divider's faintness, of the paragraph's ink (white on the darkened paper of 強調表示).
                    let ink = tone(at: paragraph.location)
                    ink.withAlphaComponent(ink.alphaComponent * theme.dividerColor.alphaComponent).setFill()
                    line.offsetBy(dx: origin.x, dy: origin.y).fill()
                }
            case .quote where concealsMarkdown:
                forEachParagraph(in: run, storage) { paragraph in
                    guard isConcealed(at: paragraph.location), let box = concealBox(in: paragraph, storage) else { return }
                    let barX = boxRect(forCharacterAt: box, in: container).minX
                    // Full line height, so consecutive quote lines make one bar, as in Notion.
                    forEachLineFragment(in: paragraph) { rect, _ in
                        let bar = NSRect(x: barX, y: rect.minY, width: 3, height: rect.height)
                        tone(at: paragraph.location).setFill()
                        bar.offsetBy(dx: origin.x, dy: origin.y).fill()
                    }
                }
            default:
                break
            }
        }

        // One rounded background per run of adjacent code lines, spanning the full line width.
        var blocks: [(rect: NSRect, fade: CGFloat)] = []
        for code in codeRects {
            if let last = blocks.last, abs(last.rect.maxY - code.rect.minY) < 1, last.fade == code.fade {
                blocks[blocks.count - 1].rect = last.rect.union(code.rect)
            } else {
                blocks.append(code)
            }
        }
        for block in blocks {
            theme.codeBackground.withAlphaComponent(theme.codeBackground.alphaComponent * block.fade).setFill()
            NSBezierPath(roundedRect: block.rect.offsetBy(dx: origin.x, dy: origin.y), xRadius: 4, yRadius: 4).fill()
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
                tone(theme.codeBackground, at: run.location).setFill()
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
            if storage.attribute(.mdTaskToggle, at: run.location, effectiveRange: nil) != nil {
                let state = MarkdownStyler.taskState(at: run.location, in: storage) ?? .todo
                guard let rect = taskIconRect(forCharacterAt: run.location) else { return }
                // An arc that turns is the text view's (see TaskSpinnerOverlay): here only the track under it.
                TaskSignalIcon.draw(state, in: rect.offsetBy(dx: origin.x, dy: origin.y), theme: theme,
                                    ink: storage.attribute(.mdInk, at: run.location, effectiveRange: nil) as? NSColor,
                                    alpha: fade(at: run.location), ring: doingTasksAreAnimated ? .track : .whole)
            } else if let depth = storage.attribute(.mdBullet, at: run.location, effectiveRange: nil) as? Int {
                drawBullet(depth: depth, in: box, glyph: glyph, origin: origin, color: tone(at: run.location))
            } else if let ordinal = storage.attribute(.mdOrdinal, at: run.location, effectiveRange: nil) as? String {
                drawOrdinal(ordinal, in: box, glyph: glyph, origin: origin, color: tone(at: run.location))
            }
        }
    }

    // MARK: Cards

    /// Where the parts of a card are, in the container's coordinates. Everything follows from where the
    /// card's lines were laid out: the opening line holds the top of the card and the title, the closing
    /// line the card's bottom, and the lines between them are its text.
    struct CardGeometry {
        /// The card's characters: its opening line through its closing line.
        let range: NSRange
        let open: NSRange
        let close: NSRange
        let color: CardColor
        let isShaded: Bool
        let frame: NSRect
        /// Where the card's lines of text are, from its left padding to its right: there the pointer is the
        /// text's. Everywhere else on the card it holds the card (see MarkdownTextView+CardDrag). Nil for
        /// a card with no lines of text.
        let content: NSRect?
        /// The tag behind the title, one piece per line of it.
        let tags: [NSRect]
        let titleIsEmpty: Bool
        /// The three dots of "•••".
        let dots: NSRect

        /// Where a click opens the card's menu: the dots with room around them.
        var menuArea: NSRect { dots.insetBy(dx: -6, dy: -8) }
    }

    /// The cards that have characters in `characters` (all of them by default).
    func cardGeometries(in characters: NSRange? = nil) -> [CardGeometry] {
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return [] }
        let all = NSRange(location: 0, length: storage.length)
        // A card is one run of its number; text being composed inside it can split the run for a moment.
        var ranges: [Int: NSRange] = [:]
        var order: [Int] = []
        storage.enumerateAttribute(.mdCard, in: all) { value, run, _ in
            guard let number = value as? Int else { return }
            if let known = ranges[number] { ranges[number] = NSUnionRange(known, run) } else { ranges[number] = run; order.append(number) }
        }
        let ns = storage.string as NSString
        return order.compactMap { number in
            guard let range = ranges[number], characters.map({ NSIntersectionRange($0, range).length > 0 }) ?? true else { return nil }
            let open = ns.paragraphRange(for: NSRange(location: range.location, length: 0))
            let close = ns.paragraphRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
            guard lineKind(at: open.location) == .cardOpen, lineKind(at: close.location) == .cardClose, open.location < close.location,
                  let color = (storage.attribute(.mdCardColor, at: range.location, effectiveRange: nil) as? String).flatMap(CardColor.init)
            else { return nil }
            return cardGeometry(range: range, open: open, close: close, color: color, storage, container)
        }
    }

    private func lineKind(at index: Int) -> MarkdownLine {
        (textStorage?.attribute(.mdLine, at: index, effectiveRange: nil) as? String).flatMap(MarkdownLine.init) ?? .text
    }

    private func cardGeometry(range: NSRange, open: NSRange, close: NSRange, color: CardColor,
                              _ storage: NSTextStorage, _ container: NSTextContainer) -> CardGeometry {
        let padding = container.lineFragmentPadding
        // The first and the last line of the opening paragraph (a long title wraps), and the closing line.
        let top = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: open.location), effectiveRange: nil)
        let title = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: NSMaxRange(open) - 1), effectiveRange: nil)
        var bottom = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: NSMaxRange(close) - 1), effectiveRange: nil).maxY
        // Side by side, cards are as tall as the tallest of their row: down to where the row ends.
        if let cell = (storage.attribute(.paragraphStyle, at: open.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first {
            bottom = max(bottom, boundsRect(for: cell, glyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)).maxY)
        }
        let frame = NSRect(x: top.minX + padding, y: top.minY + theme.cardGap,
                           width: top.width - 2 * padding, height: bottom - theme.cardGap - (top.minY + theme.cardGap))
        var content: NSRect?
        if NSMaxRange(open) < close.location {
            let closing = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: close.location), effectiveRange: nil)
            content = NSRect(x: frame.minX + theme.cardPadding, y: title.maxY,
                             width: frame.width - 2 * theme.cardPadding, height: max(closing.minY - title.maxY, 0))
        }

        // The title: what follows the hidden syntax on the opening line.
        var prefix = NSRange()
        let hasPrefix = storage.attribute(.mdBlockPrefix, at: open.location, longestEffectiveRange: &prefix, in: open) != nil
        var titleEnd = NSMaxRange(open)
        let ns = storage.string as NSString
        while titleEnd > open.location, ns.character(at: titleEnd - 1) == 0x0A || ns.character(at: titleEnd - 1) == 0x0D { titleEnd -= 1 }
        let titleStart = hasPrefix ? NSMaxRange(prefix) : open.location
        // The tag is as tall as the title's line (the part of it that holds text, without the space the
        // paragraph keeps above and below), and as wide as the title with room on both sides.
        // (With the Markdown shown, the syntax stands right before the title: the tag keeps close to it.)
        let tagPadding = concealsMarkdown ? theme.cardTagPadding : 2
        func tag(from minX: CGFloat, to maxX: CGFloat, line: NSRect) -> NSRect {
            NSRect(x: minX - tagPadding, y: line.minY, width: maxX - minX + 2 * tagPadding, height: line.height)
        }
        var tags: [NSRect] = []
        if titleEnd > titleStart {
            let glyphs = glyphRange(forCharacterRange: NSRange(location: titleStart, length: titleEnd - titleStart), actualCharacterRange: nil)
            var glyph = glyphs.location
            while glyph < NSMaxRange(glyphs) {
                var fragmentGlyphs = NSRange()
                let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &fragmentGlyphs)
                let piece = NSIntersectionRange(glyphs, fragmentGlyphs)
                guard piece.length > 0 else { break }
                let bounds = boundingRect(forGlyphRange: piece, in: container)
                tags.append(tag(from: bounds.minX, to: bounds.maxX, line: used))
                glyph = NSMaxRange(piece)
            }
        } else if concealsMarkdown {
            // No title: a tag for the placeholder, where the title would start.
            let glyph = glyphIndexForCharacter(at: min(titleStart, storage.length - 1))
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let start = fragment.minX + location(forGlyphAt: glyph).x
            let width = (theme.cardTitlePlaceholder as NSString).size(withAttributes: [.font: theme.cardTitleFont]).width
            tags.append(tag(from: start, to: start + ceil(width), line: lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)))
        }
        let dotsY = frame.minY + theme.cardPaddingTop + theme.cardTagHeight / 2 - theme.cardDotSize / 2
        let dots = NSRect(x: frame.maxX - theme.cardDotsInset - theme.cardDotsWidth, y: dotsY,
                          width: theme.cardDotsWidth, height: theme.cardDotSize)
        return CardGeometry(range: range, open: open, close: close, color: color,
                            isShaded: storage.attribute(.mdCardShade, at: open.location, effectiveRange: nil) != nil,
                            frame: frame, content: content, tags: tags, titleIsEmpty: titleEnd == titleStart, dots: dots)
    }

    /// Each card's rectangle, the title's tag and "•••"; the text is drawn over them.
    private func drawCards(in characters: NSRange, at origin: NSPoint) {
        for card in cardGeometries(in: characters) {
            func tone(_ color: NSColor) -> NSColor { card.isShaded ? theme.shaded(color) : color }
            let fade = card.isShaded ? theme.focusFade : 1
            tone(card.color.frame).setFill()
            NSBezierPath(roundedRect: card.frame.offsetBy(dx: origin.x, dy: origin.y), xRadius: theme.cardRadius, yRadius: theme.cardRadius).fill()
            tone(card.color.tag).setFill()
            for tag in card.tags {
                NSBezierPath(roundedRect: tag.offsetBy(dx: origin.x, dy: origin.y), xRadius: theme.cardTagRadius, yRadius: theme.cardTagRadius).fill()
            }
            if card.titleIsEmpty, let tag = card.tags.first {
                let font = theme.cardTitleFont
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: (card.isShaded ? theme.focusInk : card.color.tagText).withAlphaComponent(0.45 * fade)]
                let baseline = tag.midY + font.capHeight / 2 // like a title: its capitals in the middle of the tag
                (theme.cardTitlePlaceholder as NSString).draw(
                    at: NSPoint(x: tag.minX + theme.cardTagPadding + origin.x, y: baseline - font.ascender + origin.y), withAttributes: attributes)
            }
            let ink = card.isShaded ? theme.focusInk : theme.textColor // the dots, in the light ink on dark paper
            ink.withAlphaComponent(ink.alphaComponent * fade).setFill()
            for i in 0..<3 {
                let dot = NSRect(x: card.dots.minX + CGFloat(i) * theme.cardDotSpacing, y: card.dots.minY,
                                 width: theme.cardDotSize, height: theme.cardDotSize)
                NSBezierPath(ovalIn: dot.offsetBy(dx: origin.x, dy: origin.y)).fill()
            }
        }
    }

    /// How far the blocks drawn across a line (a code block's background, a divider) stay from the line's
    /// ends: a card's text is inset from the card's edges.
    private func blockInset(at index: Int) -> CGFloat {
        guard let storage = textStorage, index < storage.length, storage.attribute(.mdCard, at: index, effectiveRange: nil) != nil,
              !lineKind(at: index).isCardStructure else { return 0 }
        return theme.cardContentInset
    }

    /// 強調表示: how much of the look of the paragraph of `index` is left (1 unless it is dimmed).
    func fade(at index: Int) -> CGFloat {
        guard let storage = textStorage, index < storage.length else { return 1 }
        return storage.attribute(.mdFade, at: index, effectiveRange: nil) as? CGFloat ?? 1
    }

    /// The color of something drawn for the paragraph of `index`: `color` — or, in place of the text
    /// color, the paragraph's ink — faded as the paragraph is (強調表示).
    private func tone(_ color: NSColor? = nil, at index: Int) -> NSColor {
        var base = color ?? theme.textColor
        if color == nil, let storage = textStorage, index < storage.length,
           let ink = storage.attribute(.mdInk, at: index, effectiveRange: nil) as? NSColor { base = ink }
        let fade = fade(at: index)
        return fade == 1 ? base : base.withAlphaComponent(base.alphaComponent * fade)
    }

    /// The vertical centre of the first line's text (between the x-height and the cap height).
    private func textCenterY(glyph: Int) -> CGFloat {
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = fragment.minY + location(forGlyphAt: glyph).y
        let font = theme.bodyFont
        return baseline - (font.capHeight + font.xHeight) / 4
    }

    /// Notion's bullets: a disc, then a circle, then a square, centred in the marker column.
    private func drawBullet(depth: Int, in box: NSRect, glyph: Int, origin: NSPoint, color: NSColor) {
        let size = (theme.fontSize * 0.36).rounded(.toNearestOrAwayFromZero)
        let center = NSPoint(x: box.minX + theme.listMarkerColumn / 2, y: textCenterY(glyph: glyph))
        let rect = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            .offsetBy(dx: origin.x, dy: origin.y)
        color.set()
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
    private func drawOrdinal(_ ordinal: String, in box: NSRect, glyph: Int, origin: NSPoint, color: NSColor) {
        let font = theme.bodyFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = (ordinal as NSString).size(withAttributes: attributes).width
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = fragment.minY + location(forGlyphAt: glyph).y
        let x = box.minX + max((theme.listMarkerColumn - width) / 2, 0)
        (ordinal as NSString).draw(at: NSPoint(x: x + origin.x, y: baseline - font.ascender + origin.y), withAttributes: attributes)
    }

    /// Where a to-do's checkbox or signal is drawn (see TaskSignalIcon): a 1em square centred in the
    /// marker column, in the container's coordinates. `index` is the first character of the to-do's
    /// marker (its concealed box).
    func taskIconRect(forCharacterAt index: Int) -> NSRect? {
        guard let container = textContainers.first, let storage = textStorage, index < storage.length else { return nil }
        let box = boxRect(forCharacterAt: index, in: container)
        let size = theme.fontSize.rounded()
        let centerY = textCenterY(glyph: glyphIndexForCharacter(at: index))
        return NSRect(x: (box.minX + (theme.listMarkerColumn - size) / 2).rounded(), y: (centerY - size / 2).rounded(),
                      width: size, height: size)
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
