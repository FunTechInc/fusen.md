import AppKit

/// Converts a note to Notion-flavored Markdown — the syntax of `markdown_version: "v2"` on the page
/// markdown endpoints — and back (see guides/data-apis/notion-flavored-markdown and, for what changed
/// from the deprecated "enhanced markdown" (v1), guides/data-apis/migrate-to-notion-flavored-markdown).
///
/// The export never parses Markdown on its own: it runs MarkdownStyler and reads what the styler
/// recorded — the line kind (`mdLine`), Markdown syntax (`mdMarker`), literal code (`mdCode`) and
/// bare URLs (`mdBareURL`) — so a note has the same structure in Notion as on screen. Everything the
/// styler shows as plain text is escaped, so Notion shows it as plain text too (`$5` stays `$5`, not
/// inline math; `a | b` stays text, not a table; `# x` indented or inside a list item stays text,
/// not a heading). Where the app and the format differ, the export writes the format's form: bold,
/// italic and strikethrough become the tags `<b>`, `<i>` and `<s>` (the app shows `**「強調」**です`
/// in bold, which CommonMark's rules for `**` would not), `~~~` fences become backtick fences, and a
/// link whose target is not an absolute URL stays text.
///
/// The format is CommonMark with Notion's tags. Blocks are separated by a blank line, so a blank line
/// of the note is an empty paragraph (`<p />`), and a line break inside a block is `<br />`. Only list
/// items nest by indentation: any other block with children is a tag, with its text on the line after
/// the opening tag and its children after a blank line, not indented. A color is an attribute of the
/// block's tag (`<todo checked="false" color="blue">`).
@MainActor
enum NotionMarkdown {
    /// Characters that are always syntax in Notion's rich text. ("_" and "&" are escaped only where
    /// they would be syntax, see `escape`; ">", "#", "-", "+" and numbers only at the start of a block,
    /// see `escapingBlockStart`.)
    static let escapedCharacters: Set<Character> = ["\\", "*", "~", "`", "$", "[", "]", "<", "|"]
    /// An empty paragraph: a blank line of the note.
    static let emptyParagraph = "<p />"
    /// A line break inside a block.
    static let lineBreak = "<br />"

