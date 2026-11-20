import AppKit
import Testing
@testable import FusenCore

/// Moving cards rewrites the note from its pieces (lines, cards, rows of cards).
@MainActor
struct CardArrangementTests {
    private let styler = MarkdownStyler()

    private func arrangement(_ text: String) -> CardArrangement {
        let storage = NSTextStorage(string: text)
        styler.restyle(storage)
        return CardArrangement(storage)
    }

    private func card(_ name: String, _ lines: String...) -> String {
        ([":::card \(name)"] + lines + [":::"]).joined(separator: "\n")
    }

    private func moved(_ text: String, card: Int, to destination: CardArrangement.Destination) -> String? {
        var arrangement = arrangement(text)
        return arrangement.move(card: card, to: destination) == nil ? nil : arrangement.text
    }

    @Test func aNoteIsReadAndWrittenBackAsItIs() {
        let a = card("A", "一"), b = card("B"), c = card("C", "三", "四")
        for text in ["", "本文", "本文\n", "\n\n", a, a + "\n", "前\n" + a + "\n後", a + "\n" + b,
                     "::::columns\n" + a + "\n" + b + "\n::::", "前\n::::columns\n" + a + "\n" + b + "\n::::\n" + c + "\n\n後\n",
                     ":::card A\n```\n:::\n```\n:::", "::::columns\n本文\n::::", ":::card A\n途中"] {
            #expect(arrangement(text).text == text, "\(text)")
        }
        let pieces = arrangement("前\n::::columns\n" + a + "\n" + b + "\n::::\n" + c + "\n").pieces
        #expect(pieces == [.line("前"), .row([[":::card A", "一", ":::"], [":::card B", ":::"]]), .card([":::card C", "三", "四", ":::"]), .line("")])
    }

    @Test func cardsAreCountedInTheOrderTheyAreWritten() {
        let a = card("A"), b = card("B"), c = card("C")
        let arrangement = arrangement("前\n" + a + "\n::::columns\n" + b + "\n" + c + "\n::::")
        #expect(arrangement.cardCount == 3)
        #expect(arrangement.place(ofCard: 0)?.piece == 1 && arrangement.place(ofCard: 0)?.column == nil)
        #expect(arrangement.place(ofCard: 2)?.piece == 2 && arrangement.place(ofCard: 2)?.column == 1)
        #expect(arrangement.place(ofCard: 3) == nil)
        #expect(arrangement.lines(ofCard: 1) == [":::card B", ":::"])
        let text = arrangement.text as NSString
        #expect(arrangement.offset(ofCard: 0) == text.range(of: ":::card A").location)
        #expect(arrangement.offset(ofCard: 2) == text.range(of: ":::card C").location)
        #expect(arrangement.offset(ofPiece: 3) == text.length)
    }

    @Test func movingACardBetweenTheLines() {
        let a = card("A", "一"), b = card("B")
        let text = "一行目\n" + a + "\n二行目\n" + b + "\n三行目"
        // Pieces: 0 一行目, 1 A, 2 二行目, 3 B, 4 三行目.
        #expect(moved(text, card: 0, to: .before(piece: 0)) == a + "\n一行目\n二行目\n" + b + "\n三行目")
        #expect(moved(text, card: 0, to: .before(piece: 3)) == "一行目\n二行目\n" + a + "\n" + b + "\n三行目")
        #expect(moved(text, card: 0, to: .before(piece: 5)) == "一行目\n二行目\n" + b + "\n三行目\n" + a)
        #expect(moved(text, card: 1, to: .before(piece: 1)) == "一行目\n" + b + "\n" + a + "\n二行目\n三行目")
        // Where it is already: nothing changes.
        #expect(moved(text, card: 0, to: .before(piece: 1)) == nil)
        #expect(moved(text, card: 0, to: .before(piece: 2)) == nil)
        #expect(moved(text, card: 0, to: .before(piece: 9)) == nil)
    }

