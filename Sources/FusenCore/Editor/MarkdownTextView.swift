import AppKit

final class MarkdownTextView: NSTextView {
    /// Markdown syntax is concealed (the default), and the editing keys follow Notion; off while
    /// 「Markdown記号をすべて表示」 shows the raw text.
    var concealsMarkdown = true
    /// 強調表示 of the note this view shows, if it is on. Restyling follows it (NoteWindowController.restyle).
    var focus: NoteFocus? {
        didSet { if focus != oldValue { updateInsertionPointColor() } }
    }

    /// The caret is white on the darkened paper of 強調表示, and dark as always in a card that stays light.
    func updateInsertionPointColor() {
        guard let theme = (layoutManager as? ConcealingLayoutManager)?.theme else { return }
        var onDarkPaper = focus != nil
        if onDarkPaper, let storage = textStorage, let card = ConcealedEditing.card(around: selectedRange().location, in: storage),
           storage.attribute(.mdCardShade, at: card.range.location, effectiveRange: nil) == nil {
            onDarkPaper = false
        }
        let color = onDarkPaper ? theme.focusInk : theme.textColor
        if insertionPointColor != color { insertionPointColor = color }
    }

    // MARK: Return, Tab

    // Return continues a list / task list; Return on an empty item ends the list. Concealed, it also
    // follows Notion's other rules (see ConcealedEditing.newline). While the IME is composing, Return
    // commits the composition and never reaches this method, but guard on marked text anyway.
    override func insertNewline(_ sender: Any?) {
        if slashMenu != nil { return acceptSlashCommand() }
        guard !hasMarkedText(), let storage = textStorage else { return super.insertNewline(sender) }
        if concealsMarkdown {
            if selectedRange().length > 0 { deleteKeepingSyntax(selectedRange()) }
            guard let edit = ConcealedEditing.newline(at: selectedRange().location, in: storage) else {
                return super.insertNewline(sender)
            }
            return apply(edit, actionName: "改行")
        }
        let selection = selectedRange()
        let line = ConcealedEditing.line(at: selection.location, in: storage)
        guard selection.length == 0, line.isListItem, let prefix = line.prefix, selection.location >= NSMaxRange(prefix),
              let next = ConcealedEditing.listPrefix((storage.string as NSString).substring(with: prefix), next: true, keepCheck: false)
        else { return super.insertNewline(sender) }
        if NSMaxRange(prefix) == line.contentsEnd {
            replaceCharacters(in: prefix, with: "", actionName: "リストの終了")
            return
        }
        insertText("\n" + next, replacementRange: selection)
    }

    // Tab / Shift-Tab on a list item nests it one level deeper / shallower, as in Notion. Nesting uses
    // tabs, which is also how Notion-flavored Markdown writes child blocks.
    override func insertTab(_ sender: Any?) {
        if slashMenu != nil { return acceptSlashCommand() }
        guard let line = currentListLine() else {
            // Cards side by side are the cells of a text table, where the text view's Tab jumps to the next
            // cell. Here Tab is a tab, as everywhere else in a note.
            if isInTableCell { return insertText("\t", replacementRange: selectedRange()) }
            return super.insertTab(sender)
        }
        replaceCharacters(in: NSRange(location: line.range.location, length: 0), with: "\t", actionName: "字下げ")
    }

    override func insertBacktab(_ sender: Any?) {
        guard let line = currentListLine(), let storage = textStorage else {
            return isInTableCell ? () : super.insertBacktab(sender)
        }
        let ns = storage.string as NSString
        let start = line.range.location
        var remove = 0
        if ns.character(at: start) == 0x09 {
            remove = 1
        } else {
            while remove < 2, start + remove < line.contentsEnd, ns.character(at: start + remove) == 0x20 { remove += 1 }
        }
        guard remove > 0 else { return }
        replaceCharacters(in: NSRange(location: start, length: remove), with: "", actionName: "字下げ解除")
    }

