import AppKit

/// A place a dragged card can be dropped.
struct CardDropTarget: Equatable {
    let destination: CardArrangement.Destination
    /// For a place beside another card: where the pointer has to be to mean it (a side of that card).
    /// The places between the note's lines have none: of those the nearest one is meant.
    let zone: NSRect?
    /// The line that shows the place while the card is over it.
    let indicator: NSRect
    // Both in the text container's coordinates.
}

/// The line that shows where a dragged card would go.
final class CardDropLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 1, yRadius: 1).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Moving cards with the mouse. A card is picked up by its frame — anywhere on it but on its text. Dropped
/// between two lines of the note it stands there on its own; dropped on a side of another card the two
/// stand side by side (in a row, see CardSyntax). Only the Markdown changes: see CardArrangement.
extension MarkdownTextView {
    // MARK: Where a card can go

    /// The places card `number` can be dropped: beside every other card that has room for one more next
    /// to it, and between the pieces of the note (its lines outside cards, its cards and its rows).
    /// Places that would leave the note as it is are left out.
    func cardDropTargets(forCard number: Int) -> [CardDropTarget] {
        guard let layout = layoutManager as? ConcealingLayoutManager, let container = textContainer, let storage = textStorage
        else { return [] }
        let arrangement = CardArrangement(storage)
        let cards = layout.cardGeometries()
        guard number < cards.count, cards.count == arrangement.cardCount else { return [] }
        let theme = layout.theme
        let padding = container.lineFragmentPadding
        let width = container.size.width
        let home = arrangement.place(ofCard: number)
        func changes(_ destination: CardArrangement.Destination) -> Bool {
            var copy = arrangement
            return copy.move(card: number, to: destination) != nil
        }

        var targets: [CardDropTarget] = []
        func beside(_ card: Int, piece: Int, cardsInRow: Int) {
            // One more card in the row, unless the dragged card stands in it already.
            let count = home?.piece == piece && home?.column != nil ? cardsInRow : cardsInRow + 1
            guard card != number, width / CGFloat(count) >= theme.cardMinimumWidth else { return }
            let frame = cards[card].frame
            let reach = min(max(frame.width * 0.35, 18), 60)
            for after in [false, true] where changes(.beside(card: card, after: after)) {
                let x = after ? frame.maxX + theme.cardRowGap / 2 : frame.minX - theme.cardRowGap / 2
                targets.append(CardDropTarget(
                    destination: .beside(card: card, after: after),
                    zone: NSRect(x: after ? frame.maxX - reach : frame.minX, y: frame.minY, width: reach, height: frame.height),
                    indicator: NSRect(x: min(max(x - 1, 1), width - 3), y: frame.minY, width: 2, height: frame.height)))
            }
        }

        // The room each piece takes, top to bottom.
        var rooms: [NSRect] = []
        var next = 0
        var offset = 0
        for (index, piece) in arrangement.pieces.enumerated() {
            switch piece {
            case .line(let line):
                if offset < storage.length {
                    let glyph = layout.glyphIndexForCharacter(at: offset)
                    rooms.append(layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                        .union(layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: offset + (line as NSString).length - (line.isEmpty ? 0 : 1)),
                                                       effectiveRange: nil)))
                } else {
                    rooms.append(layout.extraLineFragmentRect) // the empty line that ends the note
                }
                offset += (line as NSString).length + 1
            case .card(let lines):
                rooms.append(cards[next].frame.insetBy(dx: 0, dy: -theme.cardGap))
                beside(next, piece: index, cardsInRow: 1)
                next += 1
                offset += lines.reduce(0) { $0 + ($1 as NSString).length + 1 }
            case .row(let rowCards):
                let frames = rowCards.indices.map { cards[next + $0].frame }
                rooms.append(frames.dropFirst().reduce(frames[0]) { $0.union($1) }.insetBy(dx: 0, dy: -theme.cardGap))
                for column in rowCards.indices { beside(next + column, piece: index, cardsInRow: rowCards.count) }
                next += rowCards.count
                offset += (CardSyntax.rowOpenMarker as NSString).length + 1 + (CardSyntax.rowCloseMarker as NSString).length + 1
                    + rowCards.flatMap { $0 }.reduce(0) { $0 + ($1 as NSString).length + 1 }
            }
        }
        // Between them (and above the first, below the last).
        for index in 0...rooms.count where changes(.before(piece: index)) {
            let y: CGFloat
            if rooms.isEmpty { y = 0 }
            else if index == 0 { y = rooms[0].minY }
            else if index == rooms.count { y = rooms[index - 1].maxY }
            else { y = (rooms[index - 1].maxY + rooms[index].minY) / 2 }
            targets.append(CardDropTarget(destination: .before(piece: index), zone: nil,
                                          indicator: NSRect(x: padding, y: y - 1, width: width - 2 * padding, height: 2)))
        }
        return targets
    }

    /// The place meant by a pointer at `point` (text container coordinates) while card `number` is dragged.
    func cardDropTarget(forCard number: Int, at point: NSPoint, among targets: [CardDropTarget]? = nil) -> CardDropTarget? {
        guard let layout = layoutManager as? ConcealingLayoutManager else { return nil }
        let cards = layout.cardGeometries()
        // Still over the card itself: nowhere yet.
        if number < cards.count, cards[number].frame.contains(point) { return nil }
        let targets = targets ?? cardDropTargets(forCard: number)
        if let side = targets.filter({ $0.zone?.contains(point) == true }).min(by: {
            abs($0.indicator.midX - point.x) < abs($1.indicator.midX - point.x)
        }) { return side }
        return targets.filter { $0.zone == nil }.min { abs($0.indicator.midY - point.y) < abs($1.indicator.midY - point.y) }
    }

    /// Moves card `number` to `destination`, as one change that ⌘Z takes back. The caret goes to the end
    /// of the card's title.
    @discardableResult
    func moveCard(_ number: Int, to destination: CardArrangement.Destination) -> Bool {
        guard isEditable, !hasMarkedText(), let storage = textStorage else { return false }
        var arrangement = CardArrangement(storage)
        guard let moved = arrangement.move(card: number, to: destination), let offset = arrangement.offset(ofCard: moved),
              let open = arrangement.lines(ofCard: moved)?.first else { return false }
        apply(ConcealedEditing.edit(to: arrangement, caret: offset + (open as NSString).length, in: storage), actionName: "カードを移動")
        return true
    }

    // MARK: The mouse

    /// The pointer over a card: a hand on its frame (it can be dragged), a pointing hand on "•••".
    func cardCursor(at point: NSPoint) -> NSCursor? {
        guard concealsMarkdown, let layout = layoutManager as? ConcealingLayoutManager,
              let card = layout.cardGeometries().first(where: { $0.frame.contains(point) }) else { return nil }
        if card.menuArea.contains(point) { return .pointingHand }
        if card.panel?.contains(point) == true { return nil }
        return isEditable ? .openHand : nil
    }

    /// Follows the mouse after a press on a card's frame. Released where it was pressed, it was a click:
    /// the caret goes where the click points to. Moved, the card is dragged: a picture of it follows the
    /// pointer, a line shows where it would go, and releasing the button puts it there. Esc lets go of it.
    func trackCardPress(on card: ConcealingLayoutManager.CardGeometry, _ event: NSEvent) {
        guard let window, let storage = textStorage,
              let number = storage.attribute(.mdCard, at: card.range.location, effectiveRange: nil) as? Int else { return }
        let pressed = event.locationInWindow
        let grabbed = containerPoint(event)
        var ghost: NSView?
        var indicator: NSView?
        var targets: [CardDropTarget] = []
        var target: CardDropTarget?
        defer {
            ghost?.removeFromSuperview()
            indicator?.removeFromSuperview()
            if ghost != nil { NSCursor.pop() }
        }
        let nextEvent = trackingEvents ?? { window.nextEvent(matching: $0) }
        while let next = nextEvent([.leftMouseDragged, .leftMouseUp, .keyDown]) {
            switch next.type {
            case .leftMouseUp:
                if ghost == nil {
                    clickOnFrame(of: card, at: grabbed)
                } else if let target {
                    moveCard(number, to: target.destination)
                }
                return
            case .keyDown:
                if next.keyCode == 53, ghost != nil { return } // Esc
            default:
                let position = next.locationInWindow
                if ghost == nil {
                    guard isEditable, !hasMarkedText(), hypot(position.x - pressed.x, position.y - pressed.y) > 4 else { continue }
                    targets = cardDropTargets(forCard: number)
                    let picture = cardPicture(card)
                    addSubview(picture)
                    ghost = picture
                    let line = CardDropLine()
                    line.isHidden = true
                    addSubview(line)
                    indicator = line
                    NSCursor.closedHand.push()
                }
                let point = containerPoint(next)
                let origin = textContainerOrigin
                ghost?.setFrameOrigin(NSPoint(x: card.frame.minX + origin.x + point.x - grabbed.x,
                                              y: card.frame.minY + origin.y + point.y - grabbed.y))
                target = cardDropTarget(forCard: number, at: point, among: targets)
                indicator?.isHidden = target == nil
                if let target { indicator?.frame = target.indicator.offsetBy(dx: origin.x, dy: origin.y) }
                autoscroll(with: next)
            }
        }
    }

    /// The card as it is drawn, to follow the pointer while it is dragged.
    private func cardPicture(_ card: ConcealingLayoutManager.CardGeometry) -> NSView {
        let rect = card.frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let view = NSImageView(frame: rect)
        if let rep = bitmapImageRepForCachingDisplay(in: rect) {
            cacheDisplay(in: rect, to: rep)
            let image = NSImage(size: rect.size)
            image.addRepresentation(rep)
            view.image = image
        }
        view.imageScaling = .scaleNone
        view.alphaValue = 0.75
        view.wantsLayer = true
        view.layer?.shadowOpacity = 0.25
        view.layer?.shadowRadius = 6
        view.layer?.shadowOffset = CGSize(width: 0, height: -2)
        return view
    }

    /// A click on a card's frame: on or beside its title, the caret goes into the title; under its text,
    /// to the end of the text (the closing line there shows nothing to click on); beside its text, to
    /// the line next to it.
    private func clickOnFrame(of card: ConcealingLayoutManager.CardGeometry, at point: NSPoint) {
        guard let storage = textStorage, let layout = layoutManager, let model = ConcealedEditing.card(at: card.range.location, in: storage)
        else { return }
        window?.makeFirstResponder(self)
        let index = characterIndexForInsertion(at: NSPoint(x: point.x + textContainerOrigin.x, y: point.y + textContainerOrigin.y))
        let closing = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: card.close.location), effectiveRange: nil)
        let caret: Int
        if point.y < (card.panel?.minY ?? closing.minY) {
            caret = min(max(index, model.open.contentStart), model.open.contentsEnd)
        } else if point.y >= closing.minY {
            caret = ConcealedEditing.lastCaret(in: model, storage)
        } else {
            caret = min(max(index, model.content.location), ConcealedEditing.lastCaret(in: model, storage))
        }
        setSelectedRange(NSRange(location: caret, length: 0))
    }
}
