import AppKit
import Testing
@testable import FusenCore

/// Rows of cards: "::::columns" … "::::" around cards that stand side by side.
@MainActor
struct CardRowTests {
    private let theme = MarkdownTheme()
    private let two = "本文\n::::columns\n:::card orange A\n- [/] 一\n- [ ] 二\n- [ ] 三\n:::\n:::card purple B\n短い\n:::\n::::\nおわり"

    private func editor(_ text: String, width: CGFloat = 300) -> ConcealedEditor {
        let e = ConcealedEditor(text, width: width)
        e.styler.restyle(e.storage, width: width)
        e.layoutManager.ensureLayout(for: e.layoutManager.textContainers[0])
        return e
    }

    @Test func theCardsOfARowStandSideBySide() throws {
        let e = editor(two)
        let cards = e.layoutManager.cardGeometries()
        try #require(cards.count == 2)
        let container = e.layoutManager.textContainers[0]
        let padding = container.lineFragmentPadding
        // Next to each other, equally wide, equally tall, 10pt apart, filling the line.
        #expect(abs(cards[0].frame.minY - cards[1].frame.minY) < 0.5)
        #expect(abs(cards[0].frame.height - cards[1].frame.height) < 0.5)
        #expect(abs(cards[0].frame.width - cards[1].frame.width) < 1)
        #expect(abs(cards[1].frame.minX - cards[0].frame.maxX - theme.cardRowGap) < 1)
        #expect(abs(cards[0].frame.minX - padding) < 0.5)
        #expect(abs(cards[1].frame.maxX - (container.size.width - padding)) < 1)
        // The lines around the row take no room: the cards are as far from the text as a card on its own.
        let above = e.layoutManager.lineFragmentRect(forGlyphAt: e.layoutManager.glyphIndexForCharacter(at: 0), effectiveRange: nil)
        let below = e.layoutManager.lineFragmentRect(forGlyphAt: e.layoutManager.glyphIndexForCharacter(at: e.index(of: "おわり")), effectiveRange: nil)
        #expect(abs(cards[0].frame.minY - above.maxY - theme.cardGap) < 0.5)
        #expect(abs(below.minY - cards[0].frame.maxY - theme.cardGap) < 0.5)
        if let dir = ProcessInfo.processInfo.environment["MARKDOWN_STICKIES_RENDER_DIR"] {
            try e.png()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("row-two.png"))
        }
    }

    // MARK: Editing in a row (in a window, as the keyboard does it)

    private func withEditor(_ text: String, width: CGFloat = 320, _ body: @MainActor (ConcealedEditor) -> Void) {
        let e = ConcealedEditor(text, width: width)
        let window = NSWindow(contentRect: e.textView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = e.textView
        window.makeFirstResponder(e.textView)
        defer { window.orderOut(nil) }
        e.textView.textContainerInset = NSSize(width: 6, height: 8)
        NoteWindowController.restyle(e.textView, with: e.styler)
        e.layoutManager.ensureLayout(for: e.layoutManager.textContainers[0])
        body(e)
    }

    private func end(_ e: ConcealedEditor, _ text: String) -> Int { e.index(of: text) + (text as NSString).length }

    private func command(_ e: ConcealedEditor, _ selector: Selector) { e.key { e.textView.doCommand(by: selector) } }

    /// Side by side still: the same top, and B to the right of A.
    private func standSideBySide(_ e: ConcealedEditor) -> Bool {
        let cards = e.layoutManager.cardGeometries()
        return cards.count >= 2 && abs(cards[0].frame.minY - cards[1].frame.minY) < 0.5 && cards[1].frame.minX > cards[0].frame.maxX
    }

    @Test func typingInACardOfARow() {
        withEditor(two) { e in
            #expect(standSideBySide(e))
            e.click(end(e, "短い"))
            e.type("文")
            e.key { e.textView.insertNewline(nil) }
            e.type("[]二行目")
            #expect(e.text.contains(":::card purple B\n短い文\n- [ ] 二行目\n:::\n::::"))
            #expect(standSideBySide(e))
            e.key { e.textView.deleteBackward(nil) }
            e.undo.undo()
            #expect(standSideBySide(e))
            // The title too.
            e.click(end(e, "card orange A"))
            e.type("の名前")
            #expect(e.text.contains(":::card orange Aの名前\n"))
            #expect(standSideBySide(e))
            let cards = e.layoutManager.cardGeometries()
            #expect(abs(cards[0].frame.height - cards[1].frame.height) < 0.5)
        }
    }

    @Test func leftAndRightGoThroughTheCardsInTheOrderTheyAreWritten() {
        withEditor(two) { e in
            e.click(end(e, "- [ ] 三"))
            command(e, #selector(NSResponder.moveRight(_:)))
            #expect(e.caret == e.index(of: "B\n"))                 // the next card's title
            command(e, #selector(NSResponder.moveLeft(_:)))
            #expect(e.caret == end(e, "- [ ] 三"))
            e.click(end(e, "短い"))
            command(e, #selector(NSResponder.moveRight(_:)))
            #expect(e.caret == e.index(of: "おわり"))               // past the row
            command(e, #selector(NSResponder.moveLeft(_:)))
            #expect(e.caret == end(e, "短い"))
            e.click(e.index(of: "A\n"))
            command(e, #selector(NSResponder.moveLeft(_:)))
            #expect(e.caret == end(e, "本文"))                      // before the row
            command(e, #selector(NSResponder.moveRight(_:)))
            #expect(e.caret == e.index(of: "A\n"))
        }
    }

    @Test func upAndDownStayInTheirColumn() {
        let text = "一二三四五六七八九十一二三四五六七八九十\n" + two.dropFirst(3) + "\nあいうえおかきくけこさしすせそたちつてと"
        withEditor(String(text)) { e in
            @MainActor func line(_ needle: String) -> Int { ConcealedEditing.line(at: e.index(of: needle), in: e.storage).range.location }
            @MainActor func caretLine() -> Int { ConcealedEditing.line(at: e.caret, in: e.storage).range.location }
            // Down the left column: the title, the three lines, then the line under the row.
            e.click(1)
            var seen: [Int] = []
            for _ in 0..<5 { command(e, #selector(NSResponder.moveDown(_:))); seen.append(caretLine()) }
            #expect(seen == [line(":::card orange"), line("- [/] 一"), line("- [ ] 二"), line("- [ ] 三"), line("おわり")])
            // And back up.
            seen = []
            for _ in 0..<5 { command(e, #selector(NSResponder.moveUp(_:))); seen.append(caretLine()) }
            #expect(seen == [line("- [ ] 三"), line("- [ ] 二"), line("- [/] 一"), line(":::card orange"), 0])
            // Down the right column: B's title, its one line, then straight to the line under the row.
            e.click(18)
            seen = []
            for _ in 0..<3 { command(e, #selector(NSResponder.moveDown(_:))); seen.append(caretLine()) }
            #expect(seen == [line(":::card purple"), line("短い"), line("おわり")])
            command(e, #selector(NSResponder.moveDown(_:)))
            #expect(caretLine() == line("あいうえお"))
            command(e, #selector(NSResponder.moveUp(_:)))
            seen = []
            for _ in 0..<3 { command(e, #selector(NSResponder.moveUp(_:))); seen.append(caretLine()) }
            #expect(seen == [line("短い"), line(":::card purple"), 0])
        }
    }

    @Test func aRowThatEndsTheNoteKeepsTheCaretInItsColumn() {
        withEditor("::::columns\n:::card orange A\n一\n二\n:::\n:::card purple B\n短い\n:::\n::::") { e in
            e.click(e.index(of: "一"))
            command(e, #selector(NSResponder.moveUp(_:)))
            command(e, #selector(NSResponder.moveUp(_:)))
            #expect(ConcealedEditing.line(at: e.caret, in: e.storage).kind == .cardOpen)
            #expect(e.caret >= e.index(of: "A\n"))
            e.click(end(e, "短い"))
            command(e, #selector(NSResponder.moveDown(_:)))
            #expect(e.caret == end(e, "短い"))                       // nothing under it: not over to card A
            e.click(end(e, "二"))
            command(e, #selector(NSResponder.moveDown(_:)))
            #expect(e.caret == end(e, "二"))
            e.click(e.index(of: "B\n"))
            command(e, #selector(NSResponder.moveUp(_:)))
            #expect(e.caret == e.index(of: "B\n"))
        }
    }

    @Test func theCaretNeverStopsOnTheLinesOfARow() {
        withEditor(two) { e in
            for position in 0...(e.text as NSString).length {
                e.click(position)
                let line = ConcealedEditing.line(at: e.caret, in: e.storage)
                #expect(!line.kind.isHiddenLine, "clicked \(position), caret \(e.caret)")
                #expect(e.caret >= line.contentStart, "clicked \(position), caret \(e.caret)")
            }
        }
    }

    @Test func clicksLandInTheCardThatIsClicked() throws {
        try withEditorThrowing(two) { e in
            let cards = e.layoutManager.cardGeometries()
            let origin = e.textView.textContainerOrigin
            for (card, needle) in zip(cards, ["- [ ] 三", "短い"]) {
                let panel = try #require(card.panel)
                let index = e.textView.characterIndexForInsertion(at: NSPoint(x: panel.midX + origin.x, y: panel.minY + 14 + origin.y))
                #expect(NSLocationInRange(index, card.range), "\(needle)")
            }
            // A selection in a card is drawn in that card.
            let range = NSRange(location: e.index(of: "短い"), length: 2)
            var count = 0
            let rects = e.layoutManager.rectArray(forCharacterRange: range, withinSelectedCharacterRange: range,
                                                 in: e.layoutManager.textContainers[0], rectCount: &count)
            #expect(count == 1)
            #expect(cards[1].panel?.contains(try #require(rects)[0]) == true)
        }
    }

    private func withEditorThrowing(_ text: String, _ body: @MainActor (ConcealedEditor) throws -> Void) throws {
        var thrown: Error?
        withEditor(text) { e in
            do { try body(e) } catch { thrown = error }
        }
        if let thrown { throw thrown }
    }

    @Test func textComposedInACardOfARowStaysInItsCard() {
        withEditor("::::columns\n:::card orange A\n一\n:::\n:::card purple B\n\n:::\n::::\n") { e in
            let line = e.index(of: "B\n") + 2
            e.click(line)
            e.textView.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            e.layoutManager.ensureLayout(for: e.layoutManager.textContainers[0])
            #expect(standSideBySide(e))
            #expect(e.layoutManager.cardGeometries().count == 2)
            let x = e.x(at: line)
            #expect(x > e.layoutManager.cardGeometries()[1].frame.minX)       // in card B, not at the line's start
            e.textView.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
            e.layoutManager.ensureLayout(for: e.layoutManager.textContainers[0])
            #expect(e.text == "::::columns\n:::card orange A\n一\n:::\n:::card purple B\n日本\n:::\n::::\n")
            #expect(standSideBySide(e))
        }
    }

    @Test func tabInACardIsATabOrAListLevel() {
        withEditor(two) { e in
            e.click(end(e, "短い"))
            command(e, #selector(NSResponder.insertTab(_:)))
            #expect(e.text.contains("短い\t\n"))                    // typed, as outside a card: not a jump to another cell
            #expect(e.caret == end(e, "短い\t"))
            e.click(end(e, "- [ ] 二"))
            command(e, #selector(NSResponder.insertTab(_:)))
            #expect(e.text.contains("\n\t- [ ] 二\n"))
            command(e, #selector(NSResponder.insertBacktab(_:)))
            #expect(e.text.contains("\n- [ ] 二\n"))
            e.click(end(e, "短い\t"))
            command(e, #selector(NSResponder.insertBacktab(_:)))
            #expect(standSideBySide(e))
            #expect(NSLocationInRange(e.caret, e.layoutManager.cardGeometries()[1].range))
        }
    }

    @Test func returnAndBackspaceAtTheEdgesOfARow() {
        withEditor("本文\n::::columns\n:::card orange A\n一\n\n:::\n:::card purple B\n短い\n:::\n::::\nおわり") { e in
            // Return on the empty last line of card A leaves the row: to a new line under it.
            e.click(e.index(of: "一\n") + 2)
            e.key { e.textView.insertNewline(nil) }
            #expect(e.text == "本文\n::::columns\n:::card orange A\n一\n:::\n:::card purple B\n短い\n:::\n::::\n\nおわり")
            #expect(e.caret == e.index(of: "\nおわり"))
            #expect(standSideBySide(e))
            // Backspace on that empty line removes it and goes back into the row; again, it only moves.
            e.key { e.textView.deleteBackward(nil) }
            #expect(e.text == "本文\n::::columns\n:::card orange A\n一\n:::\n:::card purple B\n短い\n:::\n::::\nおわり")
            #expect(e.caret == end(e, "短い"))
            e.click(e.index(of: "おわり"))
            e.key { e.textView.deleteBackward(nil) }
            #expect(e.caret == end(e, "短い"))
            #expect(standSideBySide(e))
            // Return at the start of a title in a row: no line there (a row holds only cards); on to the text.
            e.click(e.index(of: "B\n"))
            e.key { e.textView.insertNewline(nil) }
            #expect(e.text.contains(":::card purple B\n\n短い\n:::\n::::"))
            #expect(standSideBySide(e))
            // Delete at the end of the line above the row, and at the ends inside: nothing joins.
            let before = e.text
            for position in [end(e, "本文"), end(e, "card orange A"), end(e, "一"), end(e, "短い")] {
                e.click(position)
                e.key { e.textView.deleteForward(nil) }
            }
            #expect(e.text == before)
        }
    }

    @Test func aSelectionTakesWholeCardsAndWholeRows() {
        withEditor(two) { e in
            let row = NSRange(location: e.index(of: "::::columns"), length: e.index(of: "おわり") - e.index(of: "::::columns"))
            let a = NSRange(location: e.index(of: ":::card orange"), length: e.index(of: ":::card purple") - e.index(of: ":::card orange"))
            // From card A's text into its title: card A.
            e.textView.setSelectedRange(NSRange(location: e.index(of: "A\n"), length: 6))
            #expect(e.textView.selectedRange() == a)
            // From card A into card B: both, which is the whole row.
            e.textView.setSelectedRange(NSRange(location: e.index(of: "- [ ] 三"), length: e.index(of: "短い") - e.index(of: "- [ ] 三")))
            #expect(e.textView.selectedRange() == row)
            // From above the row into it: up to the end of the row.
            e.textView.setSelectedRange(NSRange(location: 1, length: e.index(of: "- [/]") - 1))
            #expect(e.textView.selectedRange() == NSRange(location: 1, length: NSMaxRange(row) - 1))
            // Deleting one card leaves the other as a card on its own.
            e.textView.setSelectedRange(a)
            e.key { e.textView.deleteBackward(nil) }
            #expect(e.text == "本文\n::::columns\n:::card purple B\n短い\n:::\n::::\nおわり")
            #expect(e.layoutManager.cardGeometries().count == 1)
            e.undo.undo()
            // Deleting the row deletes its two lines too.
            e.textView.setSelectedRange(NSRange(location: e.index(of: "- [ ] 三"), length: e.index(of: "短い") - e.index(of: "- [ ] 三")))
            e.key { e.textView.deleteBackward(nil) }
            #expect(e.text == "本文\nおわり")
        }
    }

    @Test func takingACardOutOfARow() {
        func item(_ location: Int) -> NSMenuItem {
            let item = NSMenuItem()
            item.representedObject = location
            return item
        }
        withEditor(two) { e in
            // Unwrapping one of two: the row is over, the other is a card on its own, and the text goes under it.
            e.key { e.textView.unwrapCard(item(e.index(of: ":::card orange"))) }
            #expect(e.text == "本文\n:::card purple B\n短い\n:::\nA\n- [/] 一\n- [ ] 二\n- [ ] 三\nおわり")
            #expect(e.caret == e.index(of: "A\n- [/]"))
            e.undo.undo()
            #expect(e.text == two)
            // Backspace at the start of the title does the same.
            e.click(e.index(of: "B\n"))
            e.key { e.textView.deleteBackward(nil) }
            #expect(e.text == "本文\n:::card orange A\n- [/] 一\n- [ ] 二\n- [ ] 三\n:::\nB\n短い\nおわり")
            e.undo.undo()
            e.key { e.textView.deleteCard(item(e.index(of: ":::card purple"))) }
            #expect(e.text == "本文\n:::card orange A\n- [/] 一\n- [ ] 二\n- [ ] 三\n:::\nおわり")
        }
        // In a row of three the row stays.
        withEditor("::::columns\n:::card A\n:::\n:::card B\n:::\n:::card C\n:::\n::::") { e in
            e.key { e.textView.deleteCard(item(e.index(of: ":::card B"))) }
            #expect(e.text == "::::columns\n:::card A\n:::\n:::card C\n:::\n::::")
            #expect(e.layoutManager.cardGeometries().count == 2)
            #expect(standSideBySide(e))
        }
    }

    @Test func aNewCardGoesUnderTheRow() {
        withEditor(two) { e in
            e.click(e.index(of: "- [ ] 二"))
            e.key { e.textView.insertCard(nil) }
            #expect(e.text == "本文\n::::columns\n:::card orange A\n- [/] 一\n- [ ] 二\n- [ ] 三\n:::\n:::card purple B\n短い\n:::\n::::\n:::card default \n\n:::\nおわり")
            #expect(standSideBySide(e))
            #expect(e.layoutManager.cardGeometries().count == 3)
            #expect(ConcealedEditing.line(at: e.caret, in: e.storage).kind == .cardOpen)
            #expect(e.caret > e.index(of: "::::\n:::card default"))
        }
    }

    @Test func inANarrowNoteTheCardsOfARowStandOneBelowTheOther() {
        let narrow = editor(two, width: 200)
        let cards = narrow.layoutManager.cardGeometries()
        #expect(cards.count == 2)
        #expect(cards[1].frame.minY > cards[0].frame.maxY)             // stacked
        #expect(abs(cards[0].frame.width - cards[1].frame.width) < 0.5)
        #expect(narrow.storage.attribute(.mdCardRow, at: narrow.index(of: "短い"), effectiveRange: nil) != nil) // still a row in the text
        // Three cards need more room than two.
        let three = "::::columns\n:::card A\n:::\n:::card B\n:::\n:::card C\n:::\n::::"
        #expect(editor(three, width: 300).layoutManager.cardGeometries().map(\.frame.minY).sorted().last! > 40)
        let wide = editor(three, width: 400).layoutManager.cardGeometries()
        #expect(wide.count == 3 && Set(wide.map { Int($0.frame.minY) }).count == 1)
    }

    @Test func aRowHoldsOnlyCards() {
        // Text or an empty line between the cards: not a row, and its two lines are shown as typed.
        for broken in ["::::columns\n:::card A\n:::\n\n:::card B\n:::\n::::", "::::columns\n本文\n:::card A\n:::\n::::",
                       "::::columns\n::::", "::::columns\n:::card A\n:::"] {
            let e = editor(broken)
            #expect(ConcealedEditing.line(at: 0, in: e.storage).kind == .text, "\(broken)")
            #expect(e.storage.attribute(.mdCardRow, at: 0, effectiveRange: nil) == nil, "\(broken)")
            #expect(e.property(at: 0) != .null)
        }
        // One card is enough for the syntax (it is shown as a card on its own).
        let one = editor("::::columns\n:::card A\n中\n:::\n::::")
        #expect(ConcealedEditing.line(at: 0, in: one.storage).kind == .rowOpen)
        #expect(one.layoutManager.cardGeometries().count == 1)
        #expect(NoteTitle.derive(from: one.text) == "A")
    }
}