    /// Whether the caret is in a card that stands in a row (a cell of the row's text table).
    private var isInTableCell: Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let line = ConcealedEditing.line(at: selectedRange().location, in: storage).range.location
        guard line < storage.length else { return false }
        return (storage.attribute(.paragraphStyle, at: line, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.isEmpty == false
    }

    /// The caret's line if it is a list item (and nothing is selected or being composed).
    private func currentListLine() -> ConcealedEditing.Line? {
        guard !hasMarkedText(), selectedRange().length == 0, let storage = textStorage else { return nil }
        let line = ConcealedEditing.line(at: selectedRange().location, in: storage)
        return line.isListItem ? line : nil
    }

    // MARK: Moving (concealed; see ConcealedEditing)

    // Arrow keys: TextKit 1 finds the next insertion point through the glyphs, and concealed syntax has
    // none (null glyphs), so the caret can jump the wrong way. Move by character instead (text here is
    // left-to-right), stepping over hidden syntax so that every press moves the caret on screen.
    override func moveRight(_ sender: Any?) { concealsMarkdown ? step(forward: true, extend: false) : super.moveRight(sender) }
    override func moveLeft(_ sender: Any?) { concealsMarkdown ? step(forward: false, extend: false) : super.moveLeft(sender) }
    override func moveForward(_ sender: Any?) { concealsMarkdown ? step(forward: true, extend: false) : super.moveForward(sender) }
    override func moveBackward(_ sender: Any?) { concealsMarkdown ? step(forward: false, extend: false) : super.moveBackward(sender) }
    override func moveRightAndModifySelection(_ sender: Any?) {
        concealsMarkdown ? step(forward: true, extend: true) : super.moveRightAndModifySelection(sender)
    }
    override func moveLeftAndModifySelection(_ sender: Any?) {
        concealsMarkdown ? step(forward: false, extend: true) : super.moveLeftAndModifySelection(sender)
    }
    override func moveForwardAndModifySelection(_ sender: Any?) {
        concealsMarkdown ? step(forward: true, extend: true) : super.moveForwardAndModifySelection(sender)
    }
    override func moveBackwardAndModifySelection(_ sender: Any?) {
        concealsMarkdown ? step(forward: false, extend: true) : super.moveBackwardAndModifySelection(sender)
    }

    override func moveUp(_ sender: Any?) {
        if slashMenu != nil { return moveSlashSelection(by: -1) }
        moveVertically(down: false, extend: false) { super.moveUp(sender) }
    }

    override func moveUpAndModifySelection(_ sender: Any?) {
        moveVertically(down: false, extend: true) { super.moveUpAndModifySelection(sender) }
    }

    override func moveDown(_ sender: Any?) {
        if slashMenu != nil { return moveSlashSelection(by: 1) }
        moveVertically(down: true, extend: false) { super.moveDown(sender) }
    }

    override func moveDownAndModifySelection(_ sender: Any?) {
        moveVertically(down: true, extend: true) { super.moveDownAndModifySelection(sender) }
    }

    private struct CaretLine {
        let rect: NSRect
        let glyphs: NSRange
        /// Valid insertion positions, excluding the newline and null glyphs of the next block.
        let start: Int
        let end: Int
        let reference: Int?
    }

    /// After correcting a native move, retain its original column across short/empty rows.
    /// Any non-vertical selection change (click, horizontal arrow, editing) starts a new column.
    private var verticalMotion: (x: CGFloat, corrected: Bool)?
    private var isMovingVertically = false

    private func moveVertically(down: Bool, extend: Bool, _ move: () -> Void) {
        let selection = selectedRange()
        guard concealedEditing, (extend || selection.length == 0),
              let storage = textStorage, let layoutManager, let textContainer else { return move() }
        layoutManager.ensureLayout(for: textContainer)
        let moving = extend && selection.length > 0 ? (movingEnd ?? selection.location) : selection.location
        let anchor = moving == selection.location ? NSMaxRange(selection) : selection.location
        let current = caretLine(at: moving, affinity: selectionAffinity, in: storage, layoutManager)
        let x = verticalMotion?.x ?? caretX(at: moving, on: current, in: storage, layoutManager, textContainer)
        verticalMotion = (x, verticalMotion?.corrected ?? false)
        isMovingVertically = true
        defer { isMovingVertically = false }
        var nextGlyph = down ? NSMaxRange(current.glyphs) : current.glyphs.location - 1
        var found: CaretLine?
        // A card's closing line is a row that shows nothing: the caret goes on to the row beyond it.
        var passedHiddenRow = false
        while found == nil, nextGlyph >= 0, nextGlyph < layoutManager.numberOfGlyphs {
            let row = caretLine(forGlyph: nextGlyph, in: storage, layoutManager)
            if ConcealedEditing.line(at: row.start, in: storage).kind.isHiddenLine {
                passedHiddenRow = true
                nextGlyph = down ? NSMaxRange(row.glyphs) : row.glyphs.location - 1
            } else {
                found = row
            }
        }
        // Cards side by side are columns: the row that follows in the text can be beside the caret's
        // row instead of under it. Then the row to go to is found by where the rows are.
        if let row = found, !lies(row, down, of: current, at: x) {
            found = rowByPosition(from: current, down: down, at: x, in: storage, layoutManager)
            passedHiddenRow = true
            if found == nil, !(down && layoutManager.extraLineFragmentTextContainer != nil) {
                // Nothing above (below) in this column: to the start (end) of the line, as at the note's edges.
                let edge = down ? current.end : current.start
                let fixedEnd = extend ? anchor : edge
                setSelectedRange(NSRange(location: min(fixedEnd, edge), length: abs(edge - fixedEnd)))
                return
            }
            nextGlyph = layoutManager.numberOfGlyphs
        }
        if found == nil, down, nextGlyph >= layoutManager.numberOfGlyphs, current.reference != nil,
           layoutManager.extraLineFragmentTextContainer != nil {
            found = emptyCaretLine(in: storage, layoutManager)
        }
        guard let destination = found else { return move() }
        move()
        let after = selectedRange()
        let afterMoving = extend && after.length > 0 ? (movingEnd ?? after.location) : after.location
        let afterAnchor = afterMoving == after.location ? NSMaxRange(after) : after.location
        // The selection delegate collapses a selection containing only an opening delimiter.
        // It is still the same visible anchor, so the correction must restore the original one.
        let collapsedSyntax = selection.length == 0 && after.length == 0
            && (min(anchor, afterAnchor)..<max(anchor, afterAnchor)).allSatisfy { isNullCharacter($0, in: storage) }
        guard extend ? (afterAnchor == anchor || collapsedSyntax) : after.length == 0 else { return }
        let actual = caretLine(at: afterMoving, affinity: selectionAffinity, in: storage, layoutManager)
        let reachedRow = afterMoving >= destination.start && afterMoving <= destination.end && actual.rect == destination.rect
        guard !reachedRow || verticalMotion?.corrected == true || passedHiddenRow else { return }
        verticalMotion = (x, true)

        // Null glyphs can belong to another fragment. Native movement may stall inside a hidden
        // marker, or skip a line entirely. Correct only those moves using the adjacent visual row;
        // a divider remains a visible object and needs no special "only syntax" exception.
        let point = NSPoint(x: x + textContainerOrigin.x, y: destination.rect.midY + textContainerOrigin.y)
        let target = max(destination.start, min(characterIndexForInsertion(at: point), destination.end))
        let fixedEnd = extend ? anchor : target
        setSelectedRange(NSRange(location: min(fixedEnd, target), length: abs(target - fixedEnd)),
                         affinity: down ? .downstream : .upstream, stillSelecting: false)
        scrollRangeToVisible(NSRange(location: target, length: 0))
    }

    /// Whether `row` is under (above) `current` and reaches over `x`: where a vertical move from
    /// `current` goes to.
    private func lies(_ row: CaretLine, _ down: Bool, of current: CaretLine, at x: CGFloat) -> Bool {
        (down ? row.rect.minY >= current.rect.maxY - 0.5 : row.rect.maxY <= current.rect.minY + 0.5)
            && x >= row.rect.minX - 0.5 && x <= row.rect.maxX + 0.5
    }

    /// The nearest row under (above) `current` at `x` that can hold the caret, wherever it is in the text.
    private func rowByPosition(from current: CaretLine, down: Bool, at x: CGFloat,
                               in storage: NSTextStorage, _ layout: NSLayoutManager) -> CaretLine? {
        var best: CaretLine?
        var glyph = 0
        while glyph < layout.numberOfGlyphs {
            let row = caretLine(forGlyph: glyph, in: storage, layout)
            glyph = max(NSMaxRange(row.glyphs), glyph + 1)
            guard !ConcealedEditing.line(at: row.start, in: storage).kind.isHiddenLine, lies(row, down, of: current, at: x) else { continue }
            if let known = best, down ? known.rect.minY <= row.rect.minY : known.rect.maxY >= row.rect.maxY { continue }
            best = row
        }
        return best
    }

    private func isNullCharacter(_ index: Int, in storage: NSTextStorage) -> Bool {
        index >= 0 && index < storage.length
            && storage.attribute(.mdMarker, at: index, effectiveRange: nil) != nil
            && storage.attribute(.mdConcealBox, at: index, effectiveRange: nil) == nil
    }

    private func caretLine(forGlyph glyph: Int, in storage: NSTextStorage, _ layout: NSLayoutManager) -> CaretLine {
        var glyphs = NSRange()
        let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var end = NSMaxRange(characters)
        while end > characters.location, isNullCharacter(end - 1, in: storage) { end -= 1 }
        if end > characters.location {
            end = min(end, ConcealedEditing.line(at: end - 1, in: storage).contentsEnd)
        }
        return CaretLine(rect: rect, glyphs: glyphs, start: characters.location, end: end,
                         reference: layout.characterIndexForGlyph(at: glyph))
    }

    private func emptyCaretLine(in storage: NSTextStorage, _ layout: NSLayoutManager) -> CaretLine {
        CaretLine(rect: layout.extraLineFragmentRect, glyphs: NSRange(location: layout.numberOfGlyphs, length: 0),
                  start: storage.length, end: storage.length, reference: nil)
    }

    private func caretLine(at position: Int, affinity: NSSelectionAffinity,
                           in storage: NSTextStorage, _ layout: NSLayoutManager) -> CaretLine {
        let paragraph = ConcealedEditing.line(at: position, in: storage)
        var visible = position
        while visible < paragraph.contentsEnd, isNullCharacter(visible, in: storage) { visible += 1 }
        if visible == storage.length {
            visible -= 1
            while visible >= paragraph.range.location, isNullCharacter(visible, in: storage) { visible -= 1 }
            guard visible >= paragraph.range.location else { return emptyCaretLine(in: storage, layout) }
        }
        let glyph = layout.glyphIndexForCharacter(at: visible)
        let line = caretLine(forGlyph: glyph, in: storage, layout)
        // At a soft wrap, upstream affinity belongs to the end of the preceding visual row.
        // A hidden paragraph prefix is always part of its own row instead.
        if affinity == .upstream, position == line.start, line.glyphs.location > 0,
           position > ConcealedEditing.visibleContentStart(of: paragraph, in: storage) {
            return caretLine(forGlyph: line.glyphs.location - 1, in: storage, layout)
        }
        return line
    }

    private func caretX(at position: Int, on line: CaretLine, in storage: NSTextStorage,
                        _ layout: NSLayoutManager, _ container: NSTextContainer) -> CGFloat {
        guard let reference = line.reference else {
            let paragraph = ConcealedEditing.line(at: position, in: storage)
            let style = paragraph.range.location < storage.length
                ? storage.attribute(.paragraphStyle, at: paragraph.range.location, effectiveRange: nil) as? NSParagraphStyle : nil
            return container.lineFragmentPadding + (style?.headIndent ?? 0)
        }
        let count = layout.getLineFragmentInsertionPoints(forCharacterAt: reference, alternatePositions: false,
                                                          inDisplayOrder: false, positions: nil, characterIndexes: nil)
        var positions = [CGFloat](repeating: 0, count: count)
        var indices = [Int](repeating: 0, count: count)
        layout.getLineFragmentInsertionPoints(forCharacterAt: reference, alternatePositions: false,
                                              inDisplayOrder: false, positions: &positions, characterIndexes: &indices)
        let match = indices.indices.first { indices[$0] == position }
            ?? indices.indices.first { i in
                (min(position, indices[i])..<max(position, indices[i])).allSatisfy { isNullCharacter($0, in: storage) }
            }
        return line.rect.minX + (match.map { positions[$0] } ?? container.lineFragmentPadding)
    }

    // ⌥← ⌥→: NSTextView's word moves, repeated while they only cross hidden syntax (a link's URL) and
    // spaces, so that every press moves the caret over a word on screen. At the start of a block's text NSTextView would stop in the
    // hidden marker, where the caret may not stay, so ⌥← (and ⌥⇧↑) move like ← instead (to the line above).
    override func moveWordLeft(_ sender: Any?) { moveByWord(forward: false, extend: false) { super.moveWordLeft(sender) } }
    override func moveWordBackward(_ sender: Any?) { moveByWord(forward: false, extend: false) { super.moveWordBackward(sender) } }
    override func moveWordRight(_ sender: Any?) { moveByWord(forward: true, extend: false) { super.moveWordRight(sender) } }
    override func moveWordForward(_ sender: Any?) { moveByWord(forward: true, extend: false) { super.moveWordForward(sender) } }
    override func moveWordLeftAndModifySelection(_ sender: Any?) {
        moveByWord(forward: false, extend: true) { super.moveWordLeftAndModifySelection(sender) }
    }
    override func moveWordBackwardAndModifySelection(_ sender: Any?) {
        moveByWord(forward: false, extend: true) { super.moveWordBackwardAndModifySelection(sender) }
    }
    override func moveWordRightAndModifySelection(_ sender: Any?) {
        moveByWord(forward: true, extend: true) { super.moveWordRightAndModifySelection(sender) }
    }
    override func moveWordForwardAndModifySelection(_ sender: Any?) {
        moveByWord(forward: true, extend: true) { super.moveWordForwardAndModifySelection(sender) }
    }
    override func moveParagraphBackwardAndModifySelection(_ sender: Any?) {
        isAtBlockStart(extending: true) ? step(forward: false, extend: true) : super.moveParagraphBackwardAndModifySelection(sender)
    }

    private func moveByWord(forward: Bool, extend: Bool, _ move: () -> Void) {
        guard concealsMarkdown, !hasMarkedText(), let storage = textStorage else { return move() }
        if !forward, isAtBlockStart(extending: extend) { return step(forward: false, extend: extend) }
        for _ in 0..<8 {
            let before = selectedRange()
            move()
            let after = selectedRange()
            guard after != before, extend || before.length == 0 else { return }
            // Only hidden syntax and spaces crossed ("`" is a word of its own to NSTextView): not a word yet.
            let moved = after.location != before.location ? (before.location, after.location) : (NSMaxRange(before), NSMaxRange(after))
            let ns = storage.string as NSString
            guard (min(moved.0, moved.1)..<max(moved.0, moved.1)).allSatisfy({
                ConcealedEditing.onlySyntax(between: $0, and: $0 + 1, in: storage) || InlineFormatting.isSpace(ns.character(at: $0))
            }) else { return }
        }
    }

    /// The end of the selection that Shift-arrows move (the other end stays).
    private var movingEnd: Int?

    private func step(forward: Bool, extend: Bool) {
        guard !hasMarkedText(), let storage = textStorage else { return }
        let selection = selectedRange()
        guard extend else {
            if selection.length > 0 {
                return setSelectedRange(NSRange(location: forward ? NSMaxRange(selection) : selection.location, length: 0))
            }
            setSelectedRange(NSRange(location: ConcealedEditing.step(from: selection.location, forward: forward, in: storage), length: 0))
            return scrollRangeToVisible(selectedRange())
        }
        var moving = selection.location
        if selection.length > 0 {
            moving = movingEnd.flatMap { $0 == selection.location || $0 == NSMaxRange(selection) ? $0 : nil }
                ?? (forward ? NSMaxRange(selection) : selection.location)
        }
        let anchor = moving == selection.location ? NSMaxRange(selection) : selection.location
        let moved = ConcealedEditing.step(from: moving, forward: forward, in: storage)
        setSelectedRange(NSRange(location: min(anchor, moved), length: abs(moved - anchor)))
        scrollRangeToVisible(NSRange(location: moved, length: 0))
    }

    /// Whether the caret (or the moving end of the selection) is at the start of a block's text, with
    /// only a marker or hidden syntax before it on its line.
    private func isAtBlockStart(extending: Bool) -> Bool {
        guard concealsMarkdown, !hasMarkedText(), let storage = textStorage else { return false }
        let selection = selectedRange()
        let p = extending && selection.length > 0 ? (movingEnd ?? selection.location) : selection.location
        let line = ConcealedEditing.line(at: p, in: storage)
        return p > line.range.location && ConcealedEditing.onlySyntax(between: line.range.location, and: p, in: storage)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if !isMovingVertically { verticalMotion = nil }
        let old = selectedRange()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        let new = selectedRange()
        // Shift-arrows move the end that moved last, whatever made the selection (⇧↓, ⌥⇧→, a drag).
        if new.length == 0 {
            movingEnd = nil
        } else if new.location == old.location, NSMaxRange(new) != NSMaxRange(old) {
            movingEnd = NSMaxRange(new)
        } else if NSMaxRange(new) == NSMaxRange(old), new.location != old.location {
            movingEnd = new.location
        } else if new != old {
            movingEnd = nil
        }
        if let style = typingStyle, !keepsTypingStyle, !hasMarkedText(), new != NSRange(location: style.location, length: 0) {
            typingStyle = nil
        }
        if focus != nil { updateInsertionPointColor() }
        if slashMenu != nil, !isChangingText { refreshSlashMenu() }
    }

    // MARK: Deleting (concealed)

    /// Several selections (⌘-drag): the text view's own editing, which handles them all.
    private var concealedEditing: Bool { concealsMarkdown && !hasMarkedText() && selectedRanges.count == 1 }

    override func deleteBackward(_ sender: Any?) {
        guard concealedEditing, let storage = textStorage else { return super.deleteBackward(sender) }
        if selectedRange().length > 0 { return deleteKeepingSyntax(selectedRange()) }
        guard let deletion = ConcealedEditing.deleteBackward(at: selectedRange().location, in: storage) else {
            return super.deleteBackward(sender)
        }
        perform(deletion)
    }

    override func deleteForward(_ sender: Any?) {
        guard concealedEditing, let storage = textStorage else { return super.deleteForward(sender) }
        if selectedRange().length > 0 { return deleteKeepingSyntax(selectedRange()) }
        guard let deletion = ConcealedEditing.deleteForward(at: selectedRange().location, in: storage) else {
            return super.deleteForward(sender)
        }
        perform(deletion)
    }

    // ⌥⌫ ⌥⌦ ⌘⌫ ⌃K: to the edge of the word or line as shown, never into hidden syntax; at the edge of a
    // block's text, like ⌫ and ⌦.
    override func deleteWordBackward(_ sender: Any?) { deleteShown(.word, forward: false) { super.deleteWordBackward(sender) } }
    override func deleteWordForward(_ sender: Any?) { deleteShown(.word, forward: true) { super.deleteWordForward(sender) } }
    override func deleteToBeginningOfLine(_ sender: Any?) {
        deleteShown(.line, forward: false) { super.deleteToBeginningOfLine(sender) }
    }
    override func deleteToEndOfLine(_ sender: Any?) { deleteShown(.line, forward: true) { super.deleteToEndOfLine(sender) } }
    override func deleteToBeginningOfParagraph(_ sender: Any?) {
        deleteShown(.paragraph, forward: false) { super.deleteToBeginningOfParagraph(sender) }
    }
    override func deleteToEndOfParagraph(_ sender: Any?) {
        deleteShown(.paragraph, forward: true) { super.deleteToEndOfParagraph(sender) }
    }

    private enum Reach { case word, line, paragraph }

    private func deleteShown(_ reach: Reach, forward: Bool, otherwise: () -> Void) {
        guard concealedEditing, let storage = textStorage else { return otherwise() }
        let selection = selectedRange()
        if selection.length > 0 { return deleteKeepingSyntax(selection) }
        let p = selection.location
        let line = ConcealedEditing.line(at: p, in: storage)
        if forward ? ConcealedEditing.onlySyntax(between: p, and: line.contentsEnd, in: storage)
                   : ConcealedEditing.onlySyntax(between: line.range.location, and: p, in: storage) {
            return forward ? deleteForward(nil) : deleteBackward(nil)
        }
        let target: Int
        switch reach {
        case .word:
            target = ConcealedEditing.wordBoundary(from: p, forward: forward, in: storage)
        case .paragraph:
            target = forward ? line.contentsEnd : line.contentStart
        case .line:
            // The line as laid out: a wrapped paragraph has several.
            let fragment = lineFragmentCharacters(at: forward ? p : p - 1)
            target = forward ? min(NSMaxRange(fragment), line.contentsEnd) : max(fragment.location, line.contentStart)
        }
        let r = forward ? NSRange(location: p, length: max(target - p, 0)) : NSRange(location: min(target, p), length: max(p - target, 0))
        guard r.length > 0 else { return }
        // With no syntax near, the text view's own command, which also keeps what it deletes for ⌃Y.
        let near = max(r.location - 1, 0)..<min(NSMaxRange(r) + 1, storage.length)
        if !near.contains(where: { ConcealedEditing.onlySyntax(between: $0, and: $0 + 1, in: storage) }) { return otherwise() }
        deleteKeepingSyntax(r)
    }

    private func lineFragmentCharacters(at i: Int) -> NSRange {
        guard let layoutManager, let storage = textStorage, storage.length > 0 else { return NSRange(location: i, length: 0) }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(max(i, 0), storage.length - 1))
        var glyphs = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
        return layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    override func cut(_ sender: Any?) {
        guard concealedEditing, selectedRange().length > 0 else { return super.cut(sender) }
        copy(sender)
        deleteKeepingSyntax(selectedRange(), actionName: "カット")
    }

    override func delete(_ sender: Any?) {
        guard concealedEditing, selectedRange().length > 0 else { return super.delete(sender) }
        deleteKeepingSyntax(selectedRange())
    }

    private func perform(_ deletion: ConcealedEditing.Deletion) {
        guard case .edit(let edit) = deletion else { return }
        apply(edit, actionName: "削除")
    }

    /// Deletes `r` as it is shown (see ConcealedEditing.deletion).
    private func deleteKeepingSyntax(_ r: NSRange, replacing: Bool = false, actionName: String = "削除") {
        guard let storage = textStorage else { return }
        apply(ConcealedEditing.deletion(of: r, in: storage, replacing: replacing), actionName: actionName)
    }

    // Other editing commands that would edit hidden syntax as if it were text.
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        concealedEditing ? insertNewline(sender) : super.insertNewlineIgnoringFieldEditor(sender)
    }

