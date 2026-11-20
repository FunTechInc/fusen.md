import AppKit

/// Editing rules for concealed Markdown, as in Notion: syntax takes no space on screen, so the caret
/// never stops inside it, and the editing keys act on what is visible while keeping each inline span's
/// delimiters together. Everything here reads the attributes MarkdownStyler records (`.mdBlockPrefix`,
/// `.mdMarker`, `.mdConcealBox`, `.mdSpan`, `.mdEscaped`, `.mdLine`).
@MainActor
enum ConcealedEditing {
    struct Line {
        /// The paragraph, with its newline.
        let range: NSRange
        let contentsEnd: Int
        let kind: MarkdownLine
        /// Block marker with its indentation ("## ", "\t- ", "> "), or the whole of a divider line.
        let prefix: NSRange?

        /// Where the text of the block starts.
        var contentStart: Int { prefix.map(NSMaxRange) ?? range.location }
        var content: NSRange { NSRange(location: contentStart, length: contentsEnd - contentStart) }
        var hasNewline: Bool { NSMaxRange(range) > contentsEnd }
        var isListItem: Bool { kind == .bullet || kind == .ordered || kind == .task }
        /// Not a divider, code or a line around a card: the line holds Markdown text.
        var holdsInlineText: Bool { kind != .rule && kind != .code && kind != .fence && !kind.isCardStructure }
    }

    /// An inline span (bold, italic, strike, code, link) with its delimiters.
    struct Span: Equatable {
        let range: NSRange
        let kind: MarkdownSpan
        let opening: NSRange
        let closing: NSRange
        /// Between the delimiters.
        var content: NSRange { NSRange(location: NSMaxRange(opening), length: closing.location - NSMaxRange(opening)) }
    }

    /// A change to the text, and where the caret goes after it.
    struct Edit: Equatable {
        let range: NSRange
        let string: String
        let caret: Int
    }

