import AppKit

final class MarkdownTextView: NSTextView {
    /// Markdown syntax is concealed (the default), and the editing keys follow Notion; off while
    /// 「Markdown記号をすべて表示」 shows the raw text.
    var concealsMarkdown = true

    // MARK: Return, Tab

    // Return continues a list / task list; Return on an empty item ends the list. Concealed, it also
    // follows Notion's other rules (see ConcealedEditing.newline). While the IME is composing, Return
    // commits the composition and never reaches this method, but guard on marked text anyway.
    override func insertNewline(_ sender: Any?) {
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
        guard let line = currentListLine() else { return super.insertTab(sender) }
        replaceCharacters(in: NSRange(location: line.range.location, length: 0), with: "\t", actionName: "字下げ")
    }

    override func insertBacktab(_ sender: Any?) {
        guard let line = currentListLine(), let storage = textStorage else { return super.insertBacktab(sender) }
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
    private func makeToDoIfTyped(_ text: String) {
        guard concealsMarkdown, text.hasSuffix("]"), let storage = textStorage, selectedRange().length == 0 else { return }
        let caret = selectedRange().location
        let ns = storage.string as NSString
        guard caret >= 2, ns.substring(with: NSRange(location: caret - 2, length: 2)) == "[]" else { return }
        let bracket = caret - 2
        let line = ConcealedEditing.line(at: caret, in: storage)
        let marker: String
        switch line.kind {
        case .text:
            // Indentation before it nests the to-do.
            let before = ns.substring(with: NSRange(location: line.range.location, length: bracket - line.range.location))
            guard before.allSatisfy({ $0 == " " || $0 == "\t" }) else { return }
            marker = "- [ ] "
        case .bullet, .ordered:
            guard let prefix = line.prefix, NSMaxRange(prefix) == bracket else { return }
            marker = "[ ] "
        default:
            return
        }
        if replaceCharacters(in: NSRange(location: bracket, length: 2), with: marker, actionName: "チェックボックス") {
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
        keepsTypingStyle = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        keepsTypingStyle = false
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
            toggleTask(checkLocation: location)
            return
        }
        if event.modifierFlags.contains(.command), let url = attributeValue(.mdLink, under: event, precise: false) as? URL {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    private func toggleTask(checkLocation: Int) {
        guard let storage = textStorage, checkLocation < storage.length else { return }
        let range = NSRange(location: checkLocation, length: 1)
        let current = (storage.string as NSString).substring(with: range)
        replaceCharacters(in: range, with: current == " " ? "x" : " ", actionName: "チェックボックスの切り替え")
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

    /// Makes `edit` and puts the caret where it says.
    private func apply(_ edit: ConcealedEditing.Edit, actionName: String) {
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