    @Test func droppedBesideACardTheTwoMakeARow() {
        let a = card("A", "一"), b = card("B"), c = card("C")
        let text = a + "\n本文\n" + b
        #expect(moved(text, card: 1, to: .beside(card: 0, after: true)) == "::::columns\n" + a + "\n" + b + "\n::::\n本文")
        #expect(moved(text, card: 1, to: .beside(card: 0, after: false)) == "::::columns\n" + b + "\n" + a + "\n::::\n本文")
        #expect(moved(text, card: 0, to: .beside(card: 1, after: true)) == "本文\n::::columns\n" + b + "\n" + a + "\n::::")
        #expect(moved(text, card: 0, to: .beside(card: 0, after: true)) == nil)
        // A third card joins the row, at the side it was dropped on.
        let row = "::::columns\n" + a + "\n" + b + "\n::::\n" + c
        #expect(moved(row, card: 2, to: .beside(card: 0, after: true)) == "::::columns\n" + a + "\n" + c + "\n" + b + "\n::::")
        #expect(moved(row, card: 2, to: .beside(card: 1, after: true)) == "::::columns\n" + a + "\n" + b + "\n" + c + "\n::::")
        #expect(moved(row, card: 2, to: .beside(card: 0, after: false)) == "::::columns\n" + c + "\n" + a + "\n" + b + "\n::::")
        // Within a row the cards change places.
        #expect(moved(row, card: 0, to: .beside(card: 1, after: true)) == "::::columns\n" + b + "\n" + a + "\n::::\n" + c)
        #expect(moved(row, card: 0, to: .beside(card: 1, after: false)) == nil)
        #expect(moved(row, card: 1, to: .beside(card: 0, after: true)) == nil)
    }

    @Test func aRowLeftWithOneCardIsThatCardOnItsOwn() {
        let a = card("A"), b = card("B"), c = card("C")
        let two = "前\n::::columns\n" + a + "\n" + b + "\n::::\n後"
        #expect(moved(two, card: 0, to: .before(piece: 3)) == "前\n" + b + "\n後\n" + a)
        #expect(moved(two, card: 1, to: .before(piece: 0)) == b + "\n前\n" + a + "\n後")
        #expect(moved(two, card: 1, to: .before(piece: 1)) == "前\n" + b + "\n" + a + "\n後")   // out of the row, above it
        let three = "::::columns\n" + a + "\n" + b + "\n" + c + "\n::::"
        #expect(moved(three, card: 1, to: .before(piece: 1)) == "::::columns\n" + a + "\n" + c + "\n::::\n" + b)
        // From one row into another.
        let rows = "::::columns\n" + a + "\n" + b + "\n::::\n::::columns\n" + c + "\n" + card("D") + "\n::::"
        #expect(moved(rows, card: 0, to: .beside(card: 2, after: false))
                == b + "\n::::columns\n" + a + "\n" + c + "\n" + card("D") + "\n::::")
    }

    @Test func theNumberOfTheMovedCard() {
        let a = card("A"), b = card("B"), c = card("C")
        var arrangement = arrangement(a + "\n" + b + "\n" + c)
        #expect(arrangement.move(card: 0, to: .before(piece: 3)) == 2)
        #expect(arrangement.text == b + "\n" + c + "\n" + a)
        #expect(arrangement.move(card: 2, to: .beside(card: 0, after: false)) == 0)
        #expect(arrangement.text == "::::columns\n" + a + "\n" + b + "\n::::\n" + c)
        #expect(arrangement.move(card: 2, to: .beside(card: 0, after: true)) == 1)
        #expect(arrangement.lines(ofCard: 1) == [":::card C", ":::"])
    }

    @Test func removingAndUnwrapping() {
        let a = card("orange A", "一", "二"), b = card("B")
        var standalone = arrangement("前\n" + a + "\n後")
        standalone.unwrap(card: 0)
        #expect(standalone.text == "前\nA\n一\n二\n後")
        var removed = arrangement("前\n" + a)
        removed.remove(card: 0)
        #expect(removed.text == "前")
        var inRow = arrangement("::::columns\n" + a + "\n" + b + "\n::::\n後")
        #expect(inRow.unwrap(card: 0) == 1)
        #expect(inRow.text == b + "\nA\n一\n二\n後")
        var untitled = arrangement(":::card blue \n:::")
        untitled.unwrap(card: 0)
        #expect(untitled.text == "")
    }
}