    static func line(at location: Int, in s: NSTextStorage) -> Line {
        let ns = s.string as NSString
        let clamped = min(max(location, 0), ns.length)
        var start = 0, end = 0, contentsEnd = 0
        ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: clamped, length: 0))
        let range = NSRange(location: start, length: end - start)
        guard start < ns.length else { return Line(range: range, contentsEnd: contentsEnd, kind: .text, prefix: nil) }
        let kind = (s.attribute(.mdLine, at: start, effectiveRange: nil) as? String).flatMap(MarkdownLine.init) ?? .text
        var prefix: NSRange?
        if contentsEnd > start {
            var run = NSRange()
            if s.attribute(.mdBlockPrefix, at: start, longestEffectiveRange: &run,
                           in: NSRange(location: start, length: contentsEnd - start)) != nil {
                prefix = run
            }
        }
        return Line(range: range, contentsEnd: contentsEnd, kind: kind, prefix: prefix)
    }

    /// Syntax that takes no space: markers outside block prefixes, except boxes (bullets, checkboxes,
    /// quote bars, numbers), which are drawn.
    static func isHidden(_ i: Int, in s: NSTextStorage) -> Bool {
        guard i >= 0, i < s.length else { return false }
        let attributes = s.attributes(at: i, effectiveRange: nil)
        return attributes[.mdMarker] != nil && attributes[.mdBlockPrefix] == nil && attributes[.mdConcealBox] == nil
    }

    /// The hidden backslash of an escape ("\*" shows "*").
    static func isEscapeBackslash(_ i: Int, in s: NSTextStorage) -> Bool {
        isHidden(i, in: s) && i + 1 < s.length && s.attribute(.mdEscaped, at: i + 1, effectiveRange: nil) != nil
    }

    /// Nothing the user can see lies between `a` and `b`: only hidden syntax and block markers (a
    /// divider counts as visible).
    static func onlySyntax(between a: Int, and b: Int, in s: NSTextStorage) -> Bool {
        (min(a, b)..<max(a, b)).allSatisfy { i in
            guard i >= 0, i < s.length else { return false }
            return isHidden(i, in: s) || (s.attribute(.mdBlockPrefix, at: i, effectiveRange: nil) != nil
                                   && s.attribute(.mdLine, at: i, effectiveRange: nil) as? String != MarkdownLine.rule.rawValue)
        }
    }

    /// The delimiter ("**", a link's "](url)") that `p` is inside of, if it is: between two hidden
    /// characters of the same span and side. Between the delimiters of two spans ("**" then "`") is a
    /// place of its own (after the bold, before the code).
    static func delimiter(around p: Int, in s: NSTextStorage) -> NSRange? {
        func span(_ i: Int) -> NSValue? { isHidden(i, in: s) ? s.attribute(.mdSpan, at: i, effectiveRange: nil) as? NSValue : nil }
        guard let value = span(p), span(p - 1) == value else { return nil }
        var start = p - 1, end = p + 1
        while span(start - 1) == value { start -= 1 }
        while span(end) == value { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Where a block's text starts on screen: after its marker and any hidden syntax (an opening "**").
    static func visibleContentStart(of line: Line, in s: NSTextStorage) -> Int {
        var p = line.contentStart
        while p < line.contentsEnd, isHidden(p, in: s) { p += 1 }
        return p
    }

    // MARK: Cards

    /// A card (see CardSyntax): its opening line with the title, its lines of text, its closing line.
    struct Card {
        /// The opening line through the closing line (with its line break, if it has one).
        let range: NSRange
        let open: Line
        let close: Line

        /// The lines of text between the two; empty for a card without any.
        var content: NSRange { NSRange(location: NSMaxRange(open.range), length: close.range.location - NSMaxRange(open.range)) }
        var title: NSRange { open.content }
    }

    /// The card that the character at `location` belongs to.
    static func card(at location: Int, in s: NSTextStorage) -> Card? {
        guard location >= 0, location < s.length else { return nil }
        var range = NSRange()
        guard s.attribute(.mdCard, at: location, longestEffectiveRange: &range, in: NSRange(location: 0, length: s.length)) != nil
        else { return nil }
        let open = line(at: range.location, in: s), close = line(at: NSMaxRange(range) - 1, in: s)
        guard open.kind == .cardOpen, close.kind == .cardClose, open.range.location < close.range.location else { return nil }
        return Card(range: range, open: open, close: close)
    }

    /// The card whose title or text the caret at `p` is in.
    static func card(around p: Int, in s: NSTextStorage) -> Card? {
        card(at: line(at: p, in: s).range.location, in: s)
    }

    /// Where the caret is when it comes into a card from below: the end of its last line of text (or of
    /// its title, if it has no text).
    static func lastCaret(in card: Card, _ s: NSTextStorage) -> Int {
        line(at: card.close.range.location - 1, in: s).contentsEnd
    }

    /// A row of cards: "::::columns", the cards, "::::".
    struct Row {
        /// The first of its lines through the last (with its line break, if it has one).
        let range: NSRange
        let open: Line
        let close: Line
    }

    /// The row that the character at `location` belongs to.
    static func row(at location: Int, in s: NSTextStorage) -> Row? {
        guard location >= 0, location < s.length else { return nil }
        var range = NSRange()
        guard s.attribute(.mdCardRow, at: location, longestEffectiveRange: &range, in: NSRange(location: 0, length: s.length)) != nil
        else { return nil }
        let open = line(at: range.location, in: s), close = line(at: NSMaxRange(range) - 1, in: s)
        guard open.kind == .rowOpen, close.kind == .rowClose else { return nil }
        return Row(range: range, open: open, close: close)
    }

    /// The cards of a row, left to right.
    static func cards(in row: Row, _ s: NSTextStorage) -> [Card] {
        var cards: [Card] = []
        var location = NSMaxRange(row.open.range)
        while location < row.close.range.location, let card = card(at: location, in: s) {
            cards.append(card)
            location = NSMaxRange(card.range)
        }
        return cards
    }

    /// The first place for the caret on the line that starts at `index` or, if that line shows nothing
    /// (a card's closing line, the lines around a row), on the first line after it that does: at the
    /// start of the line's text. nil if there is no such line.
    static func caretPosition(atOrAfter index: Int, in s: NSTextStorage) -> Int? {
        var i = index
        while i < s.length {
            let line = line(at: i, in: s)
            guard line.kind.isHiddenLine else { return line.contentStart }
            guard line.hasNewline else { return nil }
            i = NSMaxRange(line.range)
        }
        return i == s.length ? s.length : nil
    }

    /// The last place for the caret before the line that starts at `index`: the end of the nearest line
    /// above that shows something. nil if there is none.
    static func caretPosition(before index: Int, in s: NSTextStorage) -> Int? {
        var i = index
        while i > 0 {
            let line = line(at: i - 1, in: s)
            guard line.kind.isHiddenLine else { return line.contentsEnd }
            i = line.range.location
        }
        return nil
    }

    /// The parts of a card that hold it together: the syntax of its opening line, the line break after
    /// its title, and from the line break before its closing line to its end. Deleting any of them would
    /// leave half a card, or join text to one of its two lines.
    private static func structure(of card: Card, in s: NSTextStorage) -> [NSRange] {
        let lastBreak = lastCaret(in: card, s)
        return [card.open.prefix ?? NSRange(location: card.open.range.location, length: 0),
                NSRange(location: card.open.contentsEnd, length: NSMaxRange(card.open.range) - card.open.contentsEnd),
                NSRange(location: lastBreak, length: NSMaxRange(card.range) - lastBreak)]
    }

    /// A selection takes a card whole or leaves its structure alone: one that reaches over a part of a
    /// card's structure grows to hold all of the card, as selecting across blocks does in Notion.
    static func expandingOverCards(_ r: NSRange, in s: NSTextStorage) -> NSRange {
        var result = r
        var location = r.location
        while location < NSMaxRange(result), location < s.length {
            var run = NSRange()
            let value = s.attribute(.mdCard, at: location, longestEffectiveRange: &run, in: NSRange(location: 0, length: s.length))
            location = max(NSMaxRange(run), location + 1)
            guard value != nil, let card = card(at: run.location, in: s),
                  NSIntersectionRange(result, card.range) != card.range,
                  structure(of: card, in: s).contains(where: { NSIntersectionRange(result, $0).length > 0 }) else { continue }
            result = NSUnionRange(result, card.range)
        }
        // A row: one of its own two lines, or all of its cards, takes the row whole (no row without cards,
        // and no half of one, is left behind).
        location = result.location
        while location < NSMaxRange(result), location < s.length {
            var run = NSRange()
            let value = s.attribute(.mdCardRow, at: location, longestEffectiveRange: &run, in: NSRange(location: 0, length: s.length))
            location = max(NSMaxRange(run), location + 1)
            guard value != nil, let row = row(at: run.location, in: s), NSIntersectionRange(result, row.range) != row.range else { continue }
            let cards = cards(in: row, s)
            let touchesItsLines = NSIntersectionRange(result, row.open.range).length > 0 || NSIntersectionRange(result, row.close.range).length > 0
            let holdsAllCards = !cards.isEmpty && cards.allSatisfy { NSIntersectionRange(result, $0.range) == $0.range }
            if touchesItsLines || holdsAllCards { result = NSUnionRange(result, row.range) }
        }
        return result
    }

    /// The number MarkdownStyler gave the card (see CardArrangement).
    static func number(of card: Card, in s: NSTextStorage) -> Int? {
        s.attribute(.mdCard, at: card.range.location, effectiveRange: nil) as? Int
    }

    /// The change that makes the note `arrangement`, with the caret at `caret` (in the new text).
    static func edit(to arrangement: CardArrangement, caret: Int, in s: NSTextStorage) -> Edit {
        minimal(Edit(range: NSRange(location: 0, length: s.length), string: arrangement.text, caret: caret), in: s)
    }

    /// Taking a card away and keeping what is in it: its title becomes a line of text above its text. (A
    /// card in a row leaves the row; its text goes under the row.)
    static func unwrapping(_ card: Card, in s: NSTextStorage) -> Edit? {
        guard let number = number(of: card, in: s) else { return nil }
        var arrangement = CardArrangement(s)
        guard let piece = arrangement.unwrap(card: number) else { return nil }
        return edit(to: arrangement, caret: arrangement.offset(ofPiece: piece), in: s)
    }

    /// Removing a card with everything in it.
    static func removing(_ card: Card, in s: NSTextStorage) -> Edit? {
        guard let number = number(of: card, in: s) else { return nil }
        var arrangement = CardArrangement(s)
        let caret = arrangement.place(ofCard: number).map { arrangement.offset(ofPiece: $0.piece) } ?? card.range.location
        arrangement.remove(card: number)
        return edit(to: arrangement, caret: min(caret, (arrangement.text as NSString).length), in: s)
    }

    // MARK: Spans

    /// The span whose delimiter is at `i`.
    static func span(at i: Int, in s: NSTextStorage) -> Span? {
        guard i >= 0, i < s.length, let value = s.attribute(.mdSpan, at: i, effectiveRange: nil) as? NSValue,
              let kind = (s.attribute(.mdSpanKind, at: i, effectiveRange: nil) as? String).flatMap(MarkdownSpan.init)
        else { return nil }
        let range = value.rangeValue
        guard NSMaxRange(range) <= s.length else { return nil }
        func isOwn(_ j: Int) -> Bool { (s.attribute(.mdSpan, at: j, effectiveRange: nil) as? NSValue)?.rangeValue == range }
        var openingEnd = range.location
        while openingEnd < NSMaxRange(range), isOwn(openingEnd) { openingEnd += 1 }
        var closingStart = NSMaxRange(range)
        while closingStart > openingEnd, isOwn(closingStart - 1) { closingStart -= 1 }
        return Span(range: range, kind: kind,
                    opening: NSRange(location: range.location, length: openingEnd - range.location),
                    closing: NSRange(location: closingStart, length: NSMaxRange(range) - closingStart))
    }

    /// The inline spans of a line, outermost first.
    static func spans(in line: Line, of s: NSTextStorage) -> [Span] {
        guard line.content.length > 0 else { return [] }
        var starts: [Int] = []
        s.enumerateAttribute(.mdSpan, in: line.content) { value, _, _ in
            if let range = (value as? NSValue)?.rangeValue, !starts.contains(range.location) { starts.append(range.location) }
        }
        return starts.compactMap { span(at: $0, in: s) }.sorted {
            $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length
        }
    }

    /// The closing delimiters right after `p` of the bold, italic and strike spans whose text ends at `p`
    /// (with any closing right after those, of spans ending there too). A span cannot end with a space, so
    /// spaces typed at `p` go after them.
    static func closings(endingTextAt p: Int, in s: NSTextStorage) -> NSRange? {
        let spans = self.spans(in: line(at: p, in: s), of: s).filter { [.bold, .italic, .boldItalic, .strike].contains($0.kind) }
        var end = p
        while let span = spans.first(where: { $0.closing.location == end }) { end = NSMaxRange(span.range) }
        return end > p ? NSRange(location: p, length: end - p) : nil
    }

    // MARK: Caret

    /// Moves a caret that would stop inside hidden syntax to where it can be seen: after a block's
    /// marker (or, one step left from the block's text, to the end of the line above), and out of a
    /// delimiter towards the side it was moving to (the end, for a click). Between an escape's backslash
    /// and its character is inside too: the two show as one character.
    static func adjustCaret(_ p: Int, from old: Int, in s: NSTextStorage) -> Int {
        guard s.length > 0 else { return p }
        let line = line(at: p, in: s)
        if line.kind.isHiddenLine {
            // A card's closing line and the lines around a row of cards show nothing. Going forwards the
            // caret passes them, to the next line that shows something; otherwise (and if no line
            // follows) it goes back to the end of the text before them.
            let after = line.hasNewline ? caretPosition(atOrAfter: NSMaxRange(line.range), in: s) : nil
            let before = caretPosition(before: line.range.location, in: s)
            return (p > old ? after ?? before : before ?? after) ?? p
        }
        if let prefix = line.prefix, p >= prefix.location, p < NSMaxRange(prefix) {
            // (The line above that shows something: not a card's closing line or a row's own lines.)
            if old == NSMaxRange(prefix), p == old - 1, let above = caretPosition(before: prefix.location, in: s) { return above }
            return NSMaxRange(prefix)
        }
        guard p > line.range.location, p < line.contentsEnd else { return p }
        if isEscapeBackslash(p - 1, in: s) { return p > old ? p + 1 : adjustCaret(p - 1, from: p, in: s) }
        guard let delimiter = delimiter(around: p, in: s) else { return p }
        return p < old ? delimiter.location : NSMaxRange(delimiter)
    }

    /// A selection keeps whole pieces of syntax: an end inside a delimiter moves outwards, and a
    /// selection starting inside a block marker takes the whole marker. A selection of nothing visible
    /// (undo can leave a hidden marker selected) becomes a caret, so typing cannot replace it unseen.
    static func adjustSelection(_ r: NSRange, in s: NSTextStorage) -> NSRange {
        guard r.length > 0 else { return r }
        if onlySyntax(between: r.location, and: NSMaxRange(r), in: s) {
            return NSRange(location: adjustCaret(NSMaxRange(r), from: NSMaxRange(r), in: s), length: 0)
        }
        var start = r.location, end = NSMaxRange(r)
        if let delimiter = delimiter(around: start, in: s) { start = delimiter.location }
        if isEscapeBackslash(start - 1, in: s) { start -= 1 }
        if let delimiter = delimiter(around: end, in: s) { end = NSMaxRange(delimiter) }
        if isEscapeBackslash(end - 1, in: s) { end += 1 }
        let first = line(at: start, in: s)
        if let prefix = first.prefix, start > prefix.location, start < NSMaxRange(prefix) { start = prefix.location }
        let last = line(at: end, in: s)
        if let prefix = last.prefix, end > prefix.location, end < NSMaxRange(prefix) { end = NSMaxRange(prefix) }
        return expandingOverCards(NSRange(location: start, length: end - start), in: s)
    }

    /// Where one press of → (or ←) takes the caret from `p`: past one visible character and the hidden
    /// syntax next to it, so that every press moves the caret on screen; leftwards out of a block's
    /// text to the end of the line above.
    static func step(from p: Int, forward: Bool, in s: NSTextStorage) -> Int {
        let ns = s.string as NSString
        var q = p
        while true {
            let next = forward ? (q < ns.length ? NSMaxRange(ns.rangeOfComposedCharacterSequence(at: q)) : q)
                               : (q > 0 ? ns.rangeOfComposedCharacterSequence(at: q - 1).location : q)
            guard next != q else { return q }
            let crossed = forward ? q : next
            q = next
            let line = line(at: q, in: s)
            if let prefix = line.prefix, q >= prefix.location, q < NSMaxRange(prefix) {
                if forward { return NSMaxRange(prefix) }
                return caretPosition(before: prefix.location, in: s) ?? p
            }
            guard isHidden(crossed, in: s) else {
                // Leftwards, an escape's hidden backslash goes with its character.
                return !forward && isEscapeBackslash(q - 1, in: s) ? q - 1 : q
            }
        }
    }

    /// Where ⌥⌫ (⌥⌦) deletes to from `p`: the start (end) of the word before (after) it, in what the
    /// line shows.
    static func wordBoundary(from p: Int, forward: Bool, in s: NSTextStorage) -> Int {
        let line = line(at: p, in: s)
        let ns = s.string as NSString
        var indices: [Int] = []
        var units: [unichar] = []
        for i in line.contentStart..<line.contentsEnd where !isHidden(i, in: s) {
            indices.append(i)
            units.append(ns.character(at: i))
        }
        let shown = NSString(characters: units, length: units.count)
        let caret = indices.firstIndex { $0 >= p } ?? indices.count
        var words: [NSRange] = []
        shown.enumerateSubstrings(in: NSRange(location: 0, length: shown.length), options: [.byWords, .substringNotRequired]) {
            _, range, _, _ in words.append(range)
        }
        if forward {
            let end = words.first { NSMaxRange($0) > caret }.map(NSMaxRange) ?? indices.count
            return end > 0 ? NSMaxRange(ns.rangeOfComposedCharacterSequence(at: indices[end - 1])) : p
        }
        let start = words.last { $0.location < caret }?.location ?? 0
        return start < indices.count ? ns.rangeOfComposedCharacterSequence(at: indices[start]).location : line.contentStart
    }

    // MARK: Deleting

    enum Deletion: Equatable {
        case edit(Edit)
        /// Nothing to delete (at the very start or end of the note).
        case nothing
    }

    /// What Backspace at caret `p` does, or nil for the text view's own behaviour (an ordinary
    /// character, so typing and deleting keep coalescing into one undo step).
    static func deleteBackward(at p: Int, in s: NSTextStorage) -> Deletion? {
        let line = line(at: p, in: s)
        // A divider is deleted as a whole (the caret can only be at its end).
        if line.kind == .rule, p >= line.contentStart { return .edit(removing(wholeLine(line, in: s))) }
        // Backspace acts on what is visible: hidden syntax right before the caret does not count.
        var q = p
        while q > line.contentStart, isHidden(q - 1, in: s) { q -= 1 }
        // At the start of a card's title the card is taken away; its title and its text stay.
        if line.kind == .cardOpen, q == line.contentStart, let card = card(at: line.range.location, in: s),
           let edit = unwrapping(card, in: s) {
            return .edit(edit)
        }
        // At the start of a block's text the block becomes plain text (its indentation stays), as in Notion.
        if let prefix = line.prefix, q == NSMaxRange(prefix) { return .edit(removing(marker(of: line, in: s))) }
        if q == line.range.location {
            guard q > 0 else { return .nothing }
            let above = self.line(at: q - 1, in: s)
            if above.kind.isCardStructure {
                // The first line of a card's text, or the line after a card: the lines around the card are
                // never joined to text. An empty line goes (not a card's only line); otherwise the caret
                // just moves to the end of what is before it.
                let target = caretPosition(before: line.range.location, in: s) ?? q
                let isEmpty = line.contentsEnd == line.range.location
                let isOnlyLine = above.kind == .cardOpen
                    && (NSMaxRange(line.range) >= s.length || self.line(at: NSMaxRange(line.range), in: s).kind == .cardClose)
                let range = isEmpty && !isOnlyLine ? wholeLine(line, in: s) : NSRange(location: q, length: 0)
                return .edit(Edit(range: range, string: "", caret: target))
            }
            if above.kind == .rule { return .edit(removing(wholeLine(above, in: s))) }
            // Joins the lines (the whole line break, "\r\n" too).
            return q == p ? nil : .edit(removing(NSRange(location: above.contentsEnd, length: q - above.contentsEnd)))
        }
        let character = self.character(at: q - 1, in: s)
        let edit = deletion(of: character, in: s)
        return q == p && edit.range == character && edit.string.isEmpty ? nil : .edit(edit)
    }

    /// What Delete (forward) at caret `p` does, or nil for the text view's own behaviour.
    static func deleteForward(at p: Int, in s: NSTextStorage) -> Deletion? {
        let line = line(at: p, in: s)
        if line.kind == .rule { return .edit(removing(wholeLine(line, in: s))) }
        var q = p
        while q < line.contentsEnd, isHidden(q, in: s), !isEscapeBackslash(q, in: s) { q += 1 }
        if q == line.contentsEnd {
            guard line.hasNewline else { return q == p ? nil : .nothing }
            // The line break after a card's title holds the card together.
            if line.kind == .cardOpen { return .nothing }
            if NSMaxRange(line.range) < s.length {
                let below = self.line(at: NSMaxRange(line.range), in: s)
                if below.kind.isCardStructure {
                    // So do the one before its closing line and the one before the card: only an empty
                    // line above a card goes.
                    let isEmpty = line.contentsEnd == line.range.location
                    return (below.kind == .cardOpen || below.kind == .rowOpen) && isEmpty ? .edit(removing(line.range)) : .nothing
                }
                if below.kind == .rule { return .edit(removing(wholeLine(below, in: s))) }
                // The block below joins this line without its marker, as in Notion.
                if let prefix = below.prefix {
                    return .edit(removing(NSRange(location: line.contentsEnd, length: NSMaxRange(prefix) - line.contentsEnd)))
                }
            }
            let lineBreak = NSRange(location: line.contentsEnd, length: NSMaxRange(line.range) - line.contentsEnd)
            return q == p ? nil : .edit(removing(lineBreak))
        }
        let character = self.character(at: isEscapeBackslash(q, in: s) ? q + 1 : q, in: s)
        let edit = deletion(of: character, in: s)
        return q == p && edit.range == character && edit.string.isEmpty ? nil : .edit(edit)
    }

    /// Deleting `r` (a selection, or what a key deletes) as the user sees it: hidden syntax in it that
    /// belongs to a span reaching outside it stays ("**bo|ld** te|xt" leaves "**bo**xt"), an escaped
    /// character goes with its backslash, a span left with no visible text goes whole (no empty "****" or
    /// "[](url)" is left behind), and a block whose line break goes joins the line above without its
    /// marker. The rest must show as it did: where Markdown would read it differently ("*a*x*b*" without
    /// "x"), it is rewritten (InlineFormatting.remainder). With `replacing` (text is about to replace the
    /// selection), a span whose text is selected stays, empty, for the new text to go in, as in Notion.
    static func deletion(of r: NSRange, in s: NSTextStorage, replacing: Bool = false) -> Edit {
        guard r.length > 0 else { return Edit(range: r, string: "", caret: r.location) }
        var r = r
        if replacing {
            // What is selected is what shows: hidden syntax at the ends of the selection (an arrow key
            // that selects "猫" in "[猫](url)" takes the "[" with it) does not decide what is replaced.
            var start = r.location, end = NSMaxRange(r)
            while start < end, isHidden(start, in: s), !isEscapeBackslash(start, in: s) { start += 1 }
            while end > start, isHidden(end - 1, in: s) { end -= 1 }
            if end > start { r = NSRange(location: start, length: end - start) }
        }
        let next = line(at: NSMaxRange(r), in: s)
        // The block after the deletion joins the line it starts on — if something of that line stays: whole
        // lines (a whole card) go, and the block after them stays as it is. (Not a card: the syntax of its
        // opening line is half of it, and stays.)
        if !replacing, NSMaxRange(r) == next.range.location, next.range.location > 0, let prefix = next.prefix,
           !next.kind.isCardStructure, r.location > line(at: r.location, in: s).range.location {
            r = NSUnionRange(r, prefix)
        }
        var deleted = IndexSet(integersIn: r.location..<NSMaxRange(r))
        for i in r.location..<NSMaxRange(r) {
            if let span = span(at: i, in: s), NSIntersectionRange(span.range, r) != span.range { deleted.remove(i) }
            if isEscapeBackslash(i, in: s), i + 1 >= NSMaxRange(r) { deleted.remove(i) }
        }
        if isEscapeBackslash(r.location - 1, in: s) { deleted.insert(r.location - 1) }
        var spans: [Span] = []
        var location = r.location
        repeat {
            let line = line(at: location, in: s)
            spans += self.spans(in: line, of: s)
            location = NSMaxRange(line.range)
        } while location < NSMaxRange(r) && location < s.length
        var emptied = true
        while emptied {
            emptied = false
            for span in spans.reversed() where !deleted.contains(integersIn: span.range.location..<NSMaxRange(span.range)) {
                if replacing, r.location >= span.content.location, NSMaxRange(r) <= NSMaxRange(span.content) { continue }
                let content = span.content.location..<NSMaxRange(span.content)
                if !content.contains(where: { !deleted.contains($0) && !isHidden($0, in: s) }) {
                    deleted.insert(integersIn: span.range.location..<NSMaxRange(span.range))
                    emptied = true
                }
            }
        }
        guard let first = deleted.first, let last = deleted.last else {
            return Edit(range: NSRange(location: r.location, length: 0), string: "", caret: r.location)
        }
        // The lines the deletion touches, which become one.
        let start = line(at: first, in: s).range.location
        let region = NSRange(location: start, length: line(at: last + 1, in: s).contentsEnd - start)
        let ns = s.string as NSString
        let kept = (region.location..<NSMaxRange(region)).filter { !deleted.contains($0) }.map { ns.character(at: $0) }
        var result = Edit(range: region, string: String(utf16CodeUnits: kept, count: kept.count),
                          caret: r.location - deleted.count(in: min(first, r.location)..<r.location))
        let nearSyntax = (max(first - 1, 0)...min(last + 1, s.length - 1)).contains { isHidden($0, in: s) }
        if !replacing, nearSyntax, let repaired = InlineFormatting.remainder(of: region, deleting: deleted, in: s, caret: r.location) {
            result = Edit(range: region, string: repaired.text, caret: region.location + repaired.caret)
        }
        return minimal(result, in: s)
    }

    /// `edit` narrowed to what actually changes, on whole characters (so that undo selects just that).
    static func minimal(_ edit: Edit, in s: NSTextStorage) -> Edit {
        let old = (s.string as NSString).substring(with: edit.range) as NSString
        let new = edit.string as NSString
        var prefix = 0, suffix = 0
        while prefix < old.length, prefix < new.length, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        while suffix < old.length - prefix, suffix < new.length - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        func splits(_ string: NSString, _ i: Int) -> Bool {
            i > 0 && i < string.length && string.rangeOfComposedCharacterSequence(at: i).location != i
        }
        while prefix > 0, splits(old, prefix) || splits(new, prefix) { prefix -= 1 }
        while suffix > 0, splits(old, old.length - suffix) || splits(new, new.length - suffix) { suffix -= 1 }
        return Edit(range: NSRange(location: edit.range.location + prefix, length: old.length - prefix - suffix),
                    string: new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix)),
                    caret: edit.caret)
    }

    private static func removing(_ range: NSRange) -> Edit { Edit(range: range, string: "", caret: range.location) }

    /// The block marker without the indentation before it (Backspace keeps the nesting).
    private static func marker(of line: Line, in s: NSTextStorage) -> NSRange {
        guard let prefix = line.prefix else { return NSRange(location: line.range.location, length: 0) }
        guard line.isListItem else { return prefix }
        let ns = s.string as NSString
        var start = prefix.location
        while start < NSMaxRange(prefix), ns.character(at: start) == 0x09 || ns.character(at: start) == 0x20 { start += 1 }
        return NSRange(location: start, length: NSMaxRange(prefix) - start)
    }

    /// A line with its newline (or, for the last line, with the newline before it).
    private static func wholeLine(_ line: Line, in s: NSTextStorage) -> NSRange {
        if line.hasNewline || line.range.location == 0 { return line.range }
        return NSRange(location: line.range.location - 1, length: line.range.length + 1)
    }

    private static func character(at i: Int, in s: NSTextStorage) -> NSRange {
        (s.string as NSString).rangeOfComposedCharacterSequence(at: i)
    }

    // MARK: Return

    /// What Return at caret `p` does, or nil for a plain line break.
    static func newline(at p: Int, in s: NSTextStorage) -> Edit? {
        let line = line(at: p, in: s)
        if line.kind == .cardOpen, line.hasNewline {
            // At the start of a title: an empty line above the card, as above a heading. (Not in a row
            // of cards, which holds nothing but cards.)
            if p <= line.contentStart, line.contentStart < line.contentsEnd,
               s.attribute(.mdCardRow, at: line.range.location, effectiveRange: nil) == nil {
                return Edit(range: NSRange(location: line.range.location, length: 0), string: "\n", caret: p + 1)
            }
            // Anywhere else Return goes on to the card's text: its first line if that is empty, otherwise
            // a new line above it.
            let first = self.line(at: NSMaxRange(line.range), in: s)
            let isEmpty = first.kind == .text && first.contentsEnd == first.range.location
            return Edit(range: NSRange(location: first.range.location, length: 0), string: isEmpty ? "" : "\n",
                        caret: first.range.location)
        }
        guard line.holdsInlineText else { return nil }
        let ns = s.string as NSString
        if let exit = leavingCard(from: line, in: s) { return exit }
        if let prefix = line.prefix, p <= visibleContentStart(of: line, in: s) {
            let marker = ns.substring(with: prefix)
            guard visibleContentStart(of: line, in: s) < line.contentsEnd else {
                // Return on an empty item ends the list; an empty heading or quote gets a line below.
                return line.isListItem ? removing(prefix) : nil
            }
            if line.isListItem, let empty = listPrefix(marker, next: false, keepCheck: false),
               let this = listPrefix(marker, next: true, keepCheck: true) {
                // An empty item above, as in Notion; this one keeps its text and its check mark.
                let string = empty + "\n" + this
                return Edit(range: prefix, string: string, caret: p + (string as NSString).length - prefix.length)
            }
            // A heading or quote stays as it is, with an empty line above it.
            return Edit(range: NSRange(location: line.range.location, length: 0), string: "\n", caret: p + 1)
        }
        // Elsewhere the line breaks at the caret, moved out of the delimiters it touches ("**ab|**" breaks
        // after the "**"); spans the caret is inside close before the break and open again after it.
        var q = p
        if isEscapeBackslash(q - 1, in: s) { q -= 1 }
        let spans = self.spans(in: line, of: s)
        var moved = true
        while moved {
            moved = false
            for span in spans where span.opening.length > 0 {
                if q == span.content.location { q = span.range.location; moved = true }
                if q == NSMaxRange(span.content) { q = NSMaxRange(span.range); moved = true }
            }
        }
        var continuation = "\n"
        if line.isListItem, let prefix = line.prefix, let next = listPrefix(ns.substring(with: prefix), next: true, keepCheck: false) {
            continuation += next
        }
        if spans.contains(where: { $0.content.location < q && q < NSMaxRange($0.content) }) {
            let lineRange = NSRange(location: line.range.location, length: line.contentsEnd - line.range.location)
            let split = InlineFormatting.lineBreak(at: q - line.range.location, in: ns.substring(with: lineRange),
                                                   continuation: continuation)
            return Edit(range: lineRange, string: split.text, caret: line.range.location + split.caret)
        }
        if q == p, continuation == "\n" { return nil }
        return Edit(range: NSRange(location: q, length: 0), string: continuation,
                    caret: q + (continuation as NSString).length)
    }

    /// Return on the empty last line of a card's text leaves the card, as it ends a list: the caret goes
    /// to an empty line after the card (a new one, if the line there holds something) — after the whole
    /// row, if the card stands in one — and the line it left goes, unless it is the card's only line of text.
    private static func leavingCard(from line: Line, in s: NSTextStorage) -> Edit? {
        guard line.kind == .text, line.contentsEnd == line.range.location, line.hasNewline, NSMaxRange(line.range) < s.length
        else { return nil }
        let close = self.line(at: NSMaxRange(line.range), in: s)
        guard close.kind == .cardClose, let card = card(at: close.range.location, in: s) else { return nil }
        let last = row(at: card.range.location, in: s)?.close ?? close // the last line to pass
        let ns = s.string as NSString
        let after = last.hasNewline ? self.line(at: NSMaxRange(last.range), in: s) : nil
        let emptyLineFollows = after.map { $0.kind == .text && $0.contentsEnd == $0.range.location } ?? false
        let start = card.content.length == line.range.length ? close.range.location : line.range.location
        // From the card's closing line to the end of the last line to pass: as it is.
        let kept = ns.substring(with: NSRange(location: close.range.location, length: last.contentsEnd - close.range.location))
        let string = kept + "\n" + (last.hasNewline && !emptyLineFollows ? "\n" : "")
        return minimal(Edit(range: NSRange(location: start, length: NSMaxRange(last.range) - start), string: string,
                            caret: start + (kept as NSString).length + 1), in: s)
    }

    private static let listMarker = makeRegex(#"^([ \t]*)(?:([-*+])|(\d{1,9})([.)]))([ \t]+)(?:\[("# + TaskState.characterClass
                                              + #")\]([ \t]+))?"#)

    /// A list item's prefix written for another item of the list: with the next number, and with the
    /// check box kept or emptied.
    static func listPrefix(_ prefix: String, next: Bool, keepCheck: Bool) -> String? {
        let ns = prefix as NSString
        guard let m = listMarker.firstMatch(in: prefix, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        var result = group(1) ?? ""
        if let number = group(3).flatMap({ Int($0) }) {
            result += "\(next ? number + 1 : number)" + (group(4) ?? ".")
        } else {
            result += group(2) ?? "-"
        }
        result += group(5) ?? " "
        if let check = group(6) { result += "[" + (keepCheck ? check : " ") + "]" + (group(7) ?? " ") }
        return result
    }
}