    override func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) {
        guard concealedEditing, let storage = textStorage,
              selectedRange().length > 0 || ConcealedEditing.onlySyntax(between: selectedRange().location - 1,
                                                                         and: selectedRange().location, in: storage)
        else { return super.deleteBackwardByDecomposingPreviousCharacter(sender) }
        deleteBackward(sender)
    }

    override func transpose(_ sender: Any?) {
        guard concealedEditing, let storage = textStorage else { return super.transpose(sender) }
        let p = selectedRange().location
        let near = max(p - 2, 0)..<min(p + 1, storage.length)
        if near.contains(where: { ConcealedEditing.onlySyntax(between: $0, and: $0 + 1, in: storage) }) { return NSSound.beep() }
        super.transpose(sender)
    }

    // 編集 > 変換: what is shown changes case; hidden syntax (a link's URL) stays as it is.
    override func uppercaseWord(_ sender: Any?) { changeCase({ $0.uppercased() }) { super.uppercaseWord(sender) } }
    override func lowercaseWord(_ sender: Any?) { changeCase({ $0.lowercased() }) { super.lowercaseWord(sender) } }
    override func capitalizeWord(_ sender: Any?) { changeCase({ $0.capitalized }) { super.capitalizeWord(sender) } }

    private func changeCase(_ change: (String) -> String, otherwise: () -> Void) {
        guard concealedEditing, let storage = textStorage else { return otherwise() }
        var r = selectedRange()
        if r.length == 0 { r = selectionRange(forProposedRange: r, granularity: .selectByWord) }
        let ns = storage.string as NSString
        let shown = (r.location..<NSMaxRange(r)).filter { !ConcealedEditing.onlySyntax(between: $0, and: $0 + 1, in: storage) }
        let units = shown.map { ns.character(at: $0) }
        let changed = Array(change(String(utf16CodeUnits: units, count: units.count)).utf16)
        // "ß" becomes "SS": the characters would no longer line up with the syntax between them.
        guard !shown.isEmpty, changed.count == units.count else { return shown.isEmpty ? () : NSSound.beep() }
        let result = NSMutableString(string: ns.substring(with: r))
        for (k, i) in shown.enumerated() where changed[k] != units[k] {
            result.replaceCharacters(in: NSRange(location: i - r.location, length: 1), with: String(utf16CodeUnits: [changed[k]], count: 1))
        }
        guard replace(r, with: result as String, actionName: "変換") else { return }
        setSelectedRange(r)
    }

    // MARK: Inserting (concealed)

    private var isDropping = false

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropping = true
        defer { isDropping = false }
        return super.performDragOperation(sender)
    }

    // Pasting goes through here (dropping too, which is left alone).
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if !isDropping { prepareForInsertion(of: pboard.string(forType: .string)) }
        return super.readSelection(from: pboard, type: type)
    }

    /// Before `text` (nil: not known yet, as when the IME starts) replaces the selection or goes at the
    /// caret: the selection is deleted as shown (the syntax of spans that reach outside it stays; a span
    /// whose text is replaced stays around the new text, as in Notion), and on a divider, which holds no
    /// text, a new line starts below it. Returns whether the text changed.
    @discardableResult
    private func prepareForInsertion(of text: String?) -> Bool {
        guard concealedEditing, let storage = textStorage else { return false }
        var changed = false
        if selectedRange().length > 0 {
            // Unless the new text could not stand in a span: a line break, or space at its ends.
            let fits = text.map { !$0.isEmpty && !$0.contains(where: \.isNewline) && !$0.first!.isWhitespace && !$0.last!.isWhitespace }
            deleteKeepingSyntax(selectedRange(), replacing: fits ?? true)
            changed = true
        }
        let line = ConcealedEditing.line(at: selectedRange().location, in: storage)
        if line.kind == .rule, text?.hasPrefix("\n") != true,
           replaceCharacters(in: NSRange(location: line.contentsEnd, length: 0), with: "\n", actionName: "改行") {
            setSelectedRange(NSRange(location: line.contentsEnd + 1, length: 0))
            changed = true
        }
        return changed
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        defer { openSlashMenuIfTyped(text) }
        let style = typingStyle
        if hasMarkedText() {
            // The IME commits: text composed after ⌘B gets its style now.
            let start = markedRange().location
            keepsTypingStyle = true
            super.insertText(string, replacementRange: replacementRange)
            keepsTypingStyle = false
            typingStyle = nil
            if let style, style.location == start {
                styleTyped(text, replacing: NSRange(location: start, length: (text as NSString).length), style)
            }
            makeToDoIfTyped(text)
            return
        }
        var replacementRange = replacementRange
        let atSelection = replacementRange.location == NSNotFound || replacementRange == selectedRange()
        if atSelection, prepareForInsertion(of: text) {
            replacementRange = NSRange(location: NSNotFound, length: 0)
        }
        let spaces = !text.isEmpty && text.allSatisfy { $0.isWhitespace && !$0.isNewline }
        if let style, atSelection, style.location == selectedRange().location, selectedRange().length == 0 {
            if spaces {
                // Spaces are typed as they are (a span cannot start or end with one); the style waits for text.
                keepsTypingStyle = true
                super.insertText(string, replacementRange: replacementRange)
                keepsTypingStyle = false
                var waiting = style
                waiting.location = selectedRange().location
                typingStyle = waiting
                return
            }
            typingStyle = nil
            if styleTyped(text, replacing: NSRange(location: style.location, length: 0), style) { return }
        }
        // Spaces at the end of bold (etc.) text: after its closing delimiter, as a span cannot end with a
        // space; what is typed next goes back inside it, so the text stays bold, as typing does in Notion.
        if concealedEditing, spaces, atSelection, selectedRange().length == 0, let storage = textStorage,
           let closings = ConcealedEditing.closings(endingTextAt: selectedRange().location, in: storage),
           replaceCharacters(in: NSRange(location: NSMaxRange(closings), length: 0), with: text, actionName: "入力") {
            setSelectedRange(NSRange(location: NSMaxRange(closings) + (text as NSString).length, length: 0))
            typingStyle = TypingStyle(location: selectedRange().location, resuming: closings)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
        // "---" becomes a divider and the caret moves to a new line below it, as in Notion.
        if concealsMarkdown, text == "-", let storage = textStorage {
            let caret = selectedRange().location
            let now = ConcealedEditing.line(at: caret, in: storage)
            let content = (storage.string as NSString).substring(with: NSRange(location: now.range.location,
                                                                               length: now.contentsEnd - now.range.location))
            if content == "---", caret == now.contentsEnd, now.kind != .code, now.kind != .fence {
                super.insertText("\n", replacementRange: NSRange(location: caret, length: 0))
            }
        }
        makeToDoIfTyped(text)
    }

    /// Notion's "[]": typed at the start of a line (or of a list item's text), the block becomes a to-do.
    /// "[/]" and "[>]" make one that is in progress or waiting.
    private func makeToDoIfTyped(_ text: String) {
        guard concealsMarkdown, text.hasSuffix("]"), let storage = textStorage, selectedRange().length == 0 else { return }
        let caret = selectedRange().location
        let ns = storage.string as NSString
        var state = TaskState.todo
        var typed = 2
        if caret >= 3, ns.character(at: caret - 3) == 0x5B, let signal = TaskState(character: ns.character(at: caret - 2)),
           signal.isSignal {
            state = signal
            typed = 3
        } else {
            guard caret >= 2, ns.substring(with: NSRange(location: caret - 2, length: 2)) == "[]" else { return }
        }
        let bracket = caret - typed
        let line = ConcealedEditing.line(at: caret, in: storage)
        let marker: String
        switch line.kind {
        case .text:
            // Indentation before it nests the to-do.
            let before = ns.substring(with: NSRange(location: line.range.location, length: bracket - line.range.location))
            guard before.allSatisfy({ $0 == " " || $0 == "\t" }) else { return }
            marker = "- [\(state.rawValue)] "
        case .bullet, .ordered:
            guard let prefix = line.prefix, NSMaxRange(prefix) == bracket else { return }
            marker = "[\(state.rawValue)] "
        default:
            return
        }
        if replaceCharacters(in: NSRange(location: bracket, length: typed), with: marker, actionName: "チェックボックス") {
            setSelectedRange(NSRange(location: bracket + (marker as NSString).length, length: 0))
        }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        var replacementRange = replacementRange
        // Composition starting over a selection or on a divider: as for typing (see prepareForInsertion).
        if !hasMarkedText(), replacementRange.location == NSNotFound || replacementRange == self.selectedRange(),
           prepareForInsertion(of: nil) {
            replacementRange = NSRange(location: NSNotFound, length: 0)
        }
        if !hasMarkedText() { prepareCompositionAttributes() }
        keepsTypingStyle = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        keepsTypingStyle = false
    }

    /// The typing attributes before a composition in a card changed them.
    private var plainTypingAttributes: [NSAttributedString.Key: Any]?

    /// What text typed on the caret's line needs to stay part of a card: the line's paragraph style (its
    /// place in the card) and the card's marks. Empty outside a card.
    func cardTypingAttributes() -> [NSAttributedString.Key: Any] {
        guard let storage = textStorage else { return [:] }
        let line = ConcealedEditing.line(at: selectedRange().location, in: storage).range.location
        guard line < storage.length, storage.attribute(.mdCard, at: line, effectiveRange: nil) != nil else { return [:] }
        var attributes: [NSAttributedString.Key: Any] = [:]
        for key in [NSAttributedString.Key.paragraphStyle, .mdCard, .mdCardColor] {
            attributes[key] = storage.attribute(key, at: line, effectiveRange: nil)
        }
        return attributes
    }

    /// Text being composed is not restyled until it is committed. On an empty line of a card it is the
    /// paragraph's first character, whose style the paragraph takes: without the line's own style the
    /// text would jump out of the card while it is composed, and split the card in two. So in a card
    /// what is composed starts with the line's paragraph style and the card's marks.
    private func prepareCompositionAttributes() {
        let card = cardTypingAttributes()
        if card.isEmpty {
            guard let plain = plainTypingAttributes else { return }
            typingAttributes = plain
            plainTypingAttributes = nil
        } else {
            if plainTypingAttributes == nil { plainTypingAttributes = typingAttributes }
            typingAttributes = typingAttributes.merging(card) { _, new in new }
        }
    }

    // MARK: Formatting (書式), with Notion's shortcuts: ⌘B, ⌘I, ⇧⌘S, ⌘E, ⌘K

    @objc func toggleBold(_ sender: Any?) { toggleInline(.bold, actionName: "太字") }
    @objc func toggleItalic(_ sender: Any?) { toggleInline(.italic, actionName: "斜体") }
    @objc func toggleStrikethrough(_ sender: Any?) { toggleInline(.strike, actionName: "取り消し線") }
    @objc func toggleInlineCode(_ sender: Any?) { toggleInline(.code, actionName: "コード") }

    /// After ⌘B (etc.) with nothing selected, what is typed next at the caret gets the styles `adding`,
    /// or is typed outside the span of style `leaving` the caret is in — as typing works in Notion.
    private struct TypingStyle {
        var location: Int
        var adding: Set<MarkdownSpan> = []
        var leaving: MarkdownSpan?
        /// Spaces typed at the end of a span's text went after these closing delimiters; text typed next
        /// goes back inside the span (the delimiters move after it).
        var resuming: NSRange?
    }

    private var typingStyle: TypingStyle?
    /// Set while the text view itself moves the caret for typing, which keeps `typingStyle`.
    private var keepsTypingStyle = false

    /// Gives what the selection shows the style, or takes it away if all of it has it already. With
    /// nothing selected, the style applies to what is typed next.
    private func toggleInline(_ kind: MarkdownSpan, actionName: String) {
        guard !hasMarkedText(), isEditable, let storage = textStorage else { return }
        let selection = selectedRange()
        guard selection.length > 0 else { return toggleTypingStyle(kind) }
        let ns = storage.string as NSString
        // Each line's part of the selection (in line coordinates); dividers and code are left out.
        var parts: [(line: NSRange, text: String, part: NSRange)] = []
        var location = selection.location
        repeat {
            let line = ConcealedEditing.line(at: location, in: storage)
            let lineRange = NSRange(location: line.range.location, length: line.contentsEnd - line.range.location)
            let part = NSIntersectionRange(selection, line.content)
            if line.holdsInlineText, part.length > 0 {
                let text = ns.substring(with: lineRange)
                let relative = NSRange(location: part.location - lineRange.location, length: part.length)
                if InlineFormatting.showsText(in: relative, line: text) { parts.append((lineRange, text, relative)) }
            }
            location = NSMaxRange(line.range)
        } while location < NSMaxRange(selection) && location < storage.length
        guard !parts.isEmpty else { return NSSound.beep() }
        let styled = parts.map { InlineFormatting.has(kind, in: $0.part, line: $0.text) }
        let adding = styled.contains(false)
        var results: [(line: NSRange, text: String, selection: NSRange)] = []
        for (part, isStyled) in zip(parts, styled) {
            if adding, isStyled { // has it already: stays as it is
                results.append((part.line, part.text, NSRange(location: part.line.location + part.part.location, length: part.part.length)))
                continue
            }
            guard let result = InlineFormatting.toggle(kind, adding: adding, in: part.part, line: part.text) else {
                return NSSound.beep()
            }
            results.append((part.line, result.text,
                            NSRange(location: part.line.location + result.selection.location, length: result.selection.length)))
        }
        // One change for all the lines, so that the note is restyled once.
        let region = NSRange(location: results[0].line.location, length: NSMaxRange(results[results.count - 1].line) - results[0].line.location)
        let text = NSMutableString(string: ns.substring(with: region))
        for result in results.reversed() {
            text.replaceCharacters(in: NSRange(location: result.line.location - region.location, length: result.line.length), with: result.text)
        }
        guard replace(region, with: text as String, actionName: actionName) else { return }
        // The same characters stay selected; lines above the last one may have grown or shrunk.
        let shift = results.dropLast().reduce(0) { $0 + ($1.text as NSString).length - $1.line.length }
        let start = results[0].selection.location, end = NSMaxRange(results[results.count - 1].selection) + shift
        setSelectedRange(NSRange(location: start, length: end - start))
    }

    private func toggleTypingStyle(_ kind: MarkdownSpan) {
        guard let storage = textStorage else { return }
        let p = selectedRange().location
        // Pressed again before typing: taken back.
        if var style = typingStyle, style.location == p {
            if style.resuming != nil {
                typingStyle = nil // after "**bold** " the next text stays plain
                return
            }
            if style.leaving == kind {
                style.leaving = nil
            } else if style.adding.contains(kind) {
                style.adding.remove(kind)
            } else if style.leaving == nil {
                style.adding.insert(kind)
            }
            typingStyle = style.adding.isEmpty && style.leaving == nil ? nil : style
            return
        }
        let line = ConcealedEditing.line(at: p, in: storage)
        guard line.holdsInlineText else { return NSSound.beep() }
        // In text of that style: at its ends the caret leaves the span; inside, what is typed next goes
        // outside it.
        if let span = ConcealedEditing.spans(in: line, of: storage).last(where: {
            InlineFormatting.includes($0, kind) && $0.content.location <= p && p <= NSMaxRange($0.content)
        }) {
            if p == NSMaxRange(span.content) {
                setSelectedRange(NSRange(location: NSMaxRange(span.range), length: 0))
                // Bold italic keeps its other style for what follows.
                if span.kind == .boldItalic { typingStyle = TypingStyle(location: selectedRange().location, adding: [kind == .bold ? .italic : .bold]) }
                return
            }
            if p == span.content.location { return setSelectedRange(NSRange(location: span.range.location, length: 0)) }
            typingStyle = TypingStyle(location: p, leaving: kind)
            return
        }
        // Right after (or before) text of that style: typing goes on inside its span, rather than in a new
        // span next to it ("**ab****c**", which other Markdown readers — Notion's — read differently).
        if let span = ConcealedEditing.spans(in: line, of: storage).last(where: { $0.kind == kind && NSMaxRange($0.range) == p }) {
            return setSelectedRange(NSRange(location: span.closing.location, length: 0))
        }
        if let span = ConcealedEditing.spans(in: line, of: storage).first(where: { $0.kind == kind && $0.range.location == p }) {
            return setSelectedRange(NSRange(location: NSMaxRange(span.opening), length: 0))
        }
        typingStyle = TypingStyle(location: p, adding: [kind])
    }

    /// Puts text typed after ⌘B (etc.) in its style. `range` is where it goes (empty), or where the IME
    /// has just committed it. Returns false if Markdown cannot write it (it is then left as typed).
    @discardableResult
    private func styleTyped(_ text: String, replacing range: NSRange, _ style: TypingStyle) -> Bool {
        guard let storage = textStorage else { return false }
        let ns = storage.string as NSString
        if let closings = style.resuming {
            // Back inside the span: its closing delimiters move after the spaces and the text.
            let spaces = NSRange(location: NSMaxRange(closings), length: range.location - NSMaxRange(closings))
            guard spaces.length >= 0, !text.contains(where: \.isNewline),
                  ns.substring(with: spaces).allSatisfy({ $0.isWhitespace && !$0.isNewline }) else { return false }
            let inside = ns.substring(with: spaces) + text
            guard replace(NSRange(location: closings.location, length: NSMaxRange(range) - closings.location),
                          with: inside + ns.substring(with: closings), actionName: "入力") else { return false }
            setSelectedRange(NSRange(location: closings.location + (inside as NSString).length, length: 0))
            return true
        }
        let line = ConcealedEditing.line(at: range.location, in: storage)
        let lineRange = NSRange(location: line.range.location, length: line.contentsEnd - line.range.location)
        guard line.holdsInlineText, NSMaxRange(range) <= line.contentsEnd else { return false }
        let current = NSMutableString(string: ns.substring(with: lineRange))
        current.replaceCharacters(in: NSRange(location: range.location - lineRange.location, length: range.length), with: "")
        guard let result = InlineFormatting.typing(text, at: range.location - lineRange.location, in: current as String,
                                                   adding: style.adding, leaving: style.leaving),
              replace(lineRange, with: result.text, actionName: "入力") else { return false }
        setSelectedRange(NSRange(location: lineRange.location + result.caret, length: 0))
        return true
    }

    /// ⌘K: asks for the URL, then makes the selection a link to it (with nothing selected, inserts the
    /// URL as a link).
    @objc func insertLink(_ sender: Any?) {
        guard !hasMarkedText(), isEditable else { return }
        let alert = NSAlert()
        alert.messageText = "リンク"
        alert.informativeText = "リンク先の URL を入力してください。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "https://"
        if let clip = NSPasteboard.general.string(forType: .string), NotionMarkdown.isLinkTarget(clip) {
            field.stringValue = clip
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "追加")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let url = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        makeLink(to: url)
    }

    /// Makes the selection (on one line) a link to `url`; with nothing selected, inserts the URL as a link.
    func makeLink(to url: String) {
        guard !hasMarkedText(), isEditable, let storage = textStorage else { return }
        // Markdown ends a link's target at a space or a parenthesis.
        let target = url.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
        let r = selectedRange()
        let line = ConcealedEditing.line(at: r.location, in: storage)
        let lineRange = NSRange(location: line.range.location, length: line.contentsEnd - line.range.location)
        guard line.holdsInlineText, NSMaxRange(r) <= line.contentsEnd else { return NSSound.beep() }
        let part = r.length > 0 ? NSIntersectionRange(r, line.content) : NSRange(location: max(r.location, line.contentStart), length: 0)
        guard r.length == 0 || part.length > 0,
              let result = InlineFormatting.link(to: target, in: NSRange(location: part.location - lineRange.location, length: part.length),
                                                 line: (storage.string as NSString).substring(with: lineRange)),
              replace(lineRange, with: result.text, actionName: "リンク") else { return NSSound.beep() }
        setSelectedRange(NSRange(location: lineRange.location + result.selection.location, length: result.selection.length))
    }

    /// Inserts a divider (Notion's /divider): an empty line becomes one, otherwise it goes below the
    /// line; the caret moves to a new line below it.
    @objc func insertDivider(_ sender: Any?) {
        guard !hasMarkedText(), isEditable, let storage = textStorage else { return }
        let line = ConcealedEditing.line(at: selectedRange().location, in: storage)
        let contents = NSRange(location: line.range.location, length: line.contentsEnd - line.range.location)
        if (storage.string as NSString).substring(with: contents).trimmingCharacters(in: .whitespaces).isEmpty {
            replaceCharacters(in: contents, with: "---\n", actionName: "区切り線")
            setSelectedRange(NSRange(location: contents.location + 4, length: 0))
        } else {
            replaceCharacters(in: NSRange(location: line.contentsEnd, length: 0), with: "\n---\n", actionName: "区切り線")
            setSelectedRange(NSRange(location: line.contentsEnd + 5, length: 0))
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, let location = attributeValue(.mdTaskToggle, under: event, precise: true) as? Int {
            clickTask(checkLocation: location, option: event.modifierFlags.contains(.option))
            return
        }
        if event.modifierFlags.contains(.command), let url = attributeValue(.mdLink, under: event, precise: false) as? URL {
            NSWorkspace.shared.open(url)
            return
        }
        if event.clickCount == 1, clickCard(event) || clickBelowLastCard(event) { return }
        super.mouseDown(with: event)
    }

    // MARK: Cards

    /// The point of a mouse event in the text container's coordinates (the layout manager's).
    func containerPoint(_ event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        return NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
    }

    /// A press on a card's "•••" opens its menu. A press on its frame — anywhere on the card but on its
    /// text — is followed (see trackCardPress): a click puts the caret, a drag moves the card.
    private func clickCard(_ event: NSEvent) -> Bool {
        guard concealsMarkdown, !hasMarkedText(), let layout = layoutManager as? ConcealingLayoutManager else { return false }
        let point = containerPoint(event)
        guard let card = layout.cardGeometries().first(where: { $0.frame.contains(point) }) else { return false }
        if card.menuArea.contains(point) {
            let menu = cardMenu(forCardAt: card.range.location)
            let below = NSPoint(x: card.dots.minX + textContainerOrigin.x, y: card.dots.maxY + 6 + textContainerOrigin.y)
            menu.popUp(positioning: nil, at: below, in: self)
            return true
        }
        guard card.panel?.contains(point) != true else { return false } // on its text: a click in the text
        trackCardPress(on: card, event)
        return true
    }

    /// A click under a card that ends the note: a new line there, to write below the card.
    private func clickBelowLastCard(_ event: NSEvent) -> Bool {
        guard concealsMarkdown, isEditable, !hasMarkedText(), let layout = layoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0,
              ConcealedEditing.line(at: storage.length, in: storage).kind.isHiddenLine,
              containerPoint(event).y > layout.usedRect(for: container).maxY else { return false }
        window?.makeFirstResponder(self)
        if replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "\n", actionName: "改行") {
            setSelectedRange(NSRange(location: storage.length, length: 0))
        }
        return true
    }

    /// The menu of a card (its "•••"): its color, and taking the card away with or without what is in it.
    func cardMenu(forCardAt location: Int) -> NSMenu {
        let menu = NSMenu()
        let current = (textStorage?.attribute(.mdCardColor, at: min(location, max((textStorage?.length ?? 1) - 1, 0)), effectiveRange: nil) as? String)
            .flatMap(CardColor.init)
        for (index, color) in CardColor.allCases.enumerated() {
            let item = NSMenuItem(title: color.title, action: #selector(setCardColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = location
            item.state = color == current ? .on : .off
            item.image = Self.swatch(color)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, action) in [("カードを解除", #selector(unwrapCard(_:))), ("カードを削除", #selector(deleteCard(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = location
            menu.addItem(item)
        }
        return menu
    }

    /// A color as its tag is drawn.
    static func swatch(_ color: CardColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.tag.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            return true
        }
    }

    /// The card an action is for: the one its menu item was made for, or the one the caret is in.
    private func card(for sender: Any?) -> ConcealedEditing.Card? {
        guard !hasMarkedText(), isEditable, let storage = textStorage else { return nil }
        if let location = (sender as? NSMenuItem)?.representedObject as? Int {
            return ConcealedEditing.card(at: location, in: storage)
        }
        return ConcealedEditing.card(around: selectedRange().location, in: storage)
    }

    /// 書式 > カードの色, and a card's own menu (the item's tag is the index in `CardColor.allCases`).
    @objc func setCardColor(_ sender: NSMenuItem) {
        guard CardColor.allCases.indices.contains(sender.tag), let card = card(for: sender), let prefix = card.open.prefix else {
            return NSSound.beep()
        }
        let color = CardColor.allCases[sender.tag]
        apply([(prefix, CardSyntax.openLine(color: color, title: ""))], actionName: "カードの色")
    }

    /// Takes the card away and keeps its title and its text.
    @objc func unwrapCard(_ sender: Any?) {
        guard let card = card(for: sender), let storage = textStorage, let edit = ConcealedEditing.unwrapping(card, in: storage)
        else { return NSSound.beep() }
        apply(edit, actionName: "カードを解除")
    }

    @objc func deleteCard(_ sender: Any?) {
        guard let card = card(for: sender), let storage = textStorage, let edit = ConcealedEditing.removing(card, in: storage)
        else { return NSSound.beep() }
        apply(edit, actionName: "カードを削除")
    }

    /// 書式 > カードを挿入: a new card on the caret's line if that is empty, otherwise below it — below the
    /// whole card (and the row it stands in), if the caret is in one, as cards do not nest. With lines
    /// selected, they become the card's text. The caret goes to the title.
    @objc func insertCard(_ sender: Any?) {
        guard !hasMarkedText(), isEditable, let storage = textStorage else { return }
        let ns = storage.string as NSString
        let selection = selectedRange()
        let open = CardSyntax.openLine(color: .default, title: "")
        let first = ConcealedEditing.line(at: selection.location, in: storage)
        var last = ConcealedEditing.line(at: NSMaxRange(selection), in: storage)
        if selection.length > 0, NSMaxRange(selection) == last.range.location, last.range.location > first.range.location {
            last = ConcealedEditing.line(at: NSMaxRange(selection) - 1, in: storage) // the selection ends before that line
        }
        var range = NSRange(location: first.range.location, length: last.contentsEnd - first.range.location)
        var text = ""
        var touchesCard = false
        storage.enumerateAttribute(.mdCard, in: NSRange(location: range.location, length: min(range.length + 1, storage.length - range.location))) {
            value, _, _ in if value != nil { touchesCard = true }
        }
        if let card = ConcealedEditing.card(around: selection.location, in: storage) ?? (touchesCard ? ConcealedEditing.card(around: NSMaxRange(selection), in: storage) : nil) {
            // After that card — after the whole row, if it stands in one (a new card stands on its own).
            let anchor = ConcealedEditing.row(at: card.range.location, in: storage)?.close ?? card.close
            let end = anchor.contentsEnd
            range = NSRange(location: end, length: 0)
            text = "\n" + open + "\n\n" + CardSyntax.closeMarker + (anchor.hasNewline ? "" : "\n")
            guard replaceCharacters(in: range, with: text, actionName: "カードを挿入") else { return }
            setSelectedRange(NSRange(location: end + 1 + (open as NSString).length, length: 0))
        } else if touchesCard {
            NSSound.beep() // the selection runs into a card
        } else if selection.length > 0 || first.contentsEnd > first.range.location {
            if selection.length > 0 {
                // The selected lines become the card's text.
                text = open + "\n" + ns.substring(with: range) + "\n" + CardSyntax.closeMarker + (last.hasNewline ? "" : "\n")
                guard replace(range, with: text, actionName: "カードを挿入") else { return }
                setSelectedRange(NSRange(location: range.location + (open as NSString).length, length: 0))
            } else {
                // Below the caret's line.
                let end = first.contentsEnd
                text = "\n" + open + "\n\n" + CardSyntax.closeMarker + (first.hasNewline ? "" : "\n")
                guard replaceCharacters(in: NSRange(location: end, length: 0), with: text, actionName: "カードを挿入") else { return }
                setSelectedRange(NSRange(location: end + 1 + (open as NSString).length, length: 0))
            }
        } else {
            // On the caret's empty line.
            text = open + "\n\n" + CardSyntax.closeMarker + (first.hasNewline ? "" : "\n")
            guard replaceCharacters(in: NSRange(location: first.range.location, length: 0), with: text, actionName: "カードを挿入") else { return }
            setSelectedRange(NSRange(location: first.range.location + (open as NSString).length, length: 0))
        }
        scrollRangeToVisible(selectedRange())
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // On a card's frame (not on its text): the card's menu.
        if concealsMarkdown, isEditable, !hasMarkedText(), let layout = layoutManager as? ConcealingLayoutManager {
            let point = containerPoint(event)
            if let card = layout.cardGeometries().first(where: { $0.frame.contains(point) }), card.panel?.contains(point) != true,
               !card.tags.contains(where: { $0.contains(point) }) {
                return cardMenu(forCardAt: card.range.location)
            }
        }
        let menu = super.menu(for: event)
        guard concealsMarkdown, isEditable, !hasMarkedText(), let storage = textStorage, let menu else { return menu }
        // On a to-do: its states first. With several lines selected and the click among them, for them all.
        let clicked = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let selection = selectedRange()
        let inSelection = selection.length > 0 && clicked >= selection.location && clicked <= NSMaxRange(selection)
        let checks = taskChecks(in: inSelection ? selection : NSRange(location: clicked, length: 0), storage)
        guard !checks.isEmpty else { return menu }
        let ns = storage.string as NSString
        let states = Set(checks.map { TaskState(character: ns.character(at: $0)) ?? .todo })
        for (index, state) in TaskState.allCases.enumerated() {
            let item = NSMenuItem(title: state.title, action: #selector(setTaskStateOfClickedLines(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = checks
            item.state = states == [state] ? .on : .off
            item.image = taskStateImage(state)
            menu.insertItem(item, at: index)
        }
        menu.insertItem(.separator(), at: TaskState.allCases.count)
        return menu
    }

    // MARK: To-do states (the signals)

    /// A click on a to-do's checkbox or signal moves it one step on; with ⌥ it waits (see TaskState).
    func clickTask(checkLocation: Int, option: Bool) {
        changeTasks(at: [checkLocation], option ? .toggleWaiting : .advance)
    }

    /// ⌘Return: the to-dos on the selected lines move one step on, as with a click.
    @objc func advanceTask(_ sender: Any?) {
        guard let storage = textStorage else { return }
        changeTasks(at: taskChecks(in: selectedRange(), storage), .advance)
    }

    /// ⌥⌘Return: the to-dos on the selected lines wait, as with an ⌥-click.
    @objc func toggleTaskWaiting(_ sender: Any?) {
        guard let storage = textStorage else { return }
        changeTasks(at: taskChecks(in: selectedRange(), storage), .toggleWaiting)
    }

    /// 書式 > タスクの状態: the selected lines become to-dos in that state (the item's tag is the index in
    /// `TaskState.allCases`). Text and list items become to-dos; other blocks are left alone.
    @objc func setTaskState(_ sender: NSMenuItem) {
        guard !hasMarkedText(), isEditable, let storage = textStorage, TaskState.allCases.indices.contains(sender.tag) else { return }
        let state = TaskState.allCases[sender.tag]
        let selection = selectedRange()
        let ns = storage.string as NSString
        var edits: [(range: NSRange, string: String)] = []
        var location = selection.location
        repeat {
            let line = ConcealedEditing.line(at: location, in: storage)
            if let check = taskCheck(of: line, storage) {
                edits.append((NSRange(location: check, length: 1), state.rawValue))
            } else if line.kind == .text {
                // After the indentation, which nests the to-do. Empty lines only at the caret.
                var start = line.range.location
                while start < line.contentsEnd, ns.character(at: start) == 0x20 || ns.character(at: start) == 0x09 { start += 1 }
                if start < line.contentsEnd || selection.length == 0 {
                    edits.append((NSRange(location: start, length: 0), "- [\(state.rawValue)] "))
                }
            } else if line.kind == .bullet || line.kind == .ordered, let prefix = line.prefix {
                edits.append((NSRange(location: NSMaxRange(prefix), length: 0), "[\(state.rawValue)] "))
            }
            location = NSMaxRange(line.range)
        } while location < NSMaxRange(selection) && location < storage.length
        guard !edits.isEmpty else { return NSSound.beep() }
        apply(edits, actionName: "タスクの状態")
    }

    @objc private func setTaskStateOfClickedLines(_ sender: NSMenuItem) {
        guard let checks = sender.representedObject as? [Int], TaskState.allCases.indices.contains(sender.tag) else { return }
        changeTasks(at: checks, .set(TaskState.allCases[sender.tag]))
    }

    private enum TaskChange {
        case advance, toggleWaiting
        case set(TaskState)
    }

    private func changeTasks(at checks: [Int], _ change: TaskChange) {
        guard !hasMarkedText(), isEditable, let storage = textStorage else { return }
        let ns = storage.string as NSString
        let checks = checks.filter { $0 < ns.length }
        guard !checks.isEmpty else { return NSSound.beep() }
        let states = checks.map { TaskState(character: ns.character(at: $0)) ?? .todo }
        // Several to-dos end up alike: all waiting, or (when all waited already) none.
        let allWaiting = states.allSatisfy { $0 == .waiting }
        let edits = zip(checks, states).map { check, state -> (range: NSRange, string: String) in
            let new: TaskState = switch change {
            case .advance: state.advanced
            case .toggleWaiting: allWaiting ? .todo : .waiting
            case .set(let state): state
            }
            return (NSRange(location: check, length: 1), new.rawValue)
        }
        apply(edits, actionName: "タスクの状態")
    }

    /// Where the states of the to-dos on the lines `selection` touches are written.
    private func taskChecks(in selection: NSRange, _ storage: NSTextStorage) -> [Int] {
        var checks: [Int] = []
        var location = selection.location
        repeat {
            let line = ConcealedEditing.line(at: location, in: storage)
            if let check = taskCheck(of: line, storage) { checks.append(check) }
            location = NSMaxRange(line.range)
        } while location < NSMaxRange(selection) && location < storage.length
        return checks
    }

    private func taskCheck(of line: ConcealedEditing.Line, _ storage: NSTextStorage) -> Int? {
        guard let prefix = line.prefix, prefix.length > 0 else { return nil }
        return storage.attribute(.mdTaskToggle, at: NSMaxRange(prefix) - 1, effectiveRange: nil) as? Int
    }

    private func taskStateImage(_ state: TaskState) -> NSImage? {
        (layoutManager as? ConcealingLayoutManager).map { TaskSignalIcon.image(state, theme: $0.theme) }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(advanceTask(_:)), #selector(toggleTaskWaiting(_:)):
            guard isEditable, !hasMarkedText(), let storage = textStorage else { return false }
            return !taskChecks(in: selectedRange(), storage).isEmpty
        case #selector(setTaskState(_:)):
            guard isEditable, !hasMarkedText(), let storage = textStorage else { return false }
            if let menuItem = item as? NSMenuItem, TaskState.allCases.indices.contains(menuItem.tag) {
                let ns = storage.string as NSString
                let states = Set(taskChecks(in: selectedRange(), storage).map { TaskState(character: ns.character(at: $0)) ?? .todo })
                menuItem.state = states == [TaskState.allCases[menuItem.tag]] ? .on : .off
            }
            return true
        case #selector(setCardColor(_:)), #selector(unwrapCard(_:)), #selector(deleteCard(_:)):
            guard let card = card(for: item as? NSMenuItem) else { return false }
            if item.action == #selector(setCardColor(_:)), let menuItem = item as? NSMenuItem,
               CardColor.allCases.indices.contains(menuItem.tag) {
                let color = textStorage?.attribute(.mdCardColor, at: card.range.location, effectiveRange: nil) as? String
                menuItem.state = color == CardColor.allCases[menuItem.tag].rawValue ? .on : .off
            }
            return true
        case #selector(insertCard(_:)):
            return isEditable && !hasMarkedText()
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: The "/" menu

    /// The "/" menu while it is open (see SlashCommand).
    private(set) var slashMenu: SlashMenu?
    private var slashPanel: SlashMenuPanel?
    /// Set while the text is changing: the selection moves with it, and the menu is refreshed once after.
    private var isChangingText = false

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        isChangingText = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        return isChangingText
    }

    override func didChangeText() {
        super.didChangeText()
        isChangingText = false
        if slashMenu != nil { refreshSlashMenu() }
    }

    // Esc closes the menu (otherwise it is the text view's: word completion).
    override func cancelOperation(_ sender: Any?) {
        if slashMenu != nil { return closeSlashMenu() }
        super.cancelOperation(sender)
    }

    override func resignFirstResponder() -> Bool {
        closeSlashMenu()
        return super.resignFirstResponder()
    }

    /// "/" (or "；") typed where a block's text starts or after a space opens the menu.
    private func openSlashMenuIfTyped(_ text: String) {
        guard slashMenu == nil, concealsMarkdown, isEditable, !hasMarkedText(), selectedRange().length == 0,
              let typed = text.utf16.first, text.utf16.count == 1, SlashCommand.isTrigger(typed), let storage = textStorage else { return }
        let trigger = selectedRange().location - 1
        let ns = storage.string as NSString
        guard trigger >= 0, trigger < ns.length, ns.character(at: trigger) == typed else { return }
        let line = ConcealedEditing.line(at: trigger, in: storage)
        guard line.holdsInlineText, storage.attribute(.mdCode, at: trigger, effectiveRange: nil) == nil else { return }
        let atStart = trigger == ConcealedEditing.visibleContentStart(of: line, in: storage)
        guard atStart || InlineFormatting.isSpace(ns.character(at: trigger - 1)) else { return }
        slashMenu = SlashMenu(trigger: trigger, commands: SlashCommand.matching(""))
        showSlashPanel()
    }

    /// After the text or the selection changed: what is typed after the "/" narrows the list. The menu
    /// closes when nothing fits, when a space is typed, and when the caret leaves what was typed.
    private func refreshSlashMenu() {
        guard var menu = slashMenu, let storage = textStorage else { return }
        let ns = storage.string as NSString
        let selection = selectedRange()
        guard selection.length == 0, menu.trigger < ns.length, SlashCommand.isTrigger(ns.character(at: menu.trigger)),
              selection.location > menu.trigger,
              selection.location <= ConcealedEditing.line(at: menu.trigger, in: storage).contentsEnd else { return closeSlashMenu() }
        let query = ns.substring(with: NSRange(location: menu.trigger + 1, length: selection.location - menu.trigger - 1))
        let commands = SlashCommand.matching(query)
        guard !commands.isEmpty, !query.contains(where: \.isWhitespace) else { return closeSlashMenu() }
        let chosen = menu.commands.indices.contains(menu.selected) ? menu.commands[menu.selected] : nil
        menu.commands = commands
        menu.selected = chosen.flatMap(commands.firstIndex(of:)) ?? 0
        guard menu != slashMenu else { return }
        slashMenu = menu
        showSlashPanel()
    }

    private func moveSlashSelection(by step: Int) {
        guard var menu = slashMenu, !menu.commands.isEmpty else { return }
        menu.selected = (menu.selected + step + menu.commands.count) % menu.commands.count
        slashMenu = menu
        showSlashPanel()
    }

    func closeSlashMenu() {
        slashMenu = nil
        slashPanel?.dismiss()
    }

    /// The list is a small window under the caret; without a window (a view that is not shown) the
    /// menu is kept all the same.
    private func showSlashPanel() {
        guard let menu = slashMenu, let window, let theme = (layoutManager as? ConcealingLayoutManager)?.theme else { return }
        let panel = slashPanel ?? SlashMenuPanel()
        slashPanel = panel
        panel.onChoose = { [weak self] index in
            guard let self, var menu = self.slashMenu, menu.commands.indices.contains(index) else { return }
            menu.selected = index
            self.slashMenu = menu
            self.acceptSlashCommand()
        }
        panel.show(menu, at: firstRect(forCharacterRange: NSRange(location: menu.trigger, length: 1), actualRange: nil),
                   in: window, theme: theme)
    }

    /// Return (or a click): what was typed for the menu goes, and the chosen command is done where it
    /// was typed — as one step for ⌘Z.
    func acceptSlashCommand() {
        guard let menu = slashMenu, menu.commands.indices.contains(menu.selected), !hasMarkedText() else { return closeSlashMenu() }
        let command = menu.commands[menu.selected]
        let typed = NSRange(location: menu.trigger, length: selectedRange().location - menu.trigger)
        closeSlashMenu()
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
            undoManager?.setActionName(command.title)
        }
        guard typed.length > 0, replaceCharacters(in: typed, with: "", actionName: command.title) else { return }
        setSelectedRange(NSRange(location: typed.location, length: 0))
        switch command {
        case .card:
            insertCard(nil)
        case .divider:
            insertDivider(nil)
        case .doing, .waiting, .todo:
            let item = NSMenuItem()
            item.tag = command.taskState.flatMap(TaskState.allCases.firstIndex(of:)) ?? 0
            setTaskState(item)
        }
    }

    // MARK: The pointer over a card

    /// Where the events come from while a press on a card is followed (see trackCardPress): the
    /// window's event queue, unless a test plays the mouse from here.
    var trackingEvents: ((NSEvent.EventTypeMask) -> NSEvent?)?

    private var cardTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = cardTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        cardTrackingArea = area
    }

    // A hand over a card's frame, which can be dragged; a pointing hand over "•••".
    override func mouseMoved(with event: NSEvent) {
        if let cursor = cardCursor(at: containerPoint(event)) { cursor.set() } else { super.mouseMoved(with: event) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if let cursor = cardCursor(at: containerPoint(event)) { cursor.set() } else { super.cursorUpdate(with: event) }
    }

    // MARK: To-dos in progress: the turning rings

    /// In a window (a note), the rings of the to-dos in progress are layers that turn (see
    /// TaskSpinnerOverlay). Anywhere else the layout manager draws them, still.
    private(set) var spinnerOverlay: TaskSpinnerOverlay?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        guard let window, let layoutManager = layoutManager as? ConcealingLayoutManager else {
            spinnerOverlay?.isAnimating = false
            return
        }
        if spinnerOverlay == nil {
            // A dot of a view at the origin: its layers reach over the text, the view itself is in nobody's way.
            let overlay = TaskSpinnerOverlay(color: layoutManager.theme.doingColor)
            overlay.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            addSubview(overlay)
            spinnerOverlay = overlay
            layoutManager.doingTasksAreAnimated = true
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(updateSpinnerAnimation),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(updateSpinnerAnimation),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
        updateSpinnerAnimation()
    }

    /// The rings turn while the note can be seen, unless 「視差効果を減らす」 is on.
    @objc private func updateSpinnerAnimation() {
        spinnerOverlay?.isAnimating = window?.occlusionState.contains(.visible) == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        updateTaskSpinners()
    }

    /// Puts a ring on each to-do in progress, where the layout manager would draw it.
    func updateTaskSpinners() {
        guard let overlay = spinnerOverlay, let layoutManager = layoutManager as? ConcealingLayoutManager,
              let storage = textStorage else { return }
        var rings: [TaskSpinnerOverlay.Ring] = []
        if layoutManager.concealsMarkdown, storage.length > 0 {
            let ns = storage.string as NSString
            let origin = textContainerOrigin
            storage.enumerateAttribute(.mdConcealBox, in: NSRange(location: 0, length: storage.length)) { value, run, _ in
                guard value != nil, let check = storage.attribute(.mdTaskToggle, at: run.location, effectiveRange: nil) as? Int,
                      check < ns.length, TaskState(character: ns.character(at: check)) == .doing,
                      let rect = layoutManager.taskIconRect(forCharacterAt: run.location) else { return }
                rings.append(TaskSpinnerOverlay.Ring(frame: rect.offsetBy(dx: origin.x, dy: origin.y),
                                                     opacity: Float(layoutManager.fade(at: run.location))))
            }
        }
        overlay.show(rings)
    }

    // MARK: Changing the text

    /// Replaces the whole text as one undoable step (used to restore a version from history).
    func replaceAllText(with string: String, actionName: String) {
        guard let storage = textStorage else { return }
        replaceCharacters(in: NSRange(location: 0, length: storage.length), with: string, actionName: actionName)
        setSelectedRange(NSRange(location: 0, length: 0))
        scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// Undoable replacement that goes through the normal NSTextView change pipeline. Returns false if
    /// the change was refused (e.g. the text is not editable).
    @discardableResult
    func replaceCharacters(in range: NSRange, with string: String, actionName: String) -> Bool {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: string) else { return false }
        let selection = selectedRange()
        storage.replaceCharacters(in: range, with: string)
        didChangeText()
        undoManager?.setActionName(actionName)
        let delta = (string as NSString).length - range.length
        let caret = selection.location >= NSMaxRange(range) ? selection.location + delta : range.location
        setSelectedRange(NSRange(location: min(max(caret, 0), storage.length), length: 0))
        return true
    }

    /// Makes several replacements (in order, not overlapping) as one undoable change. The selection keeps
    /// covering the same text; a caret where text is inserted ends up after that text.
    @discardableResult
    private func apply(_ edits: [(range: NSRange, string: String)], actionName: String) -> Bool {
        guard let storage = textStorage, let first = edits.first, let last = edits.last else { return false }
        let region = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        let text = NSMutableString(string: (storage.string as NSString).substring(with: region))
        for edit in edits.reversed() {
            text.replaceCharacters(in: NSRange(location: edit.range.location - region.location, length: edit.range.length),
                                   with: edit.string)
        }
        func moved(_ p: Int) -> Int {
            edits.reduce(p) { result, edit in
                NSMaxRange(edit.range) <= p ? result + (edit.string as NSString).length - edit.range.length : result
            }
        }
        let selection = selectedRange()
        let start = moved(selection.location), end = moved(NSMaxRange(selection))
        guard replace(region, with: text as String, actionName: actionName) else { return false }
        setSelectedRange(NSRange(location: start, length: max(end - start, 0)))
        return true
    }

    /// Makes `edit` and puts the caret where it says.
    func apply(_ edit: ConcealedEditing.Edit, actionName: String) {
        if edit.range.length > 0 || !edit.string.isEmpty {
            guard replace(edit.range, with: edit.string, actionName: actionName) else { return }
        }
        setSelectedRange(NSRange(location: edit.caret, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// Replaces `range` with `string`, changing only the part that differs, so that undo selects just
    /// that (not a whole rewritten line, which the next key press would replace).
    @discardableResult
    private func replace(_ range: NSRange, with string: String, actionName: String) -> Bool {
        guard let storage = textStorage else { return false }
        let edit = ConcealedEditing.minimal(ConcealedEditing.Edit(range: range, string: string, caret: 0), in: storage)
        guard edit.range.length > 0 || !edit.string.isEmpty else { return true }
        return replaceCharacters(in: edit.range, with: edit.string, actionName: actionName)
    }

    /// Attribute value under the mouse. `precise` also requires the pointer to be inside the
    /// run's glyph rectangle (so clicking just after a checkbox places the caret instead).
    private func attributeValue(_ key: NSAttributedString.Key, under event: NSEvent, precise: Bool) -> Any? {
        guard let storage = textStorage, let window, storage.length > 0 else { return nil }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            var run = NSRange()
            guard let value = storage.attribute(key, at: candidate, effectiveRange: &run) else { continue }
            if !precise { return value }
            let rect = firstRect(forCharacterRange: run, actualRange: nil).insetBy(dx: -2, dy: -2)
            if rect.contains(screenPoint) { return value }
        }
        return nil
    }
}