    // Only used to find where a line's content starts; its kind always comes from the styler.
    // Same patterns as the block regexes in MarkdownStyler.
    private static let headingPrefix = makeRegex(#"^ {0,3}#{1,6}(?:[ \t]+|$)"#)
    private static let quotePrefix = makeRegex(#"^ {0,3}(?:>[ \t]+)+|^ {0,3}>[ \t]*$"#)
    private static let taskPrefix = makeRegex(#"^([ \t]*)(?:[-*+]|\d{1,9}[.)])[ \t]+\[("# + TaskState.characterClass
                                              + #")\](?:[ \t]+|$)"#)
    private static let listPrefix = makeRegex(#"^([ \t]*)(?:[-*+]|(\d{1,9})[.)])(?:[ \t]+|$)"#)
    /// The part of a link after its label, as MarkdownStyler matches it: `](target "title")`.
    private static let linkTail = makeRegex(#"\]\(([^()\s]+)(?:[ \t]+"[^"\n]*")?\)"#)

    // Block syntax at the start of a block's text (see `escapingBlockStart`).
    private static let blockStart = makeRegex(#"^(?:#+|[-+])(?=[ \t]|$)|^>|^-[- \t]*$|^([-_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let orderedStart = makeRegex(#"^\d{1,9}(?=[.)](?:[ \t]|$))"#)
    private static let closingHashes = makeRegex(#"(?:^|[ \t])(#+)$"#)
    /// "&" with what makes it a character reference ("&amp;", "&#38;", "&#x26;"), which Markdown decodes.
    private static let referenceStart = makeRegex(#"^&(?:#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});"#)

    // MARK: Export

    /// The note as Notion-flavored Markdown. Trailing blank lines are dropped.
    static func export(_ text: String, styler: MarkdownStyler) -> String {
        let storage = NSTextStorage(string: text)
        styler.restyle(storage)
        var exporter = Exporter(storage: storage)
        return exporter.run()
    }

    /// A block of the note on its way to Notion; its text is Notion's rich text already.
    private final class Block {
        enum Kind: Equatable {
            /// The note itself.
            case note
            case paragraph, quote, divider, empty
            case heading(Int)
            case bullet
            /// A numbered item, with the number it has in the note.
            case ordered(String)
            case todo(TaskState)
            /// Its lines, the two fences included.
            case code([String])
            case callout(CardColor)
            case columns, column
        }

        let kind: Kind
        var text: String
        var children: [Block] = []

        init(_ kind: Kind, _ text: String = "") {
            self.kind = kind
            self.text = text
        }

        /// The marker of a list item that is written in Markdown ("- ", "3. ", "- [ ] "): one without a
        /// color, whose children — if it has any, and then it needs a text of its own — are such items
        /// too. Every other list item is written as a tag.
        var listMarker: String? {
            let marker: String
            switch kind {
            case .bullet: marker = "- "
            case .ordered(let number): marker = number + ". "
            case .todo(.todo): marker = "- [ ] "
            case .todo(.done): marker = "- [x] "
            default: return nil
            }
            guard children.isEmpty || (!text.isEmpty && children.allSatisfy { $0.listMarker != nil }) else { return nil }
            return marker
        }

        /// Items of one family that follow each other are one Markdown list: "-" (bullets and to-dos) or "1".
        var listFamily: Character? {
            listMarker.map { $0.hasPrefix("-") ? "-" : "1" }
        }
    }

    /// Reads the note line by line and builds its blocks: which block is the child of which is decided
    /// here, as the indentation of the note says; how that is written is `render`'s business.
    @MainActor
    private struct Exporter {
        let storage: NSTextStorage
        let ns: NSString
        let note = Block(.note)
        /// Where a block at depth 0 goes: the note, or the callout of the card being exported.
        var container: Block
        /// The columns of the row of cards being exported.
        var row: Block?
        /// The last block at each depth below `container`: a deeper block becomes the child of the one above it.
        var path: [Block] = []
        /// The last block that is not a blank line; it limits how deep the next one may be nested.
        var previous: (depth: Int, canHaveChildren: Bool)?
        /// Blank lines not added yet. They get the parent of the next block, so a blank line inside a
        /// nested list does not end the nesting; trailing ones are dropped.
        var blankLines = 0
        /// Quote lines waiting to be joined into one block.
        var quote: [String]?
        /// The code block being read: the length of its fence (3 for "~~~"), its language, its lines.
        var code: (fence: Int, info: String, lines: [String])?

        init(storage: NSTextStorage) {
            self.storage = storage
            ns = storage.string as NSString
            container = note
        }

        mutating func run() -> String {
            var location = 0
            while location < ns.length {
                var start = 0, end = 0, contentsEnd = 0
                ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                                for: NSRange(location: location, length: 0))
                line(NSRange(location: start, length: contentsEnd - start), kind: kind(at: start))
                location = end
            }
            flushQuote()
            closeCode() // an unclosed fence runs to the end of the note, as in the app
            return NotionMarkdown.render(note.children).joined(separator: "\n")
        }

        private func kind(at location: Int) -> MarkdownLine {
            (storage.attribute(.mdLine, at: location, effectiveRange: nil) as? String).flatMap(MarkdownLine.init) ?? .text
        }

        private mutating func line(_ range: NSRange, kind: MarkdownLine) {
            let raw = ns.substring(with: range)
            if kind != .quote { flushQuote() }

            switch kind {
            case .code:
                code?.lines.append(raw) // literal, never escaped
            case .fence:
                if code == nil { openCode(raw) } else { closeCode() }
            case .rule:
                add(Block(.divider), depth: 0, canHaveChildren: false)
            case .h1, .h2, .h3, .h4:
                let content = NotionMarkdown.after(NotionMarkdown.headingPrefix, in: range, ns)
                add(Block(.heading(kind.headingLevel ?? 1), NotionMarkdown.escapingClosingHashes(inline(content))),
                    depth: 0, canHaveChildren: false) // headings cannot have children
            case .quote:
                var content = NotionMarkdown.after(NotionMarkdown.quotePrefix, in: range, ns)
                // A list or task marker inside a quote is not rich text syntax: keep it as plain text.
                var prefix = ""
                if let m = NotionMarkdown.taskPrefix.firstMatch(in: ns as String, range: content)
                    ?? NotionMarkdown.listPrefix.firstMatch(in: ns as String, range: content) {
                    prefix = NotionMarkdown.escape(ns.substring(with: m.range))
                    content = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(content) - NSMaxRange(m.range))
                }
                quote = (quote ?? []) + [prefix + inline(content)]
            case .bullet, .ordered, .task, .text:
                listOrText(range, raw: raw, kind: kind)
            case .rowOpen:
                // Cards side by side: columns, each holding one card.
                let columns = Block(.columns)
                add(columns, depth: 0, canHaveChildren: false)
                row = columns
            case .rowClose:
                row = nil
            case .cardOpen:
                // A card is a callout in its color; its title is the callout's own text, in bold.
                let parts = CardSyntax.parseOpen(ns, line: range)
                let title = ns.substring(with: parts.title).trimmingCharacters(in: .whitespaces)
                let callout = Block(.callout(parts.color), title.isEmpty ? "" : "<b>" + NotionMarkdown.escape(title) + "</b>")
                if let row {
                    let column = Block(.column)
                    column.children = [callout]
                    row.children.append(column)
                } else {
                    add(callout, depth: 0, canHaveChildren: false)
                }
                container = callout
                path = []
                previous = nil
            case .cardClose:
                // Blank lines at the end of a card are dropped, as at the end of the note.
                blankLines = 0
                container = note
                path = []
                previous = (0, false)
            }
        }

        /// Adds a block at `depth` below `container` — at most one deeper than the block before it, and
        /// not below a block that cannot have children — after the blank lines waiting before it.
        private mutating func add(_ block: Block, depth requested: Int, canHaveChildren: Bool) {
            let limit = previous.map { $0.canHaveChildren ? $0.depth + 1 : $0.depth } ?? 0
            let depth = min(requested, limit, path.count)
            let parent = depth == 0 ? container : path[depth - 1]
            parent.children += (0..<blankLines).map { _ in Block(.empty) }
            blankLines = 0
            parent.children.append(block)
            path = Array(path.prefix(depth)) + [block]
            previous = (depth, canHaveChildren)
        }

        /// Code blocks are always top level (in a card: the callout's child), and always backtick
        /// fences, the only kind the format has.
        private mutating func openCode(_ raw: String) {
            let text = String(raw.drop { $0 == " " || $0 == "\t" }).trimmingTrailingWhitespace
            let run = text.prefix { $0 == text.first }
            var info = String(text.dropFirst(run.count))
            var lines: [String] = []
            if info.contains("`") {
                // A backtick fence's info string cannot contain "`" (CommonMark): Notion would read the
                // line as text with inline code and the code after it as Markdown. The app shows a code
                // block, so the text after the fence becomes its first line.
                let trimmed = info.trimmingCharacters(in: .whitespaces)
                if !trimmed.allSatisfy({ $0 == "`" }) { lines.append(trimmed) }
                info = ""
            }
            code = (run.first == "`" ? run.count : 3, info, lines)
        }

        /// The fence is longer than every run of backticks in the code, as the format asks (and so also
        /// longer than a line of backticks that a "~~~" block may hold).
        private mutating func closeCode() {
            guard let open = code else { return }
            code = nil
            let longest = open.lines.map(NotionMarkdown.longestBacktickRun).max() ?? 0
            let fence = String(repeating: "`", count: max(open.fence, longest + 1))
            add(Block(.code([fence + open.info] + open.lines + [fence])), depth: 0, canHaveChildren: false)
        }

        private mutating func listOrText(_ range: NSRange, raw: String, kind: MarkdownLine) {
            if kind == .text, raw.allSatisfy(\.isWhitespace) {
                blankLines += 1
                return
            }
            let text = ns as String
            var block = Block.Kind.paragraph
            var indentation = NSRange(location: range.location, length: 0)
            var content = range
            if kind == .task, let m = NotionMarkdown.taskPrefix.firstMatch(in: text, range: range) {
                indentation = m.range(at: 1)
                // Waiting and in progress are not done: Notion gets them unchecked, in the signal's color.
                block = .todo(TaskState(character: ns.character(at: m.range(at: 2).location)) ?? .todo)
                content = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(range) - NSMaxRange(m.range))
            } else if kind == .bullet || kind == .ordered, let m = NotionMarkdown.listPrefix.firstMatch(in: text, range: range) {
                indentation = m.range(at: 1)
                block = m.range(at: 2).location != NSNotFound ? .ordered(ns.substring(with: m.range(at: 2))) : .bullet
                content = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(range) - NSMaxRange(m.range))
            } else {
                var i = range.location
                while i < NSMaxRange(range), ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
                indentation = NSRange(location: range.location, length: i - range.location)
                content = NSRange(location: i, length: NSMaxRange(range) - i)
            }
            add(Block(block, NotionMarkdown.escapingBlockStart(inline(content))),
                depth: NotionMarkdown.depth(of: ns.substring(with: indentation)), canHaveChildren: true)
        }

        private mutating func flushQuote() {
            guard var parts = quote else { return }
            // Leading spaces would be block syntax too (four make a code block).
            parts[0] = NotionMarkdown.escapingBlockStart(String(parts[0].drop { $0 == " " || $0 == "\t" }))
            add(Block(.quote, parts.joined(separator: NotionMarkdown.lineBreak)), depth: 0, canHaveChildren: true)
            quote = nil
        }

        /// Rich text: code verbatim, bold, italic and strikethrough as Notion's tags, other special
        /// characters escaped, bare URLs as links. Inside a link's label (`inLabel`) a bare URL stays
        /// text: links cannot nest.
        private func inline(_ range: NSRange, inLabel: Bool = false) -> String {
            var end = NSMaxRange(range)
            if !inLabel {
                while end > range.location, ns.character(at: end - 1) == 0x20 || ns.character(at: end - 1) == 0x09 { end -= 1 }
            }
            var out = ""
            var open: [String] = [] // the tags open at this point, outermost first
            var i = range.location
            while i < end {
                var run = NSRange()
                if storage.attribute(.mdBareURL, at: i, longestEffectiveRange: &run,
                                     in: NSRange(location: i, length: end - i)) != nil {
                    let url = ns.substring(with: run)
                    if inLabel || !NotionMarkdown.isLinkTarget(url) {
                        out += NotionMarkdown.escape(url)
                    } else {
                        out = NotionMarkdown.notImage(out) + "[" + NotionMarkdown.escape(url) + "](" + url + ")"
                    }
                    i = NSMaxRange(run)
                    continue
                }
                let isMarker = storage.attribute(.mdMarker, at: i, effectiveRange: nil) != nil
                if isMarker, ns.character(at: i) == 0x5B, let link = link(at: i, end: end) { // "[" of [label](url)
                    let label = inline(link.label, inLabel: true)
                    if NotionMarkdown.isLinkTarget(link.target) {
                        out = NotionMarkdown.notImage(out) + "[" + label + "](" + link.target + ")" // a title is dropped
                    } else {
                        // Notion links need an absolute URL: a relative path or an anchor stays text.
                        out += "\\[" + label + NotionMarkdown.escape(ns.substring(with: link.tail))
                    }
                    i = NSMaxRange(link.tail)
                    continue
                }
                if isMarker, let delimiter = emphasis(at: i), i + delimiter.length <= end {
                    if delimiter.opens {
                        open += delimiter.tags
                        out += delimiter.tags.map { "<\($0)>" }.joined()
                    } else {
                        for tag in delimiter.tags.reversed() {
                            // (A span that opened outside this text has nothing to close here.)
                            guard let index = open.lastIndex(of: tag) else { continue }
                            // Tags must nest: what opened inside the span closes with it, and opens again after it.
                            let inner = Array(open[(index + 1)...])
                            out += inner.reversed().map { "</\($0)>" }.joined() + "</\(tag)>" + inner.map { "<\($0)>" }.joined()
                            open.remove(at: index)
                        }
                    }
                    i += delimiter.length
                    continue
                }
                let character = ns.rangeOfComposedCharacterSequence(at: i)
                let string = ns.substring(with: character)
                if isMarker || storage.attribute(.mdCode, at: i, effectiveRange: nil) != nil
                    || storage.attribute(.mdEscaped, at: i, effectiveRange: nil) != nil {
                    out += string // syntax, code, or a character the note already escaped
                } else if string == "_" {
                    // Between two letters "_" is never emphasis (snake_case stays as it is).
                    let within = range.location..<end
                    out += isWord(i - 1, within) && isWord(i + 1, within) ? "_" : "\\_"
                } else if string == "&" {
                    let rest = NSRange(location: i, length: end - i)
                    out += NotionMarkdown.referenceStart.firstMatch(in: ns as String, range: rest) != nil ? "\\&" : "&"
                } else {
                    out += NotionMarkdown.escape(string)
                }
                i = NSMaxRange(character)
            }
            return out + open.reversed().map { "</\($0)>" }.joined()
        }

        /// The bold, italic or strikethrough delimiter at `i`: Notion's tags for its span, and whether it
        /// opens the span. (`_x_` and `__x__` are the same spans as `*x*` and `**x**`.)
        private func emphasis(at i: Int) -> (tags: [String], length: Int, opens: Bool)? {
            guard let raw = storage.attribute(.mdSpanKind, at: i, effectiveRange: nil) as? String,
                  let kind = MarkdownSpan(rawValue: raw),
                  let span = (storage.attribute(.mdSpan, at: i, effectiveRange: nil) as? NSValue)?.rangeValue
            else { return nil }
            switch kind {
            case .bold: return (["b"], 2, i == span.location)
            case .italic: return (["i"], 1, i == span.location)
            case .boldItalic: return (["b", "i"], 3, i == span.location)
            case .strike: return (["s"], 2, i == span.location)
            case .code, .link: return nil
            }
        }

        /// A letter or a digit of the note's text at `i` (not syntax, code or a link the export rewrites).
        private func isWord(_ i: Int, _ within: Range<Int>) -> Bool {
            guard within.contains(i) else { return false }
            for key in [NSAttributedString.Key.mdMarker, .mdCode, .mdEscaped, .mdBareURL]
            where storage.attribute(key, at: i, effectiveRange: nil) != nil {
                return false
            }
            let string = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: i))
            return string.count == 1 && NotionMarkdown.isWord(Character(string))
        }

        /// The link whose "[" is at `start`, as MarkdownStyler matched it (its label has no "]").
        private func link(at start: Int, end: Int) -> (label: NSRange, target: String, tail: NSRange)? {
            let close = ns.range(of: "]", range: NSRange(location: start + 1, length: end - start - 1))
            guard close.location != NSNotFound,
                  let m = NotionMarkdown.linkTail.firstMatch(in: ns as String, options: .anchored,
                                                            range: NSRange(location: close.location, length: end - close.location))
            else { return nil }
            return (NSRange(location: start + 1, length: close.location - start - 1),
                    ns.substring(with: m.range(at: 1)), m.range)
        }
    }

    // MARK: Export: how blocks are written

    /// The lines of blocks that follow each other. A blank line separates them; only the items of one
    /// Markdown list follow each other directly.
    private static func render(_ blocks: [Block], indentation: String = "") -> [String] {
        var lines: [String] = []
        for (index, block) in blocks.enumerated() {
            if index > 0, !(block.listFamily != nil && block.listFamily == blocks[index - 1].listFamily) {
                lines.append("")
            }
            lines += render(block, indentation: indentation)
        }
        return lines
    }

    private static func render(_ block: Block, indentation: String) -> [String] {
        if let marker = block.listMarker {
            // A list item in Markdown: its children are list items too, indented to where its text starts.
            var lines = [indentation + marker + block.text]
            if let first = block.children.first {
                // An empty item, or a number other than 1, cannot follow the text directly: Markdown
                // would read that line as more of the text.
                if first.text.isEmpty || !(first.listFamily == "-" || first.listMarker == "1. ") { lines.append("") }
                let width = block.listFamily == "-" ? 2 : marker.count
                lines += render(block.children, indentation: indentation + String(repeating: " ", count: width))
            }
            return lines
        }
        // Anything else starts its lines at the margin: it is never the child of a Markdown list item
        // (see `listMarker`), only of the note or of a tag.
        switch block.kind {
        case .note:
            return render(block.children)
        case .paragraph:
            return block.children.isEmpty ? [block.text] : tagged("<p>", block.text, block.children, "</p>")
        case .quote:
            return block.children.isEmpty ? ["> " + block.text] : tagged("<quote>", block.text, block.children, "</quote>")
        case .heading(let level):
            return [String(repeating: "#", count: level) + " " + block.text]
        case .divider:
            return ["---"]
        case .empty:
            return [emptyParagraph]
        case .code(let lines):
            return lines
        case .bullet:
            return ["<ul>"] + tagged("<li>", block.text, block.children, "</li>") + ["</ul>"]
        case .ordered:
            return ["<ol>"] + tagged("<li>", block.text, block.children, "</li>") + ["</ol>"]
        case .todo(let state):
            return tagged(todoTag(state), block.text, block.children, "</todo>")
        case .callout(let color):
            var text = block.text
            var children = block.children
            // Without a title the callout starts with the card's text, as a callout written in Notion
            // does — unless that text would come back as a title.
            if text.isEmpty, let first = children.first, first.kind == .paragraph, first.children.isEmpty,
               cardTitle(first.text) == nil {
                text = first.text
                children.removeFirst()
            }
            return tagged(calloutTag(color), text, children, "</callout>")
        case .columns:
            return ["<columns>"] + block.children.flatMap { render($0, indentation: "") } + ["</columns>"]
        case .column:
            return ["<column>"] + render(block.children) + ["</column>"]
        }
    }

    /// A block written as a tag: its text on the line after the opening tag, its children after a blank
    /// line. No blank line touches a tag (Notion would keep it as whitespace); a block without text that
    /// has children starts with an empty paragraph, so that its first child is not read as its text.
    private static func tagged(_ open: String, _ text: String, _ children: [Block], _ close: String) -> [String] {
        var lines = [open]
        if !text.isEmpty {
            lines.append(text)
        } else if !children.isEmpty {
            lines.append(emptyParagraph)
        }
        if !children.isEmpty {
            lines.append("")
            lines += render(children)
        }
        return lines + [close]
    }

    // MARK: Cards and signals

    /// The icon of the callout a card becomes (a callout always has one).
    static let cardIcon = "📌"

    /// A card is a callout with the card's color as its background (none for the default color).
    static func calloutTag(_ color: CardColor) -> String {
        color == .default ? "<callout icon=\"\(cardIcon)\">" : "<callout icon=\"\(cardIcon)\" color=\"\(color.rawValue)_bg\">"
    }

    /// The color of a to-do that is in progress (the ring's blue) or waiting (the star's yellow).
    static func signalColor(_ state: TaskState) -> String? {
        switch state {
        case .doing: "blue"
        case .waiting: "yellow"
        case .todo, .done: nil
        }
    }

    /// The signal of an unchecked to-do of `color` (as text or as background), if it is one: the colors the
    /// app sends, and orange, which it sent for one that waits before that had a star.
    static func signal(forColor color: String?) -> TaskState? {
        guard let color else { return nil }
        let name = color.hasSuffix("_bg") ? String(color.dropLast(3)) : color
        if name == "orange" { return .waiting }
        return TaskState.allCases.first { signalColor($0) == name }
    }

    /// A to-do as a tag: the only way to give it a color, or children that are not list items.
    static func todoTag(_ state: TaskState) -> String {
        "<todo checked=\"\(state == .done)\"" + (signalColor(state).map { " color=\"\($0)\"" } ?? "") + ">"
    }

    private static func after(_ prefix: NSRegularExpression, in range: NSRange, _ ns: NSString) -> NSRange {
        guard let m = prefix.firstMatch(in: ns as String, range: range) else { return range }
        return NSRange(location: NSMaxRange(m.range), length: NSMaxRange(range) - NSMaxRange(m.range))
    }

    /// Nesting depth from leading whitespace, as in MarkdownStyler: one level per tab or per two spaces.
    private static func depth(of indentation: String) -> Int {
        let tabs = indentation.filter { $0 == "\t" }.count
        return tabs + (indentation.count - tabs) / 2
    }

    /// Text with every character escaped that Notion would read as syntax: the characters that always
    /// are; "_" unless it stands between two letters or digits (where Markdown never reads it as
    /// emphasis); and "&" where it would start a character reference ("&amp;").
    static func escape(_ string: String) -> String {
        let characters = Array(string)
        var out = ""
        for (index, character) in characters.enumerated() {
            let isSyntax: Bool
            switch character {
            case "_":
                isSyntax = !(index > 0 && isWord(characters[index - 1])
                             && index + 1 < characters.count && isWord(characters[index + 1]))
            case "&":
                let rest = String(characters[index...])
                isSyntax = referenceStart.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) != nil
            default:
                isSyntax = escapedCharacters.contains(character)
            }
            if isSyntax { out.append("\\") }
            out.append(character)
        }
        return out
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// Text at the start of a block (paragraph, list item, to-do, quote) that the app shows as text
    /// but that is block syntax in Markdown: a heading (`# `), a list item (`- `, `+ `, `1. `, `1) `),
    /// a quote (`>`) or a divider (`---`, `- -`, `___`). Notion would make it a block, inside a list
    /// item a child block; a backslash (CommonMark's escape for any ASCII punctuation) keeps it text.
    static func escapingBlockStart(_ text: String) -> String {
        let indentation = String(text.prefix { $0 == " " || $0 == "\t" })
        let rest = String(text.dropFirst(indentation.count))
        let range = NSRange(location: 0, length: (rest as NSString).length)
        if blockStart.firstMatch(in: rest, range: range) != nil {
            return indentation + "\\" + rest
        }
        if let m = orderedStart.firstMatch(in: rest, range: range) {
            let digits = (rest as NSString).substring(with: m.range)
            return indentation + digits + "\\" + rest.dropFirst(digits.count)
        }
        return text
    }

    /// A heading's text that ends in " #" (or is only "#"): Markdown drops that as a closing sequence.
    static func escapingClosingHashes(_ text: String) -> String {
        guard let m = closingHashes.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        else { return text }
        return (text as NSString).replacingCharacters(in: NSRange(location: m.range(at: 1).location, length: 0), with: "\\")
    }

    /// "!" right before a link would make it an image.
    static func notImage(_ text: String) -> String {
        text.hasSuffix("!") ? String(text.dropLast()) + "\\!" : text
    }

    /// A target Notion can link to: an http(s) URL with a host, or mailto:, within the API's
    /// 2000-character URL limit. Anything else could make Notion reject the whole note.
    static func isLinkTarget(_ target: String) -> Bool {
        guard target.utf16.count <= 2000, let url = URL(string: target), let scheme = url.scheme?.lowercased()
        else { return false }
        switch scheme {
        case "http", "https": return !(url.host() ?? "").isEmpty
        case "mailto": return target.count > "mailto:".count
        default: return false
        }
    }

    /// The longest run of backticks in a line.
    private static func longestBacktickRun(_ line: String) -> Int {
        var longest = 0, run = 0
        for character in line {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
    }

    // MARK: Import

    /// Names (in Japanese) of Notion-only elements in Notion-flavored Markdown — things the sticky can
    /// only show as tags or literal text, and that become plain text in Notion when the note is sent
    /// back. Code, escaped characters and link targets are ignored, so text the app itself sent
    /// (`\<callout>`, `` `$x$` ``) is not reported; neither is what becomes a card, a row of cards, a
    /// signal or a nested block.
    static func notionOnlyElements(in markdown: String) -> [String] {
        let imported = convert(markdown)
        let joined = imported.remains.joined(separator: "\n")
        let withoutCode = joined.replacingOccurrences(of: #"(`+)[^\n]*?\1|<code>[^\n]*?</code>"#, with: " ", options: .regularExpression)
        let unescaped = withoutCode.replacingOccurrences(of: #"\\[!-/:-@\[-`{-~]"#, with: " ", options: .regularExpression)
        let withoutTargets = unescaped.replacingOccurrences(of: #"\]\([^)\n]*\)"#, with: "] ", options: .regularExpression)
        // Tags that are reported under a name of their own, or that the app has syntax for.
        let known = "b|i|s|u|code|br|span|callout|toggle|table|colgroup|col|tr|td|th|table-of-contents|columns|column|page"
            + "|database|folder|mention|date|image|audio|video|file|pdf|bookmark|embed|link-preview|external_object_instance"
            + "|synced-block|synced-block-reference|meeting-notes[a-z-]*|unknown|equation|p|h[1-4]|li|ul|ol|quote|todo"
        let kinds: [(name: String, pattern: String, in: String)] = [
            ("コールアウト", #"<callout[\s>]"#, withoutTargets),
            ("トグル", #"<toggle[\s>]"#, withoutTargets),
            // A table with colors or widths is a tag; a plain one is a pipe table, known by its "| --- |" row.
            ("表", #"<table[\s>]|(?m)^\|?[ \t]*:?-{3,}:?[ \t]*(?:\|[ \t]*:?-{3,}:?[ \t]*)+\|?[ \t]*$|(?m)^\|[ \t]*:?-{3,}:?[ \t]*\|[ \t]*$"#, withoutTargets),
            ("目次", #"<table-of-contents"#, withoutTargets),
            ("段組み", #"<columns[\s>]"#, withoutTargets),
            ("サブページ・データベース", #"<(?:page|database|folder)[\s>]"#, withoutTargets),
            ("メンション", #"<(?:mention|date)[\s/>]"#, withoutTargets),
            // Colored words and underlines, and a block in a color (the color is on the block's tag).
            ("文字色・下線", #"<span[\s>]|<u>|<(?:p|h[1-4]|li|quote|todo|toggle)\s[^>\n]*\bcolor=""#, withoutTargets),
            ("画像・ファイル", #"!\[[^\]\n]*\]\(|<(?:image|audio|video|file|pdf)[\s>]"#, unescaped),
            ("ブックマーク・埋め込み", #"<(?:bookmark|embed|link-preview|external_object_instance)[\s/>]"#, withoutTargets),
            ("同期ブロック", #"<synced-block"#, withoutTargets),
            ("会議メモ", #"<meeting-notes"#, withoutTargets),
            ("引用元", #"\[\^"#, unescaped),
            ("数式", #"\$[^$\n]+\$|<equation[\s>]"#, withoutTargets),
            ("取得できなかったブロック", #"<unknown[\s/>]"#, withoutTargets),
            ("その他のブロック", "<(?!(?:" + known + #")[\s/>])[A-Za-z][A-Za-z0-9_-]*[\s/>]"#, withoutTargets),
        ]
        var names = kinds.filter { $0.in.range(of: $0.pattern, options: .regularExpression) != nil }.map(\.name)
        if imported.equation, !names.contains("数式") { names.append("数式") }
        // A line break the app cannot keep inside a heading. (A "<br />" inside inline code stays
        // literal text on import, so it is not reported: the app itself exports such notes.)
        if imported.headingLineBreak { names.append("ブロック内の改行") }
        // Columns that are not cards side by side come in one below the other.
        if imported.flattenedColumns, !names.contains("段組み") { names.append("段組み") }
        if imported.nestedCode { names.append("入れ子のコードブロック") }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// Notion-flavored Markdown back to the app's Markdown (「Notion の内容を取り込む」). Reverses
    /// `export`: `<p />` becomes a blank line, a block's children become indented lines under it
    /// (whether Notion wrote them indented under a list item or between the block's tags), and
    /// `<br />` a new line — inside a quote a new `>` line, inside a list item or to-do an indented
    /// line under it. `<b>`, `<i>`, `<s>` and `<code>` become `**`, `*`, `~~` and backticks.
    ///
    /// Notion's backslash escapes are kept only where the app would otherwise read the character as
    /// syntax (MarkdownStyler decides), so a note that was exported comes back unchanged and `\*`,
    /// `\#` or `1\.` stay text; an `_` that the app would read as emphasis gets one, because Notion
    /// never writes emphasis with `_` (`__init__` stays `__init__`). Code, `$…$` and `$$` equations
    /// and link targets are copied verbatim (parentheses in a target are percent-encoded, which the
    /// app's links need); a link whose text is its URL becomes a bare URL when the app shows it as one.
    /// Blocks the app cannot nest (code blocks, headings, quotes, dividers) come back at the top
    /// level. Tags the app does not know (toggles, tables, …) are left as they are, and so are the two
    /// tag lines around a block in a color the app cannot show.
    ///
    /// A callout becomes a card — its color the card's, its own text the card's title — and columns that
    /// each hold one callout become a row of cards (other columns come in one below the other). A to-do
    /// in the color of a signal (blue: in progress, orange: waiting) becomes that signal.
    static func fromNotion(_ markdown: String) -> String {
        convert(markdown).lines.joined(separator: "\n")
    }

    private static func convert(_ markdown: String) -> Importer {
        var importer = Importer()
        importer.render(elements(markdown.components(separatedBy: "\n")), depth: 0, inCard: false, nested: false)
        return importer
    }

    // MARK: Import: reading Notion's blocks

    /// A block of Notion's Markdown on its way into the app; its text is still Notion's rich text.
    private struct Element {
        enum Kind: Equatable {
            case paragraph, quote, divider, empty
            case heading(Int)
            case bullet
            /// A numbered item, with its number if Notion wrote one.
            case ordered(String?)
            case todo(TaskState)
            /// Lines that are copied as they are: a code block with its fences, an equation with its "$$" lines.
            case code([String]), equation([String])
            case callout(CardColor)
            case columns, column
            /// A line the app has no block for (a tag it does not know, a tag that is never closed): it stays text.
            case literal
        }

        var kind: Kind
        var text = ""
        var children: [Element] = []
        /// The two tag lines the block was written between, if it was written as a tag.
        var open = "", close = ""
        /// The tag has a color the app cannot show: its two lines stay, as text, around the block.
        var keepsTags = false
    }

    private struct Tag {
        let name: String
        let attributes: [String: String]
        let isClosing: Bool
        let isSelfClosing: Bool
    }

    private static let tagLine = makeRegex(#"^<(/?)([A-Za-z][A-Za-z0-9_-]*)((?:\s+[A-Za-z_][A-Za-z0-9_:.-]*(?:="[^"]*")?)*)\s*(/?)>$"#)
    /// A block's two tags with its text between them, all on one line: `<quote>text</quote>`.
    private static let taggedLine = makeRegex(#"^(<([a-z][a-z0-9]*)(?:\s+[A-Za-z_][A-Za-z0-9_:.-]*(?:="[^"]*")?)*\s*>)(.*)(</\2>)$"#)
    private static let tagAttribute = makeRegex(#"([A-Za-z_][A-Za-z0-9_:.-]*)="([^"]*)""#)
    /// The tags whose blocks the app has: everything between their two lines is read as their text and children.
    private static let containerTags: Set<String> = ["callout", "columns", "column", "p", "quote", "ul", "ol", "li", "todo", "h1", "h2", "h3", "h4"]
    private static let dividerLine = makeRegex(#"^-(?:[ \t]*-){2,}$"#)
    private static let headingLine = makeRegex(#"^(#{1,6})(?:[ \t]+|$)"#)
    /// A list item's marker — never escaped — and the checkbox of a to-do after it.
    private static let listLine = makeRegex(#"^(?:[-*+]|(\d{1,9})[.)])(?:[ \t]+|$)(?:\[([ xX])\](?:[ \t]+|$))?"#)
    private static let bareURLWhole = makeRegex("^" + MarkdownStyler.bareURLPattern + "$")

    /// The tag a line consists of, if it is one tag and nothing else.
    private static func tag(_ line: String) -> Tag? {
        let ns = line as NSString
        guard let m = tagLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var attributes: [String: String] = [:]
        for a in tagAttribute.matches(in: line, range: m.range(at: 3)) {
            attributes[ns.substring(with: a.range(at: 1))] = ns.substring(with: a.range(at: 2))
        }
        return Tag(name: ns.substring(with: m.range(at: 2)), attributes: attributes,
                   isClosing: m.range(at: 1).length > 0, isSelfClosing: m.range(at: 4).length > 0)
    }

    private static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }
    private static func indentation(of line: String) -> String { String(line.prefix { $0 == " " || $0 == "\t" }) }
    /// A line without the whitespace around it.
    private static func body(of line: String) -> String {
        String(line.drop { $0 == " " || $0 == "\t" }).trimmingTrailingWhitespace
    }
    /// How far whitespace indents: a tab counts as four columns, as in Markdown.
    private static func width(of indentation: String) -> Int {
        indentation.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    /// The index of the line that closes the tag opened at `start` (the same tag may open again inside;
    /// nothing in a code block is a tag).
    private static func closing(of name: String, from start: Int, in lines: [String]) -> Int? {
        var depth = 0
        var fence: (character: Character, length: Int)?
        for index in (start + 1)..<lines.count {
            let line = body(of: lines[index])
            if let opened = fence {
                if let run = fenceRun(line), run.character == opened.character, run.length >= opened.length { fence = nil }
                continue
            }
            if let run = fenceRun(line) { fence = run; continue }
            guard let tag = tag(line), tag.name == name, !tag.isSelfClosing else { continue }
            if !tag.isClosing {
                depth += 1
            } else if depth == 0 {
                return index
            } else {
                depth -= 1
            }
        }
        return nil
    }

    /// A list item: its kind, the text after its marker, and how wide the marker is (its children are
    /// indented that far).
    private static func listItem(_ line: String) -> (kind: Element.Kind, text: String, width: Int)? {
        let ns = line as NSString
        guard let m = listLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let text = ns.substring(from: NSMaxRange(m.range))
        if m.range(at: 2).location != NSNotFound {
            return (.todo(ns.substring(with: m.range(at: 2)) == " " ? .todo : .done), text, 2)
        }
        if m.range(at: 1).location != NSNotFound {
            return (.ordered(ns.substring(with: m.range(at: 1))), text, m.range(at: 1).length + 2)
        }
        return (.bullet, text, 2)
    }

    /// Whether a line starts a block of its own (otherwise, right under a line of text, it continues that text).
    private static func startsBlock(_ line: String) -> Bool {
        let range = NSRange(location: 0, length: (line as NSString).length)
        return fenceRun(line) != nil || line == "$$" || line.hasPrefix(">") || line.hasPrefix("|") || tag(line) != nil
            || dividerLine.firstMatch(in: line, range: range) != nil || headingLine.firstMatch(in: line, range: range) != nil
            || listItem(line) != nil
    }

    /// Whether a line ends in the "\" that is Markdown's hard line break (not in "\\", a backslash).
    private static func endsInHardBreak(_ text: String) -> Bool {
        text.reversed().prefix { $0 == "\\" }.count % 2 == 1
    }

    /// Text with the line that follows it in the same block: after a line break if the text ends in
    /// one, otherwise after a space.
    private static func joined(_ text: String, _ next: String) -> String {
        endsInHardBreak(text) ? String(text.dropLast()) + lineBreak + next : text + " " + next
    }

    /// The blocks in `lines`. Blank lines only separate blocks (an empty paragraph is `<p />`).
    private static func elements(_ lines: [String]) -> [Element] {
        var out: [Element] = []
        var index = 0
        while index < lines.count {
            let lead = indentation(of: lines[index])
            let line = body(of: lines[index])
            let whole = NSRange(location: 0, length: (line as NSString).length)
            index += 1
            if line.isEmpty { continue }

            if let fence = fenceRun(line) {
                // A code block: copied as it is, without the indentation of its fence. Notion calls a
                // block without a language "txt"; the app writes that as no language.
                let language = line.dropFirst(fence.length).trimmingCharacters(in: .whitespaces)
                var code = [language == "txt" ? String(line.prefix(fence.length)) : line]
                while index < lines.count {
                    let text = lines[index].hasPrefix(lead) ? String(lines[index].dropFirst(lead.count)) : lines[index]
                    code.append(text)
                    index += 1
                    let inner = body(of: text)
                    if let close = fenceRun(inner), close.character == fence.character, close.length >= fence.length,
                       inner.count == close.length {
                        break
                    }
                }
                out.append(Element(kind: .code(code)))
            } else if line == "$$" {
                var equation = [line]
                while index < lines.count {
                    equation.append(body(of: lines[index]))
                    index += 1
                    if equation.last == "$$" { break }
                }
                out.append(Element(kind: .equation(equation)))
            } else if let tag = tag(line) {
                if tag.name == "p", tag.isSelfClosing {
                    out.append(Element(kind: .empty))
                } else if tag.isSelfClosing, containerTags.contains(tag.name) {
                    out += container(tag, open: line, inner: [], close: "") // a block without text or children
                } else if !tag.isClosing, containerTags.contains(tag.name),
                          let end = closing(of: tag.name, from: index - 1, in: lines) {
                    out += container(tag, open: line, inner: Array(lines[index..<end]), close: body(of: lines[end]))
                    index = end + 1
                } else {
                    out.append(Element(kind: .literal, text: line))
                }
            } else if let m = taggedLine.firstMatch(in: line, range: whole), let tag = tag((line as NSString).substring(with: m.range(at: 1))),
                      containerTags.contains(tag.name) {
                // Notion writes a block's tags on lines of their own, but reads them on one line too.
                let ns = line as NSString
                out += container(tag, open: ns.substring(with: m.range(at: 1)), inner: [ns.substring(with: m.range(at: 3))],
                                 close: ns.substring(with: m.range(at: 4)))
            } else if dividerLine.firstMatch(in: line, range: whole) != nil {
                out.append(Element(kind: .divider))
            } else if let m = headingLine.firstMatch(in: line, range: whole) {
                out.append(Element(kind: .heading(min(m.range(at: 1).length, 4)), text: (line as NSString).substring(from: NSMaxRange(m.range))))
            } else if line.hasPrefix(">") {
                // Lines that follow each other are one quote; each is a line of it.
                var parts = [String(line.hasPrefix("> ") ? line.dropFirst(2) : line.dropFirst())]
                while index < lines.count {
                    let next = body(of: lines[index])
                    if next.hasPrefix(">") {
                        // (The next line is a line of the quote anyway: a hard break before it says no more.)
                        if endsInHardBreak(parts[parts.count - 1]) { parts[parts.count - 1].removeLast() }
                        parts.append(String(next.hasPrefix("> ") ? next.dropFirst(2) : next.dropFirst()))
                    } else if !next.isEmpty, !startsBlock(next) {
                        parts[parts.count - 1] = joined(parts[parts.count - 1], next) // a line without ">" right under it
                    } else {
                        break
                    }
                    index += 1
                }
                out.append(Element(kind: .quote, text: parts.joined(separator: lineBreak)))
            } else if let item = listItem(line) {
                // Its children: the lines indented under it (by a tab, or by spaces up to where its text starts).
                var inner: [String] = []
                var blank = 0
                while index < lines.count {
                    let next = lines[index]
                    if isBlank(next) {
                        blank += 1
                    } else if width(of: indentation(of: next)) >= width(of: lead) + 2 {
                        inner += Array(repeating: "", count: blank)
                        blank = 0
                        inner.append(unindented(next, lead: lead, width: item.width))
                    } else {
                        break
                    }
                    index += 1
                }
                index -= blank // blank lines before the next block are not the item's
                var element = Element(kind: item.kind, text: item.text)
                var first = 0
                while first < inner.count, !inner[first].isEmpty, !startsBlock(body(of: inner[first])) {
                    element.text = joined(element.text, body(of: inner[first])) // more of the item's own text
                    first += 1
                }
                element.children = elements(Array(inner[first...]))
                out.append(element)
            } else {
                // A paragraph, with the lines right under it that do not start a block (a table row stays a line).
                var text = line
                while !line.hasPrefix("|"), index < lines.count {
                    let next = body(of: lines[index])
                    guard !next.isEmpty, !startsBlock(next) else { break }
                    text = joined(text, next)
                    index += 1
                }
                out.append(Element(kind: .paragraph, text: text))
            }
        }
        return out
    }

    /// A line of a list item's children without the indentation the item gave it: one tab, or the
    /// spaces up to where the item's text starts.
    private static func unindented(_ line: String, lead: String, width: Int) -> String {
        var rest = Substring(line)
        rest = rest.hasPrefix(lead) ? rest.dropFirst(lead.count) : rest.drop { $0 == " " || $0 == "\t" }
        if rest.first == "\t" { return String(rest.dropFirst()) }
        var spaces = 0
        while spaces < width, rest.first == " " {
            rest = rest.dropFirst()
            spaces += 1
        }
        return String(rest)
    }

    /// The block (or blocks) a tag with its closing line is. The text of the block is the paragraph right
    /// after the opening tag; an empty paragraph there means the block has no text; what follows are
    /// its children.
    private static func container(_ tag: Tag, open: String, inner: [String], close: String) -> [Element] {
        var children = elements(inner)
        switch tag.name {
        case "columns":
            return [Element(kind: .columns, children: children, open: open, close: close)]
        case "column":
            return [Element(kind: .column, children: children, open: open, close: close)]
        case "ul":
            return children // the list is not a block: its items are
        case "ol":
            return children.map { item in
                var item = item
                if item.kind == .bullet, item.open.hasPrefix("<li") { item.kind = .ordered(nil) }
                return item
            }
        default:
            break
        }
        var text = ""
        if let first = children.first {
            if first.kind == .empty {
                children.removeFirst()
            } else if first.kind == .paragraph, first.children.isEmpty, !first.keepsTags {
                text = first.text
                children.removeFirst()
            }
        }
        let color = tag.attributes["color"].flatMap { $0 == "default" ? nil : $0 }
        var element = Element(kind: .paragraph, text: text, children: children, open: open, close: close)
        // A color is only kept where the app has something for it: a card's color, a signal.
        element.keepsTags = color != nil
        switch tag.name {
        case "callout":
            let name = color.map { $0.hasSuffix("_bg") ? String($0.dropLast(3)) : $0 } ?? CardColor.default.rawValue
            element.kind = .callout(CardColor(rawValue: name) ?? .default)
            element.keepsTags = false
        case "todo":
            // Unchecked and in the color of a signal (as text or as background): that signal.
            let signal = signal(forColor: color)
            if tag.attributes["checked"] == "true" {
                element.kind = .todo(.done)
            } else if let signal {
                element.kind = .todo(signal)
                element.keepsTags = false
            } else {
                element.kind = .todo(.todo)
            }
        case "quote":
            element.kind = .quote
        case "li":
            element.kind = .bullet
        case "h1", "h2", "h3", "h4":
            // A heading has no children: what is nested in it follows it.
            element.kind = .heading(Int(tag.name.dropFirst()) ?? 1)
            element.children = []
            return [element] + children
        default: // "p"
            if text.isEmpty, children.isEmpty, color == nil { element.kind = .empty }
        }
        return [element]
    }

    // MARK: Import: writing the app's lines

    /// Writes Notion's blocks as the lines of a note, and collects what `notionOnlyElements` reports.
    @MainActor
    private struct Importer {
        let styler = MarkdownStyler()
        var lines: [String] = []
        /// The text and the tags that stay Notion's own: everything but code, and but the tags that
        /// became a card, a row of cards, a signal or a nesting.
        var remains: [String] = []
        /// Some columns were not cards side by side (they hold other blocks, or more than one): what
        /// they hold comes one below the other.
        var flattenedColumns = false
        var nestedCode = false
        var equation = false
        var headingLineBreak = false

        /// `depth`: how deep the blocks are nested (one tab each); in a card it starts again at 0.
        /// In a card (`inCard`) nothing more becomes a card: cards do not nest. `nested`: the blocks
        /// are the children of a block.
        mutating func render(_ elements: [Element], depth: Int, inCard: Bool, nested: Bool) {
            var previous: Int? // the number of the numbered item right before
            for element in elements {
                var number = 0
                if case .ordered(let written) = element.kind {
                    // Notion numbers a list itself: the first item starts it, each one after it counts on.
                    // So an item without a number (one written as a tag), or with a number that does not
                    // count on ("1." for every item is valid Markdown), gets the next one.
                    let own = written.flatMap { Int($0) }
                    number = previous.map { last in own.map { $0 > last ? $0 : last + 1 } ?? last + 1 } ?? own ?? 1
                    previous = number
                } else {
                    previous = nil
                }
                render(element, number: number, depth: depth, inCard: inCard, nested: nested)
            }
        }

        private mutating func render(_ element: Element, number: Int, depth: Int, inCard: Bool, nested: Bool) {
            let lead = String(repeating: "\t", count: depth)
            if element.keepsTags { literal(element.open, lead) }
            switch element.kind {
            case .empty:
                lines.append("")
            case .divider:
                lines.append("---")
            case .code(let code):
                // The app's code blocks are top level: one nested under another block comes back there.
                lines += code
                if nested { nestedCode = true }
            case .equation(let source):
                // The app shows an equation as its source: escaped wherever it would read it as Markdown.
                equation = true
                lines += source.map { $0 == "$$" ? $0 : NotionMarkdown.appLine("", "", $0, styler: styler, literal: true, textOnly: true) }
            case .heading(let level):
                // A line break inside a heading: the rest follows as text.
                text(element.text, prefix: String(repeating: "#", count: level) + " ", lead: "", continuation: "")
                if NotionMarkdown.lineBreaks(element.text).count > 1 { headingLineBreak = true }
            case .paragraph:
                text(element.text, prefix: "", lead: lead, continuation: lead)
                render(element.children, depth: depth + 1, inCard: inCard, nested: true)
            case .bullet, .ordered, .todo:
                let marker: String
                switch element.kind {
                case .ordered: marker = "\(number). "
                case .todo(let state): marker = "- [\(state.rawValue)] "
                default: marker = "- "
                }
                text(element.text, prefix: marker, lead: lead, continuation: lead + "\t")
                render(element.children, depth: depth + 1, inCard: inCard, nested: true)
            case .quote:
                remains.append(element.text)
                // An empty part is ">" (it continues the quote above); only a quote that starts empty needs "> ".
                for (index, part) in NotionMarkdown.lineBreaks(element.text).enumerated() {
                    lines.append(part.isEmpty ? (index == 0 ? "> " : ">") : NotionMarkdown.appLine("", "> ", part, styler: styler))
                }
                render(element.children, depth: 1, inCard: inCard, nested: true)
            case .literal:
                literal(element.text, lead)
            case .callout(let color):
                if inCard {
                    // A callout in a callout stays as it came: cards do not nest.
                    literal(element.open, lead)
                    if !element.text.isEmpty { text(element.text, prefix: "", lead: lead, continuation: lead) }
                    render(element.children, depth: depth, inCard: true, nested: nested)
                    literal(element.close, lead)
                } else {
                    card(element, color)
                }
            case .columns:
                let cards = element.children.map { column -> (Element, CardColor)? in
                    guard column.kind == .column, column.children.count == 1, case .callout(let color) = column.children[0].kind
                    else { return nil }
                    return (column.children[0], color)
                }
                if inCard {
                    literal(element.open, lead)
                    render(element.children, depth: depth, inCard: true, nested: nested)
                    literal(element.close, lead)
                } else if !cards.isEmpty, cards.allSatisfy({ $0 != nil }) {
                    // Columns that each hold one callout and nothing else: a row of cards.
                    lines.append(CardSyntax.rowOpenMarker)
                    for case let (callout, color)? in cards { card(callout, color) }
                    lines.append(CardSyntax.rowCloseMarker)
                } else {
                    flattenedColumns = true
                    for column in element.children {
                        render(column.kind == .column ? column.children : [column], depth: depth, inCard: false, nested: nested)
                    }
                }
            case .column:
                if inCard { literal(element.open, lead) }
                render(element.children, depth: depth, inCard: inCard, nested: nested)
                if inCard { literal(element.close, lead) }
            }
            if element.keepsTags { literal(element.close, lead) }
        }

        /// A callout as a card. Its own text is the card's title if it is all bold, which is how the app
        /// sends a title; any other text is the first line of the card's text, so a card without a title
        /// comes back as it was sent. (A card stands at the start of its lines, wherever the callout was.)
        private mutating func card(_ callout: Element, _ color: CardColor) {
            let title = NotionMarkdown.cardTitle(callout.text)
            lines.append(CardSyntax.openLine(color: color, title: title ?? ""))
            if title == nil, !callout.text.isEmpty { text(callout.text, prefix: "", lead: "", continuation: "") }
            render(callout.children, depth: 0, inCard: true, nested: false)
            lines.append(CardSyntax.closeMarker)
        }

        /// The rich text of a block as the app's lines: after `prefix` (the block's marker), and after each
        /// line break one more line, which is text (`continuation` is what it starts with).
        private mutating func text(_ content: String, prefix: String, lead: String, continuation: String) {
            remains.append(content)
            let parts = NotionMarkdown.lineBreaks(content)
            lines.append(NotionMarkdown.appLine(lead, prefix, parts[0], styler: styler))
            lines += parts.dropFirst().map { NotionMarkdown.appLine(continuation, "", $0, styler: styler, textOnly: true) }
        }

        /// A line that stays as Notion wrote it, as text. (None for the closing line of a tag that is
        /// closed in itself.)
        private mutating func literal(_ line: String, _ lead: String) {
            guard !line.isEmpty else { return }
            remains.append(line)
            lines.append(NotionMarkdown.appLine(lead, "", line, styler: styler))
        }
    }

    /// The title of the card a callout becomes, if the callout's own text is one: text that is all bold
    /// and nothing else (`<b>名前</b>`, or `**名前**`).
    static func cardTitle(_ text: String) -> String? {
        let inner: Substring
        if text.hasPrefix("<b>"), text.hasSuffix("</b>"), text.count > 7 {
            inner = text.dropFirst(3).dropLast(4)
        } else if text.hasPrefix("**"), text.hasSuffix("**"), text.count > 4 {
            inner = text.dropFirst(2).dropLast(2)
        } else {
            return nil
        }
        // No other tag inside it, and no second bold span (an escaped "<" or "*" is text).
        let bare = inner.replacingOccurrences(of: #"\\[!-/:-@\[-`{-~]"#, with: "", options: .regularExpression)
        guard !bare.contains("<"), !bare.contains("**") else { return nil }
        return plainText(String(inner))
    }

    /// The line kind Notion meant: from its block prefix.
    private static func expectedKind(prefix: String) -> MarkdownLine {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(">") { return .quote }
        if trimmed.hasPrefix("#") { return .heading(trimmed.prefix { $0 == "#" }.count) }
        if trimmed.hasSuffix("]") { return .task }
        if let first = trimmed.first, first.isNumber { return .ordered }
        return trimmed.isEmpty ? .text : .bullet
    }

    /// Rich text of one Notion block, split into what can change (characters, escaped characters)
    /// and what is copied as is (code spans, equations, links).
    private enum Piece {
        case character(Character)
        case escaped(Character)
        case verbatim(String)
        /// Equation source: shown as written, so escaped wherever the app would read it as syntax.
        case literal(Character)
    }

    /// One line of the app: `lead` (indentation) + `prefix` (block marker) + the converted `content`.
    /// Starts with every escape removed, then restores the backslash of each character the app would
    /// read as syntax, escapes `_` that it would read as emphasis, and — if the line would change
    /// kind (`\#` becoming a heading) — the escapes at the start. Repeats until nothing changes.
    private static func appLine(_ lead: String, _ prefix: String, _ content: String, styler: MarkdownStyler,
                                alwaysEscaped: Set<Character> = [], literal: Bool = false, textOnly: Bool = false) -> String {
        let pieces = literal ? content.map { Piece.literal($0) } : inlinePieces(content, styler: styler)
        let expected = expectedKind(prefix: prefix)
        let head = lead + prefix
        let base = (head as NSString).length
        var keep = Set(pieces.indices.filter {   // escaped pieces that keep their backslash
            if case .escaped(let c) = pieces[$0] { alwaysEscaped.contains(c) } else { false }
        })
        var added = Set<Int>()    // "_" pieces that get one
        for _ in 0..<6 {
            let (text, offsets) = render(pieces, keep: keep, added: added, base: base)
            let storage = NSTextStorage(string: head + text)
            styler.restyle(storage)
            func isSyntax(_ offset: Int) -> Bool {
                storage.attribute(.mdMarker, at: offset, effectiveRange: nil) != nil
                    || storage.attribute(.mdCode, at: offset, effectiveRange: nil) != nil
            }
            var changed = false
            for (index, piece) in pieces.enumerated() {
                guard let offset = offsets[index], offset < storage.length else { continue }
                switch piece {
                case .escaped where !keep.contains(index) && isSyntax(offset):
                    keep.insert(index)
                    changed = true
                case .character("_") where !added.contains(index) && isSyntax(offset),
                     .literal where !added.contains(index) && isSyntax(offset):
                    added.insert(index)
                    changed = true
                default:
                    break
                }
            }
            let kind = storage.length > 0
                ? (storage.attribute(.mdLine, at: 0, effectiveRange: nil) as? String).flatMap(MarkdownLine.init) ?? .text
                : .text
            if kind != expected {
                let restored = changed
                let unkept = pieces.indices.filter { if case .escaped = pieces[$0] { !keep.contains($0) } else { false } }
                let early = unkept.filter { (offsets[$0] ?? .max) < base + 6 }
                keep.formUnion(early.isEmpty ? unkept : early)
                changed = changed || !unkept.isEmpty
                // Nothing Notion escaped (text after <br>: "- x", "# x", "1. x", "---"): escape the
                // first punctuation, as the export's escapingBlockStart does.
                if textOnly, !restored, unkept.isEmpty, let first = pieces.indices.first(where: {
                    switch pieces[$0] {
                    case .character(let c), .literal(let c): isASCIIPunctuation(c) && !added.contains($0)
                    default: false
                    }
                }) {
                    added.insert(first)
                    changed = true
                }
            }
            if !changed { return head + text }
        }
        let all = Set(pieces.indices)
        return head + render(pieces, keep: all, added: added, base: base).text
    }

    private static func render(_ pieces: [Piece], keep: Set<Int>, added: Set<Int>, base: Int) -> (text: String, offsets: [Int: Int]) {
        var text = ""
        var offsets: [Int: Int] = [:]
        var length = base
        for (index, piece) in pieces.enumerated() {
            let string: String
            switch piece {
            case .character(let c), .literal(let c):
                string = added.contains(index) ? "\\" + String(c) : String(c)
            case .escaped(let c):
                string = keep.contains(index) ? "\\" + String(c) : String(c)
            case .verbatim(let s):
                string = s
            }
            if case .verbatim = piece {} else { offsets[index] = length + (string.utf16.count - String(string.last!).utf16.count) }
            text += string
            length += string.utf16.count
        }
        return (text, offsets)
    }

    /// Rich text of one Notion block, split into what can change (characters, escaped characters)
    /// and what is copied as is (code spans, equations, links, the delimiters of a span).
    private static func inlinePieces(_ content: String, styler: MarkdownStyler) -> [Piece] {
        let chars = Array(content)
        var pieces: [Piece] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, isASCIIPunctuation(chars[i + 1]) {
                pieces.append(text(chars[i + 1]))
                i += 2
            } else if c == "`" {
                let run = chars[i...].prefix { $0 == "`" }.count
                if let close = closingBackticks(chars, from: i + run, length: run) {
                    pieces.append(.verbatim(String(chars[i..<(close + run)])))
                    i = close + run
                } else {
                    pieces += Array(repeating: .character("`"), count: run)
                    i += run
                }
            } else if c == "$", let close = closingDollar(chars, from: i + 1) {
                pieces += chars[i...close].map { .literal($0) } // an equation: not Markdown
                i = close + 1
            } else if c == "[", let link = link(chars, at: i) {
                let url = link.url.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                let range = NSRange(location: 0, length: (url as NSString).length)
                let isBare = plainText(link.label) == link.url && bareURLWhole.firstMatch(in: url, range: range) != nil
                // The label is rich text too; its brackets must stay escaped or the link would break.
                let label = appLine("", "", link.label, styler: styler, alwaysEscaped: ["[", "]"])
                pieces.append(.verbatim(isBare ? url : "[" + label + "](" + url + ")"))
                i = link.end
            } else if c == "<", let span = span(chars, at: i, styler: styler) {
                pieces += span.pieces
                i = span.end
            } else if c == "&", let reference = characterReference(chars, at: i) {
                pieces.append(text(reference.character))
                i = reference.end
            } else {
                pieces.append(.character(c))
                i += 1
            }
        }
        return pieces
    }

    /// A character Notion wrote as text (escaped, or as a character reference). It may get a backslash
    /// in the app — but only a character the app's backslash escapes: before any other ("\$", "\<")
    /// the app would show the backslash.
    private static func text(_ c: Character) -> Piece {
        c.utf16.count == 1 && MarkdownStyler.isEscapable(c.utf16.first!) ? .escaped(c) : .character(c)
    }

    /// Notion's tag for a span the app has syntax for, starting at `start`: `<b>`, `<i>` and `<s>` become
    /// the app's delimiters around what they hold (spaces at its edges move outside: the app's
    /// delimiters must touch the text), and `<code>` a code span, whose text is literal.
    private static func span(_ chars: [Character], at start: Int, styler: MarkdownStyler) -> (pieces: [Piece], end: Int)? {
        func starts(_ text: String, at index: Int) -> Bool {
            let expected = Array(text)
            return index + expected.count <= chars.count && Array(chars[index..<(index + expected.count)]) == expected
        }
        for (name, delimiter) in [("b", "**"), ("i", "*"), ("s", "~~")] where starts("<\(name)>", at: start) {
            // The closing tag of this span: the same tag may open again inside it.
            var depth = 0
            var i = start + name.count + 2
            var close: Int?
            while i < chars.count {
                if chars[i] == "\\" {
                    i += 2
                } else if starts("<\(name)>", at: i) {
                    depth += 1
                    i += name.count + 2
                } else if starts("</\(name)>", at: i) {
                    if depth == 0 { close = i; break }
                    depth -= 1
                    i += name.count + 3
                } else {
                    i += 1
                }
            }
            guard let close else { return nil }
            let inner = Array(chars[(start + name.count + 2)..<close])
            let leading = inner.prefix { $0 == " " || $0 == "\t" }.count
            let trailing = inner.count == leading ? 0 : inner.reversed().prefix { $0 == " " || $0 == "\t" }.count
            let core = String(inner[leading..<(inner.count - trailing)])
            var pieces = inner.prefix(leading).map { Piece.character($0) }
            if !core.isEmpty {
                pieces += [.verbatim(delimiter)] + inlinePieces(core, styler: styler) + [.verbatim(delimiter)]
            }
            pieces += inner.suffix(trailing).map { Piece.character($0) }
            return (pieces, close + name.count + 3)
        }
        if starts("<code>", at: start) {
            var i = start + 6
            while i < chars.count, !starts("</code>", at: i) { i += 1 }
            guard i < chars.count, i > start + 6 else { return nil }
            let code = String(chars[(start + 6)..<i])
            // Delimiters longer than any run of backticks in the code, and not touching one.
            let fence = String(repeating: "`", count: longestBacktickRun(code) + 1)
            let padding = code.hasPrefix("`") || code.hasSuffix("`") ? " " : ""
            return ([.verbatim(fence + padding + code + padding + fence)], i + 7)
        }
        return nil
    }

    private static let namedReferences: [String: Character] = ["lt": "<", "gt": ">", "amp": "&", "quot": "\"", "apos": "'", "nbsp": "\u{A0}"]

    /// The character a reference at `start` stands for ("&lt;", "&#60;", "&#x3C;"), and the index after
    /// it. Only the names Notion's format itself uses are known; any other name stays as it is written.
    private static func characterReference(_ chars: [Character], at start: Int) -> (character: Character, end: Int)? {
        guard let semicolon = chars[start...].prefix(34).firstIndex(of: ";"), semicolon > start + 1 else { return nil }
        let name = String(chars[(start + 1)..<semicolon])
        let scalar: Unicode.Scalar?
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            scalar = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
        } else if name.hasPrefix("#") {
            scalar = UInt32(name.dropFirst(), radix: 10).flatMap(Unicode.Scalar.init)
        } else {
            scalar = namedReferences[name]?.unicodeScalars.first
        }
        guard let scalar, scalar.value >= 0x20 else { return nil } // never a line break or another control character
        return (Character(scalar), semicolon + 1)
    }

    private static func isASCIIPunctuation(_ c: Character) -> Bool {
        c.isASCII && (c.isPunctuation || c.isSymbol)
    }

    /// What Notion shows for rich text without formatting: backslash escapes removed, character
    /// references decoded.
    private static func plainText(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, isASCIIPunctuation(chars[i + 1]) {
                out.append(chars[i + 1])
                i += 2
            } else if chars[i] == "&", let reference = characterReference(chars, at: i) {
                out.append(reference.character)
                i = reference.end
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    private static func fenceRun(_ line: String) -> (character: Character, length: Int)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let length = line.prefix { $0 == first }.count
        return length >= 3 ? (first, length) : nil
    }

    /// Splits at `<br />` (and `<br/>`, `<br>`), but not inside inline code, and not at an escaped
    /// one (`\<br />` is the text "<br />").
    private static func lineBreaks(_ text: String) -> [String] {
        let chars = Array(text)
        var parts = [""]
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                parts[parts.count - 1] += String(chars[i...(i + 1)])
                i += 2
                continue
            }
            if chars[i] == "`" {
                let run = chars[i...].prefix { $0 == "`" }.count
                let end = closingBackticks(chars, from: i + run, length: run).map { $0 + run } ?? i + run
                parts[parts.count - 1] += String(chars[i..<end])
                i = end
                continue
            }
            if chars[i] == "<" {
                let rest = String(chars[i..<min(i + 6, chars.count)])
                if let tag = ["<br />", "<br/>", "<br>"].first(where: { rest.hasPrefix($0) }) {
                    parts.append("")
                    i += tag.count
                    continue
                }
                if rest == "<code>", let close = text.range(of: "</code>", range: text.index(text.startIndex, offsetBy: i)..<text.endIndex) {
                    let end = text.distance(from: text.startIndex, to: close.upperBound)
                    parts[parts.count - 1] += String(chars[i..<end])
                    i = end
                    continue
                }
            }
            parts[parts.count - 1].append(chars[i])
            i += 1
        }
        return parts
    }

    private static func closingBackticks(_ chars: [Character], from start: Int, length: Int) -> Int? {
        var i = start
        while i < chars.count {
            guard chars[i] == "`" else { i += 1; continue }
            let run = chars[i...].prefix { $0 == "`" }.count
            if run == length { return i }
            i += run
        }
        return nil
    }

    /// The closing "$" of an inline equation that starts at `start - 1` (not "$$", not escaped).
    private static func closingDollar(_ chars: [Character], from start: Int) -> Int? {
        guard start < chars.count, chars[start] != "$", !chars[start].isWhitespace else { return nil }
        var i = start
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "$" { return chars[i - 1].isWhitespace ? nil : i }
            i += 1
        }
        return nil
    }

    /// `[label](url)` starting at `start`: the raw (still escaped) label, the URL and the index after
    /// ")". The URL may contain balanced parentheses, as Wikipedia links do.
    private static func link(_ chars: [Character], at start: Int) -> (label: String, url: String, end: Int)? {
        var i = start + 1
        while i < chars.count, chars[i] != "]" {
            i += chars[i] == "\\" ? 2 : 1
        }
        guard i + 1 < chars.count, chars[i] == "]", chars[i + 1] == "(" else { return nil }
        let label = String(chars[(start + 1)..<i])
        var j = i + 2
        var depth = 0
        while j < chars.count {
            let c = chars[j]
            if c.isWhitespace { return nil }
            if c == "(" { depth += 1 } else if c == ")" {
                if depth == 0 { break }
                depth -= 1
            }
            j += 1
        }
        guard j < chars.count, j > i + 2 else { return nil }
        return (label, String(chars[(i + 2)..<j]), j + 1)
    }
}

fileprivate extension String {
    var trimmingTrailingWhitespace: String {
        var s = self
        while let last = s.last, last == " " || last == "\t" { s.removeLast() }
        return s
    }
}
