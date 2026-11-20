import AppKit

/// Converts a note to Notion-flavored ("enhanced") Markdown, the format of the page markdown
/// endpoints, and back (see guides/data-apis/enhanced-markdown, API version 2026-03-11).
///
/// The export never parses Markdown on its own: it runs MarkdownStyler and reads what the styler
/// recorded — the line kind (`mdLine`), Markdown syntax (`mdMarker`), literal code (`mdCode`) and
/// bare URLs (`mdBareURL`) — so a note has the same structure in Notion as on screen. Everything the
/// styler shows as plain text is escaped, so Notion shows it as plain text too (`$5` stays `$5`, not
/// inline math; `a | b` stays text, not a table; `# x` indented or inside a list item stays text,
/// not a heading). Where the app accepts syntax the format does not document, the export writes the
/// documented form: `_x_` and `__x__` become `*x*` and `**x**`, `~~~` fences become backtick fences,
/// and a link whose target is not an absolute URL stays text.
///
/// Notion's format is line-based: one block per line, children indented with tabs, blank lines
/// dropped (hence `<empty-block/>`), and one quote block per `>` line (hence `<br>`).
@MainActor
enum NotionMarkdown {
    /// Characters the spec says to backslash-escape outside code.
    static let escapedCharacters: Set<Character> = ["\\", "*", "~", "`", "$", "[", "]", "<", ">", "{", "}", "|", "^"]
    static let emptyBlock = "<empty-block/>"

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
    private static let blockStart = makeRegex(#"^(?:#+|[-+])(?=[ \t]|$)|^([-_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let orderedStart = makeRegex(#"^\d{1,9}(?=[.)](?:[ \t]|$))"#)
    private static let closingHashes = makeRegex(#"(?:^|[ \t])(#+)$"#)

    // MARK: Export

    /// The note as Notion-flavored Markdown. Trailing blank lines are dropped.
    static func export(_ text: String, styler: MarkdownStyler) -> String {
        let storage = NSTextStorage(string: text)
        styler.restyle(storage)
        var exporter = Exporter(storage: storage)
        return exporter.run()
    }

    @MainActor
    private struct Exporter {
        let storage: NSTextStorage
        let ns: NSString
        var lines: [String] = []
        /// Quote lines waiting to be joined into one block.
        var quote: [String]?
        /// The last block that is not a blank line; it limits how deep the next one may be nested.
        var previous: (depth: Int, canHaveChildren: Bool)?
        /// Blank lines not written yet. They are written at the depth of the next block, so a blank
        /// line inside a nested list does not end the nesting; trailing ones are dropped.
        var blankLines = 0
        /// The fence written for the code block being exported (a backtick fence, also for `~~~`).
        var openFence: String?
        /// How deep the card being exported is in Notion: its blocks are the children of a callout (which
        /// is the child of a column, in a row), one tab per level. 0 outside a card.
        var base = 0
        var inRow = false

        init(storage: NSTextStorage) {
            self.storage = storage
            ns = storage.string as NSString
        }

        mutating func run() -> String {
            var location = 0
            while location < ns.length {
                var start = 0, end = 0, contentsEnd = 0
                ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                                for: NSRange(location: location, length: 0))
                line(NSRange(location: start, length: contentsEnd - start), kind: kind(at: start), next: end)
                location = end
            }
            flushQuote()
            if let fence = openFence {
                lines.append(fence) // an unclosed fence runs to the end of the note, as in the app
            }
            return lines.joined(separator: "\n")
        }

        private func kind(at location: Int) -> MarkdownLine {
            (storage.attribute(.mdLine, at: location, effectiveRange: nil) as? String).flatMap(MarkdownLine.init) ?? .text
        }

        /// `next`: where the following line starts.
        private mutating func line(_ range: NSRange, kind: MarkdownLine, next: Int) {
            let raw = ns.substring(with: range)
            if kind != .quote { flushQuote() }

            switch kind {
            case .code:
                lines.append(String(repeating: "\t", count: base) + raw) // literal, never escaped
            case .fence:
                fence(raw, next: next)
                previous = (0, false)
            case .rule:
                emit("---", depth: 0)
                previous = (0, false)
            case .h1, .h2, .h3, .h4:
                let content = NotionMarkdown.after(NotionMarkdown.headingPrefix, in: range, ns)
                emit(String(repeating: "#", count: kind.headingLevel ?? 1) + " "
                     + NotionMarkdown.escapingClosingHashes(inline(content)), depth: 0)
                previous = (0, false) // headings cannot have children
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
                open("<columns>", depth: 0)
                inRow = true
            case .rowClose:
                close("</columns>", depth: 0)
                inRow = false
                previous = (0, false)
            case .cardOpen:
                // A card is a callout in its color; its title is the callout's own text, in bold.
                let parts = CardSyntax.parseOpen(ns, line: range)
                let depth = inRow ? 2 : 0
                if inRow { open("<column>", depth: 1) }
                open(NotionMarkdown.calloutTag(parts.color), depth: depth)
                base = depth + 1
                previous = nil
                let title = ns.substring(with: parts.title).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    emit("**" + NotionMarkdown.escape(title) + "**", depth: 0)
                    previous = (0, false)
                }
            case .cardClose:
                let depth = base - 1
                base = 0
                close("</callout>", depth: depth)
                if inRow { close("</column>", depth: 1) }
                previous = (0, false)
            }
        }

        /// The opening tag of a callout or of columns, after the blank lines waiting before it.
        private mutating func open(_ tag: String, depth: Int) {
            let indentation = String(repeating: "\t", count: depth)
            lines += Array(repeating: indentation + NotionMarkdown.emptyBlock, count: blankLines)
            blankLines = 0
            lines.append(indentation + tag)
        }

        /// A closing tag. Blank lines at the end of what it closes are dropped, as at the end of the note.
        private mutating func close(_ tag: String, depth: Int) {
            blankLines = 0
            lines.append(String(repeating: "\t", count: depth) + tag)
        }

        /// Fences are always top level (an indented fence would become a child block in Notion) and
        /// always backtick fences, the only kind the format documents.
        private mutating func fence(_ raw: String, next: Int) {
            let text = String(raw.drop { $0 == " " || $0 == "\t" }).trimmingTrailingWhitespace
            let indentation = String(repeating: "\t", count: base) // in a card: the callout's child
            if let fence = openFence {
                lines.append(indentation + fence) // the closing fence matches the one written for the opening
                openFence = nil
                return
            }
            let run = text.prefix { $0 == text.first }
            // ~~~ becomes a backtick fence longer than any line of backticks inside the block.
            let fence = run.first == "`" ? String(run)
                : String(repeating: "`", count: max(3, longestBacktickLine(from: next) + 1))
            var info = String(text.dropFirst(run.count))
            var firstLine: String?
            if info.contains("`") {
                // A backtick fence's info string cannot contain "`" (CommonMark): Notion would read the
                // line as text with inline code and the code after it as Markdown. The app shows a code
                // block, so the text after the fence becomes its first line.
                let trimmed = info.trimmingCharacters(in: .whitespaces)
                if !trimmed.allSatisfy({ $0 == "`" }) { firstLine = trimmed }
                info = ""
            }
            emit(fence + info, depth: 0)
            if let firstLine { lines.append(indentation + firstLine) }
            openFence = fence
        }

        /// The longest line made only of backticks among the code lines from `location` on.
        private func longestBacktickLine(from location: Int) -> Int {
            var longest = 0
            var location = location
            while location < ns.length, kind(at: location) == .code {
                let range = ns.lineRange(for: NSRange(location: location, length: 0))
                let line = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty, line.allSatisfy({ $0 == "`" }) { longest = max(longest, line.count) }
                location = NSMaxRange(range)
            }
            return longest
        }

        private mutating func listOrText(_ range: NSRange, raw: String, kind: MarkdownLine) {
            if kind == .text, raw.allSatisfy(\.isWhitespace) {
                blankLines += 1
                return
            }
            let text = ns as String
            var marker = ""
            var color = ""
            var indentation = NSRange(location: range.location, length: 0)
            var content = range
            if kind == .task, let m = NotionMarkdown.taskPrefix.firstMatch(in: text, range: range) {
                indentation = m.range(at: 1)
                // Waiting and in progress are not done: Notion gets them unchecked, in the signal's color.
                let state = TaskState(character: ns.character(at: m.range(at: 2).location)) ?? .todo
                marker = state == .done ? "- [x] " : "- [ ] "
                if let name = NotionMarkdown.signalColor(state) { color = " {color=\"\(name)\"}" }
                content = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(range) - NSMaxRange(m.range))
            } else if kind == .bullet || kind == .ordered, let m = NotionMarkdown.listPrefix.firstMatch(in: text, range: range) {
                indentation = m.range(at: 1)
                marker = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) + ". " : "- "
                content = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(range) - NSMaxRange(m.range))
            } else {
                var i = range.location
                while i < NSMaxRange(range), ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
                indentation = NSRange(location: range.location, length: i - range.location)
                content = NSRange(location: i, length: NSMaxRange(range) - i)
            }
            // Notion nests with tabs, one level deeper than the parent at most.
            let limit = previous.map { $0.canHaveChildren ? $0.depth + 1 : $0.depth } ?? 0
            let depth = min(NotionMarkdown.depth(of: ns.substring(with: indentation)), limit)
            emit(marker + NotionMarkdown.escapingBlockStart(inline(content)) + color, depth: depth)
            previous = (depth, true)
        }

        private mutating func flushQuote() {
            guard var parts = quote else { return }
            // Leading spaces would be block syntax too (four make a code block).
            parts[0] = NotionMarkdown.escapingBlockStart(String(parts[0].drop { $0 == " " || $0 == "\t" }))
            emit("> " + parts.joined(separator: "<br>"), depth: 0)
            previous = (0, true)
            quote = nil
        }

        /// Appends a block at `depth` — in a card, that deep inside the card's callout — after the blank
        /// lines waiting before it (at the same depth, so that they and the block share a parent).
        private mutating func emit(_ block: String, depth: Int) {
            let indentation = String(repeating: "\t", count: base + depth)
            lines += Array(repeating: indentation + NotionMarkdown.emptyBlock, count: blankLines)
            blankLines = 0
            lines.append(indentation + block)
        }

        /// Rich text: syntax and code verbatim, other special characters escaped, bare URLs as links.
        /// Inside a link's label (`inLabel`) a bare URL stays text: links cannot nest.
        private func inline(_ range: NSRange, inLabel: Bool = false) -> String {
            var end = NSMaxRange(range)
            if !inLabel {
                while end > range.location, ns.character(at: end - 1) == 0x20 || ns.character(at: end - 1) == 0x09 { end -= 1 }
            }
            var out = ""
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
                let character = ns.rangeOfComposedCharacterSequence(at: i)
                let string = ns.substring(with: character)
                if isMarker, string == "_" {
                    out += "*" // _italic_ and __bold__: the format only has * and **
                } else if isMarker || storage.attribute(.mdCode, at: i, effectiveRange: nil) != nil
                            || storage.attribute(.mdEscaped, at: i, effectiveRange: nil) != nil {
                    out += string // syntax, code, or a character the note already escaped
                } else {
                    out += NotionMarkdown.escape(string)
                }
                i = NSMaxRange(character)
            }
            return out
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

    // MARK: Cards and signals

    /// The icon of the callout a card becomes (a callout always has one).
    static let cardIcon = "📌"

    /// A card is a callout with the card's color as its background (none for the default color).
    static func calloutTag(_ color: CardColor) -> String {
        color == .default ? "<callout icon=\"\(cardIcon)\">" : "<callout icon=\"\(cardIcon)\" color=\"\(color.rawValue)_bg\">"
    }

    /// The color of a to-do that is in progress (the ring's blue) or waiting (the pause mark's pink).
    static func signalColor(_ state: TaskState) -> String? {
        switch state {
        case .doing: "blue"
        case .waiting: "pink"
        case .todo, .done: nil
        }
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

    static func escape(_ string: String) -> String {
        var out = ""
        for character in string {
            if escapedCharacters.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// Text at the start of a block (paragraph, list item, to-do, quote) that the app shows as text
    /// but that is block syntax in Markdown: a heading (`# `), a list item (`- `, `+ `, `1. `, `1) `)
    /// or a divider (`---`, `___`). Notion would make it a block, inside a list item a child block;
    /// a backslash (CommonMark's escape for any ASCII punctuation) keeps it text.
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

    // MARK: Import

    /// Names (in Japanese) of Notion-only elements in Notion-flavored Markdown — things the sticky can
    /// only show as tags or literal text, and that become plain text in Notion when the note is sent
    /// back. Code blocks, inline code, escaped characters and link targets are ignored, so text the
    /// app itself sent (`\<callout>`, `` `$x$` ``) is not reported.
    static func notionOnlyElements(in markdown: String) -> [String] {
        var fence: (character: Character, length: Int)?
        var text: [String] = []
        var nestedCode = false
        // What becomes a card, a row of cards or a signal is not Notion-only: only what is left over.
        let converted = cardLines(markdown.components(separatedBy: "\n"))
        let lines = converted.lines.compactMap { line -> String? in
            guard case .notion(let line) = line else { return nil }
            let body = String(line.drop { $0 == "\t" || $0 == " " })
            let prefix = blockPrefix(of: body)
            return signalToDo(prefix: prefix, content: String(body.dropFirst(prefix.count))).map { $0.prefix + $0.content } ?? line
        }
        for line in lines {
            let body = String(line.drop { $0 == "\t" || $0 == " " })
            if let open = fence {
                if let close = fenceRun(body), close.character == open.character, close.length >= open.length {
                    fence = nil
                }
                continue
            }
            if let open = fenceRun(body) {
                fence = open
                if body.count != line.count { nestedCode = true }
                continue
            }
            text.append(line)
        }
        let joined = text.joined(separator: "\n")
        let withoutCode = joined.replacingOccurrences(of: #"(`+)[^\n]*?\1"#, with: " ", options: .regularExpression)
        let unescaped = withoutCode.replacingOccurrences(of: #"\\[!-/:-@\[-`{-~]"#, with: " ", options: .regularExpression)
        let withoutTargets = unescaped.replacingOccurrences(of: #"\]\([^)\n]*\)"#, with: "] ", options: .regularExpression)
        let kinds: [(name: String, pattern: String, in: String)] = [
            ("コールアウト", #"<callout[\s>]"#, withoutTargets),
            ("トグル", #"<details[\s>]|\{[^}\n]*toggle="true""#, withoutTargets),
            ("表", #"<table[\s>]"#, withoutTargets),
            ("目次", #"<table_of_contents"#, withoutTargets),
            ("段組み", #"<columns[\s>]"#, withoutTargets),
            ("サブページ・データベース", #"<(page|database)[\s>]"#, withoutTargets),
            ("メンション", #"<mention-"#, withoutTargets),
            ("文字色・下線", #"<span[\s>]|\{[^}\n]*color=""#, withoutTargets),
            ("画像・ファイル", #"!\[[^\]\n]*\]\(|<(audio|video|file|pdf)[\s>]"#, unescaped),
            ("同期ブロック", #"<synced_block"#, withoutTargets),
            ("会議メモ", #"<meeting-notes"#, withoutTargets),
            ("引用元", #"\[\^"#, unescaped),
            ("数式", #"(?m)^\s*\$\$|\$[^$\n]+\$"#, withoutTargets),
            ("取得できなかったブロック", #"<unknown[\s/>]"#, withoutTargets),
            // A line break the app cannot keep inside a heading. (A "<br>" inside inline code stays
            // literal text on import, so it is not reported: the app itself exports such notes.)
            ("ブロック内の改行", #"(?m)^\t*#{1,6}[ \t][^\n]*<br"#, withoutTargets),
        ]
        var names = kinds.filter { $0.in.range(of: $0.pattern, options: .regularExpression) != nil }.map(\.name)
        // Columns that are not cards side by side come in one below the other.
        if converted.flattenedColumns, !names.contains("段組み") { names.append("段組み") }
        if nestedCode { names.append("入れ子のコードブロック") }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// Notion-flavored Markdown back to the app's Markdown (「Notion の内容を取り込む」). Reverses
    /// `export`: `<empty-block/>` becomes a blank line, and `<br>` a new line — inside a quote a new
    /// `>` line, inside a list item or to-do an indented line under it.
    ///
    /// Notion's backslash escapes are kept only where the app would otherwise read the character as
    /// syntax (MarkdownStyler decides), so a note that was exported comes back unchanged and `\*`,
    /// `\#` or `1\.` stay text; an `_` that the app would read as emphasis gets one, because Notion
    /// never writes emphasis with `_` (`__init__` stays `__init__`). Code, `$…$` and `$$` equations
    /// and link targets are copied verbatim (parentheses in a target are percent-encoded, which the
    /// app's links need); a link whose text is its URL becomes a bare URL when the app shows it as one.
    /// A code block nested under a list item comes back at the top level. Tags the app does not know
    /// (toggles, tables, …) are left as they are.
    ///
    /// A callout becomes a card — its color the card's, its own text the card's title — and columns that
    /// each hold one callout become a row of cards (other columns come in one below the other). A to-do
    /// in the color of a signal (blue: in progress, pink: waiting) becomes that signal.
    static func fromNotion(_ markdown: String) -> String {
        let styler = MarkdownStyler()
        var out: [String] = []
        var fence: (character: Character, length: Int, indentation: String)?
        var inEquation = false
        for converted in cardLines(markdown.components(separatedBy: "\n")).lines {
            let line: String
            switch converted {
            case .app(let text):
                out.append(text) // a line around a card, written as the app writes it
                continue
            case .notion(let text):
                line = text
            }
            let indentation = String(line.prefix { $0 == "\t" || $0 == " " })
            let body = String(line.dropFirst(indentation.count))
            if let open = fence {
                out.append(line.hasPrefix(open.indentation) ? String(line.dropFirst(open.indentation.count)) : line)
                if let close = fenceRun(body), close.character == open.character, close.length >= open.length,
                   body.dropFirst(close.length).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    fence = nil
                }
                continue
            }
            if let open = fenceRun(body) {
                fence = (open.character, open.length, indentation)
                out.append(body)
                continue
            }
            if body.trimmingCharacters(in: .whitespaces) == "$$" {
                inEquation.toggle()
                out.append(line)
                continue
            }
            if inEquation {
                out.append(appLine(indentation, "", body, styler: styler, literal: true, textOnly: true))
                continue
            }
            if body == emptyBlock {
                out.append("")
                continue
            }
            if body.hasPrefix(">") {
                let content = body.hasPrefix("> ") ? body.dropFirst(2) : body.dropFirst()
                // An empty part is ">" (it continues the quote above); only a quote that starts empty needs "> ".
                for (index, part) in lineBreaks(String(content)).enumerated() {
                    out.append(part.isEmpty ? indentation + (index == 0 ? "> " : ">") : appLine(indentation, "> ", part, styler: styler))
                }
                continue
            }
            var prefix = blockPrefix(of: body)
            var content = String(body.dropFirst(prefix.count))
            if let signal = signalToDo(prefix: prefix, content: content) { (prefix, content) = signal }
            let parts = lineBreaks(content)
            out.append(appLine(indentation, prefix, parts[0], styler: styler))
            let continuation = prefix.isEmpty || prefix.hasPrefix("#") ? indentation : indentation + "\t"
            out += parts.dropFirst().map { appLine(continuation, "", $0, styler: styler, textOnly: true) }
        }
        return out.joined(separator: "\n")
    }

    // MARK: Import: cards and signals

    /// A line of Notion's Markdown on its way into the app: still Notion's, or already the app's own.
    private enum ImportLine: Equatable {
        case notion(String)
        case app(String)
    }

    private static let calloutOpen = makeRegex(#"^<callout(?:\s[^>]*)?>\s*$"#)
    private static let colorAttribute = makeRegex(#"\scolor="([a-z_]+)""#)
    private static let unchecked = makeRegex(#"^[-*+][ \t]+\[ \][ \t]+$"#)
    private static let signalSuffix = makeRegex(#"(?:^|[ \t])\{color="(blue|pink)(?:_bg)?"\}[ \t]*$"#)

    /// An unchecked to-do in a signal's color, as that signal: "- [ ] 資料 {color="blue"}" is "- [/] 資料".
    private static func signalToDo(prefix: String, content: String) -> (prefix: String, content: String)? {
        let whole = NSRange(location: 0, length: (prefix as NSString).length)
        let ns = content as NSString
        guard unchecked.firstMatch(in: prefix, range: whole) != nil,
              let m = signalSuffix.firstMatch(in: content, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let state = ns.substring(with: m.range(at: 1)) == "blue" ? TaskState.doing : .waiting
        return (prefix.replacingOccurrences(of: "[ ]", with: "[\(state.rawValue)]"), ns.substring(to: m.range.location))
    }

    /// Turns callouts into cards and columns of callouts into rows of cards: their tags become the lines
    /// the app writes around a card and a row, and their children lose the indentation the tags gave
    /// them. Everything else is passed on as it is. `flattenedColumns`: some columns were not cards side
    /// by side (they hold other blocks, or more than one); what they hold comes one below the other.
    private static func cardLines(_ lines: [String]) -> (lines: [ImportLine], flattenedColumns: Bool) {
        var flattened = false
        func tabs(_ line: String) -> Int { line.prefix { $0 == "\t" }.count }
        func unindented(_ line: String) -> String { String(line.drop { $0 == "\t" || $0 == " " }) }
        func dedent(_ line: String, _ depth: Int) -> String { String(line.dropFirst(min(depth, tabs(line)))) }
        func isCalloutOpen(_ line: String) -> Bool {
            let body = unindented(line)
            return calloutOpen.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) != nil
        }
        /// The index of the line that closes the tag opened at `start` (`open` says what opens another one inside).
        func closing(_ tag: String, from start: Int, in lines: [String], open: (String) -> Bool) -> Int? {
            var depth = 0
            var fence: (character: Character, length: Int)?
            for index in (start + 1)..<lines.count {
                let body = unindented(lines[index])
                if let opened = fence {
                    if let run = fenceRun(body), run.character == opened.character, run.length >= opened.length { fence = nil }
                    continue
                }
                if let run = fenceRun(body) { fence = run; continue }
                if open(lines[index]) { depth += 1 } else if body == tag {
                    if depth == 0 { return index }
                    depth -= 1
                }
            }
            return nil
        }

        /// `depth`: the indentation the enclosing tags gave these lines. In a card nothing more is
        /// converted: cards do not nest.
        func convert(_ lines: [String], depth: Int, inCard: Bool) -> [ImportLine] {
            var out: [ImportLine] = []
            var fence: (character: Character, length: Int)?
            var index = 0
            while index < lines.count {
                let line = lines[index]
                let body = unindented(line)
                if let opened = fence {
                    if let run = fenceRun(body), run.character == opened.character, run.length >= opened.length { fence = nil }
                } else if let run = fenceRun(body) {
                    fence = run
                } else if !inCard, isCalloutOpen(line), let end = closing("</callout>", from: index, in: lines, open: isCalloutOpen) {
                    out += card(open: line, children: Array(lines[(index + 1)..<end]))
                    index = end + 1
                    continue
                } else if !inCard, body == "<columns>",
                          let end = closing("</columns>", from: index, in: lines, open: { unindented($0) == "<columns>" }) {
                    out += columns(Array(lines[(index + 1)..<end]), depth: tabs(line) + 1)
                    index = end + 1
                    continue
                }
                out.append(.notion(dedent(line, depth)))
                index += 1
            }
            return out
        }

        /// A callout as a card. Its own text — the first line in it — is the card's title if it is all
        /// bold, which is how the app sends a title; any other first line is the first line of the
        /// card's text, so a card without a title comes back as it was sent.
        func card(open: String, children: [String]) -> [ImportLine] {
            let depth = tabs(open) + 1
            let tag = unindented(open) as NSString
            var color = CardColor.default
            if let m = colorAttribute.firstMatch(in: tag as String, range: NSRange(location: 0, length: tag.length)) {
                let name = tag.substring(with: m.range(at: 1))
                color = CardColor(rawValue: name.hasSuffix("_bg") ? String(name.dropLast(3)) : name) ?? .default
            }
            var children = children
            var title = ""
            if let first = children.first, tabs(first) <= depth {
                let text = unindented(first)
                let isRichText = !text.isEmpty && blockPrefix(of: text).isEmpty && !text.hasPrefix("<") && !text.hasPrefix(">")
                    && fenceRun(text) == nil && text != "$$"
                if isRichText, text.count > 4, text.hasPrefix("**"), text.hasSuffix("**"),
                   !text.dropFirst(2).dropLast(2).contains("**") {
                    title = unescapeAll(String(text.dropFirst(2).dropLast(2)))
                    children.removeFirst()
                }
            }
            return [.app(CardSyntax.openLine(color: color, title: title))] + convert(children, depth: depth, inCard: true)
                + [.app(CardSyntax.closeMarker)]
        }

        /// Columns as a row of cards, if each of them holds one callout and nothing else.
        func columns(_ lines: [String], depth: Int) -> [ImportLine] {
            var cells: [[String]] = []
            var index = 0
            while index < lines.count {
                if unindented(lines[index]) == "<column>",
                   let end = closing("</column>", from: index, in: lines, open: { unindented($0) == "<column>" }) {
                    cells.append(Array(lines[(index + 1)..<end]))
                    index = end + 1
                } else {
                    index += 1
                }
            }
            let cards = cells.map { cell -> [ImportLine]? in
                guard let first = cell.first, isCalloutOpen(first),
                      closing("</callout>", from: 0, in: cell, open: isCalloutOpen) == cell.count - 1 else { return nil }
                return card(open: first, children: Array(cell.dropFirst().dropLast()))
            }
            if !cards.isEmpty, cards.allSatisfy({ $0 != nil }) {
                return [.app(CardSyntax.rowOpenMarker)] + cards.flatMap { $0 ?? [] } + [.app(CardSyntax.rowCloseMarker)]
            }
            flattened = true
            return cells.flatMap { convert($0, depth: depth + 1, inCard: false) }
        }

        let result = convert(lines, depth: 0, inCard: false)
        return (result, flattened)
    }

    private static let notionBlockPrefix = makeRegex(#"^(?:#{1,6}[ \t]+|[-*+][ \t]+\[[ xX]\][ \t]+|[-*+][ \t]+|\d{1,9}[.)][ \t]+)"#)
    private static let bareURLWhole = makeRegex("^" + MarkdownStyler.bareURLPattern + "$")

    /// Heading, list and to-do markers, which are never escaped.
    private static func blockPrefix(of line: String) -> String {
        guard let m = notionBlockPrefix.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        else { return "" }
        return (line as NSString).substring(with: m.range)
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

    private static func inlinePieces(_ content: String, styler: MarkdownStyler) -> [Piece] {
        let chars = Array(content)
        var pieces: [Piece] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, isASCIIPunctuation(chars[i + 1]) {
                pieces.append(.escaped(chars[i + 1]))
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
                let isBare = unescapeAll(link.label) == link.url && bareURLWhole.firstMatch(in: url, range: range) != nil
                // The label is rich text too; its brackets must stay escaped or the link would break.
                let label = appLine("", "", link.label, styler: styler, alwaysEscaped: ["[", "]"])
                pieces.append(.verbatim(isBare ? url : "[" + label + "](" + url + ")"))
                i = link.end
            } else {
                pieces.append(.character(c))
                i += 1
            }
        }
        return pieces
    }

    private static func isASCIIPunctuation(_ c: Character) -> Bool {
        c.isASCII && (c.isPunctuation || c.isSymbol)
    }

    private static func unescapeAll(_ text: String) -> String {
        var out = ""
        var escaping = false
        for c in text {
            if !escaping, c == "\\" { escaping = true; continue }
            if escaping, !isASCIIPunctuation(c) { out.append("\\") }
            escaping = false
            out.append(c)
        }
        return out
    }

    private static func fenceRun(_ line: String) -> (character: Character, length: Int)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let length = line.prefix { $0 == first }.count
        return length >= 3 ? (first, length) : nil
    }

    /// Splits at `<br>` (and `<br/>`, `<br />`), but not inside inline code.
    private static func lineBreaks(_ text: String) -> [String] {
        let chars = Array(text)
        var parts = [""]
        var i = 0
        while i < chars.count {
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
