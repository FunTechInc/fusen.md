import Foundation

/// How cards are written:
///
///     :::card orange プロジェクトA
///     - [/] 進行中のタスク
///     :::
///
/// A card opens with ":::card", its color and its title, and closes with ":::"; the lines between are
/// ordinary Markdown. The color may be left out (the default color), then everything after ":::card "
/// is the title.
///
/// A card is only a card when both lines are there: an opening line without its closing line stays the
/// text it is, visible, and never takes the rest of the note with it. Cards do not nest.
///
/// Cards stand one below the other. Cards that stand side by side are written between two more lines:
///
///     ::::columns
///     :::card orange プロジェクトA
///     …
///     :::
///     :::card purple プロジェクトB
///     …
///     :::
///     ::::
///
/// Such a row holds cards and nothing else (no text and no empty lines between them); otherwise its two
/// lines stay text, and the cards stand one below the other.
enum CardSyntax {
    static let openMarker = ":::card"
    static let closeMarker = ":::"
    static let rowOpenMarker = "::::columns"
    static let rowCloseMarker = "::::"

    private static let open = makeRegex(#"^:::card(?:[ \t]+|$)"#)
    private static let close = makeRegex(#"^:::[ \t]*$"#)
    private static let rowOpen = makeRegex(#"^::::columns[ \t]*$"#)
    private static let rowClose = makeRegex(#"^::::[ \t]*$"#)

    struct Card: Equatable {
        /// The opening and the closing line, each with its line break.
        let open: NSRange
        let close: NSRange
        let color: CardColor
        /// ":::card orange " — the syntax of the opening line.
        let prefix: NSRange
        /// The rest of the opening line.
        let title: NSRange
        /// The row the card stands in (an index into the rows), if it stands in one.
        var row: Int?

        /// From the opening line through the closing line.
        var range: NSRange { NSRange(location: open.location, length: NSMaxRange(close) - open.location) }
        /// The lines between them.
        var content: NSRange { NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open)) }
    }

    /// Cards side by side.
    struct Row: Equatable {
        /// The "::::columns" and the "::::" line, each with its line break.
        let open: NSRange
        let close: NSRange
        /// Its cards (indices into the cards), left to right.
        let cards: Range<Int>

        var range: NSRange { NSRange(location: open.location, length: NSMaxRange(close) - open.location) }
    }

    struct Blocks: Equatable {
        var cards: [Card] = []
        var rows: [Row] = []
    }

    static func isOpen(_ text: String, _ line: NSRange) -> Bool { open.firstMatch(in: text, range: line) != nil }
    static func isClose(_ text: String, _ line: NSRange) -> Bool { close.firstMatch(in: text, range: line) != nil }
    static func isRowOpen(_ text: String, _ line: NSRange) -> Bool { rowOpen.firstMatch(in: text, range: line) != nil }
    static func isRowClose(_ text: String, _ line: NSRange) -> Bool { rowClose.firstMatch(in: text, range: line) != nil }
    /// A line that is card syntax and nothing else (it has no title to show).
    static func isStructureOnly(_ text: String, _ line: NSRange) -> Bool {
        isClose(text, line) || isRowOpen(text, line) || isRowClose(text, line)
    }

    /// The parts of an opening line (`line`: without its line break).
    static func parseOpen(_ ns: NSString, line: NSRange) -> (color: CardColor, prefix: NSRange, title: NSRange) {
        func isSpace(_ i: Int) -> Bool { ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 }
        let end = NSMaxRange(line)
        var i = line.location + (openMarker as NSString).length
        while i < end, isSpace(i) { i += 1 }
        let afterMarker = i
        while i < end, !isSpace(i) { i += 1 }
        var color = CardColor.default
        var prefixEnd = afterMarker
        if let named = CardColor(rawValue: ns.substring(with: NSRange(location: afterMarker, length: i - afterMarker))) {
            color = named
            while i < end, isSpace(i) { i += 1 }
            prefixEnd = i
        }
        return (color, NSRange(location: line.location, length: prefixEnd - line.location),
                NSRange(location: prefixEnd, length: end - prefixEnd))
    }

    /// The opening line of a card.
    static func openLine(color: CardColor, title: String) -> String { "\(openMarker) \(color.rawValue) \(title)" }

    /// Finds the cards of a note, and the rows of cards. `isCode` says whether a line (without its line
    /// break) is inside a fenced code block, where nothing is Markdown; it is called once per line, in order.
    static func blocks(in ns: NSString, isCode: (NSRange) -> Bool) -> Blocks {
        let text = ns as String
        var blocks = Blocks()
        var pendingCard: (paragraph: NSRange, line: NSRange)?
        var pendingRow: (paragraph: NSRange, firstCard: Int)?
        var location = 0
        while location < ns.length {
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            location = end
            let line = NSRange(location: start, length: contentsEnd - start)
            let paragraph = NSRange(location: start, length: end - start)
            if isCode(line) {
                if pendingCard == nil { pendingRow = nil } // code between the cards: not a row
            } else if isOpen(text, line) {
                if pendingCard != nil { pendingRow = nil } // an opening line that was never closed stays text
                pendingCard = (paragraph, line)
            } else if let opened = pendingCard {
                guard isClose(text, line) else { continue } // a line of the card's text
                let parts = parseOpen(ns, line: opened.line)
                blocks.cards.append(Card(open: opened.paragraph, close: paragraph, color: parts.color, prefix: parts.prefix, title: parts.title))
                pendingCard = nil
            } else if isRowOpen(text, line) {
                pendingRow = (paragraph, blocks.cards.count)
            } else if isRowClose(text, line), let row = pendingRow, row.firstCard < blocks.cards.count {
                for card in row.firstCard..<blocks.cards.count { blocks.cards[card].row = blocks.rows.count }
                blocks.rows.append(Row(open: row.paragraph, close: paragraph, cards: row.firstCard..<blocks.cards.count))
                pendingRow = nil
            } else {
                pendingRow = nil // text, an empty line, or a stray closing line
            }
        }
        return blocks
    }
}
