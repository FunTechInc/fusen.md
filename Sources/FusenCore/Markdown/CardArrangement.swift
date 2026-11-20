import AppKit

/// A note as the pieces that cards are moved between: lines of text, cards, and rows of cards (see
/// CardSyntax). Moving a card, taking one away or unwrapping one rewrites the note from its pieces, so
/// the Markdown always stays well formed: a row has its two lines around two or more cards, and gives
/// them up when a single card is left in it.
///
/// Cards are counted in the order they are written, as MarkdownStyler numbers them (`.mdCard`).
struct CardArrangement: Equatable {
    enum Piece: Equatable {
        /// A line of the note outside any card.
        case line(String)
        /// A card on its own: its lines, from the opening to the closing line.
        case card([String])
        /// Cards side by side.
        case row([[String]])
    }

    /// Where a card can be put.
    enum Destination: Hashable {
        /// On its own, before the piece with this index (`pieces.count`: at the end of the note).
        case before(piece: Int)
        /// Beside the card with this number, left or right of it: into its row, or making a row of the two.
        case beside(card: Int, after: Bool)
    }

    var pieces: [Piece] = []

    /// Reads the pieces of a styled note.
    @MainActor
    init(_ storage: NSTextStorage) {
        let ns = storage.string as NSString
        let all = NSRange(location: 0, length: ns.length)
        func lines(_ range: NSRange) -> [String] {
            var lines = ns.substring(with: range).components(separatedBy: "\n")
            if lines.count > 1, lines.last == "" { lines.removeLast() } // the line break that ends the last line
            return lines
        }
        var location = 0
        while location < ns.length {
            var run = NSRange()
            if storage.attribute(.mdCardRow, at: location, longestEffectiveRange: &run, in: all) != nil {
                var cards: [[String]] = []
                var inner = run.location
                while inner < NSMaxRange(run) {
                    var card = NSRange()
                    if storage.attribute(.mdCard, at: inner, longestEffectiveRange: &card, in: run) != nil {
                        cards.append(lines(card))
                        inner = NSMaxRange(card)
                    } else {
                        inner = NSMaxRange(ns.lineRange(for: NSRange(location: inner, length: 0))) // the row's own lines
                    }
                }
                pieces.append(.row(cards))
                location = NSMaxRange(run)
            } else if storage.attribute(.mdCard, at: location, longestEffectiveRange: &run, in: all) != nil {
                pieces.append(.card(lines(run)))
                location = NSMaxRange(run)
            } else {
                var start = 0, end = 0, contentsEnd = 0
                ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
                pieces.append(.line(ns.substring(with: NSRange(location: start, length: contentsEnd - start))))
                location = end
            }
        }
        // A note that ends with a line break has an empty last line.
        if ns.length == 0 || ns.character(at: ns.length - 1) == 0x0A { pieces.append(.line("")) }
    }

    init(pieces: [Piece]) { self.pieces = pieces }

    // MARK: Reading

    private static func lines(of piece: Piece) -> [String] {
        switch piece {
        case .line(let line): [line]
        case .card(let card): card
        case .row(let cards): [CardSyntax.rowOpenMarker] + cards.flatMap { $0 } + [CardSyntax.rowCloseMarker]
        }
    }

    /// The note's text.
    var text: String { pieces.flatMap(Self.lines).joined(separator: "\n") }

    var cardCount: Int {
        pieces.reduce(0) { count, piece in
            switch piece {
            case .line: count
            case .card: count + 1
            case .row(let cards): count + cards.count
            }
        }
    }

    /// The piece that holds card `number`, and the card's place in it if the piece is a row.
    func place(ofCard number: Int) -> (piece: Int, column: Int?)? {
        var next = 0
        for (index, piece) in pieces.enumerated() {
            switch piece {
            case .line:
                break
            case .card:
                if next == number { return (index, nil) }
                next += 1
            case .row(let cards):
                if number < next + cards.count { return (index, number - next) }
                next += cards.count
            }
        }
        return nil
    }

    func lines(ofCard number: Int) -> [String]? {
        guard let place = place(ofCard: number) else { return nil }
        switch pieces[place.piece] {
        case .card(let lines): return lines
        case .row(let cards): return place.column.map { cards[$0] }
        case .line: return nil
        }
    }

    /// Where the piece with this index starts in `text` (for `pieces.count`: where the text ends).
    func offset(ofPiece index: Int) -> Int {
        let before = pieces.prefix(index).flatMap(Self.lines)
        let length = before.reduce(0) { $0 + ($1 as NSString).length + 1 }
        return index >= pieces.count && !pieces.isEmpty ? length - 1 : length
    }

    /// Where card `number` starts in `text`.
    func offset(ofCard number: Int) -> Int? {
        guard let place = place(ofCard: number) else { return nil }
        var offset = offset(ofPiece: place.piece)
        if let column = place.column, case .row(let cards) = pieces[place.piece] {
            offset += (CardSyntax.rowOpenMarker as NSString).length + 1
            offset += cards.prefix(column).flatMap { $0 }.reduce(0) { $0 + ($1 as NSString).length + 1 }
        }
        return offset
    }

    // MARK: Changing

    /// Takes card `number` out of where it is: a row left with one card becomes that card on its own.
    /// Returns the card's lines and the index of the piece it was (in).
    @discardableResult
    private mutating func take(card number: Int) -> (lines: [String], piece: Int, pieceIsGone: Bool)? {
        guard let place = place(ofCard: number) else { return nil }
        switch pieces[place.piece] {
        case .card(let lines):
            pieces.remove(at: place.piece)
            return (lines, place.piece, true)
        case .row(var cards):
            guard let column = place.column else { return nil }
            let lines = cards.remove(at: column)
            switch cards.count {
            case 0:
                pieces.remove(at: place.piece)
                return (lines, place.piece, true)
            case 1:
                pieces[place.piece] = .card(cards[0])
            default:
                pieces[place.piece] = .row(cards)
            }
            return (lines, place.piece, false)
        case .line:
            return nil
        }
    }

    /// Removes card `number` with everything in it.
    mutating func remove(card number: Int) {
        take(card: number)
    }

    /// Takes card `number` away and keeps what is in it: its title and its text become lines of the
    /// note — where the card was, or under the row it stood in. Returns the index of the first of them
    /// (of the piece that follows, if the card was empty).
    @discardableResult
    mutating func unwrap(card number: Int) -> Int? {
        guard let taken = take(card: number), let open = taken.lines.first else { return nil }
        let ns = open as NSString
        let title = ns.substring(with: CardSyntax.parseOpen(ns, line: NSRange(location: 0, length: ns.length)).title)
        var lines = Array(taken.lines.dropFirst().dropLast())
        if !title.isEmpty { lines.insert(title, at: 0) }
        let index = taken.pieceIsGone ? taken.piece : taken.piece + 1
        pieces.insert(contentsOf: lines.map(Piece.line), at: index)
        return index
    }

    /// Moves card `number` to `destination`. Returns the number the card has afterwards, or nil if the
    /// note would not change (or the move makes no sense).
    @discardableResult
    mutating func move(card number: Int, to destination: Destination) -> Int? {
        let original = self
        var moved = self
        guard let taken = moved.take(card: number) else { return nil }
        switch destination {
        case .before(var piece):
            guard piece >= 0, piece <= pieces.count else { return nil }
            if taken.pieceIsGone, taken.piece < piece { piece -= 1 }
            moved.pieces.insert(.card(taken.lines), at: piece)
        case .beside(let target, let after):
            guard target != number, target >= 0, target < cardCount else { return nil }
            let renumbered = target > number ? target - 1 : target
            guard let place = moved.place(ofCard: renumbered) else { return nil }
            switch moved.pieces[place.piece] {
            case .card(let lines):
                moved.pieces[place.piece] = .row(after ? [lines, taken.lines] : [taken.lines, lines])
            case .row(var cards):
                guard let column = place.column else { return nil }
                cards.insert(taken.lines, at: after ? column + 1 : column)
                moved.pieces[place.piece] = .row(cards)
            case .line:
                return nil
            }
        }
        guard moved != original else { return nil }
        self = moved
        // The card is the one whose lines these are, at the place it was put: find it by walking.
        switch destination {
        case .before(var piece):
            if taken.pieceIsGone, taken.piece < piece { piece -= 1 }
            return cardNumber(atPiece: piece)
        case .beside(let target, let after):
            let renumbered = target > number ? target - 1 : target
            return after ? renumbered + 1 : renumbered
        }
    }

    /// The number of the card that is the piece with this index (the number of cards before it).
    private func cardNumber(atPiece index: Int) -> Int {
        pieces.prefix(index).reduce(0) { count, piece in
            switch piece {
            case .line: count
            case .card: count + 1
            case .row(let cards): count + cards.count
            }
        }
    }
}
