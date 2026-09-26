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
    private static let quotePrefix = makeRegex(#"^ {0,3}(?:>[ \t]?)+"#)
    private static let taskPrefix = makeRegex(#"^([ \t]*)(?:[-*+]|\d{1,9}[.)])[ \t]+\[([ xX])\](?:[ \t]+|$)"#)
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
                lines.append(raw) // literal, never escaped
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
            }
        }

        /// Fences are always top level (an indented fence would become a child block in Notion) and
        /// always backtick fences, the only kind the format documents.
        private mutating func fence(_ raw: String, next: Int) {
            let text = String(raw.drop { $0 == " " || $0 == "\t" }).trimmingTrailingWhitespace
            if let fence = openFence {
                lines.append(fence) // the closing fence matches the one written for the opening
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
            if let firstLine { lines.append(firstLine) }
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
            var indentation = NSRange(location: range.location, length: 0)
            var content = range
            if kind == .task, let m = NotionMarkdown.taskPrefix.firstMatch(in: text, range: range) {
                indentation = m.range(at: 1)
                marker = ns.substring(with: m.range(at: 2)) == " " ? "- [ ] " : "- [x] "
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
            emit(marker + NotionMarkdown.escapingBlockStart(inline(content)), depth: depth)
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

        /// Appends a block at `depth`, after the blank lines waiting before it (at the same depth, so
        /// that they and the block share a parent).
        private mutating func emit(_ block: String, depth: Int) {
            let indentation = String(repeating: "\t", count: depth)
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
                } else if isMarker || storage.attribute(.mdCode, at: i, effectiveRange: nil) != nil {
                    out += string
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
    /// back. Code blocks are ignored.
    static func notionOnlyElements(in markdown: String) -> [String] {
        let kinds: [(name: String, pattern: String)] = [
            ("コールアウト", #"<callout[\s>]"#),
            ("トグル", #"<details[\s>]|\{[^}\n]*toggle="true""#),
            ("表", #"<table[\s>]"#),
            ("目次", #"<table_of_contents"#),
            ("段組み", #"<columns[\s>]"#),
            ("サブページ・データベース", #"<(page|database)[\s>]"#),
            ("メンション", #"<mention-"#),
            ("文字色・下線", #"<span[\s>]|\{[^}\n]*color=""#),
            ("画像・ファイル", #"!\[[^\]\n]*\]\(|<(audio|video|file|pdf)[\s>]"#),
            ("同期ブロック", #"<synced_block"#),
            ("数式", #"(?m)^\s*\$\$|(?<!\\)\$[^$\n]+(?<!\\)\$"#),
            ("取得できなかったブロック", #"<unknown[\s/>]"#),
        ]
        var fence: (character: Character, length: Int)?
        var text: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            let body = String(line.drop { $0 == "\t" || $0 == " " })
            if let open = fence {
                if let close = fenceRun(body), close.character == open.character, close.length >= open.length {
                    fence = nil
                }
                continue
            }
            if let open = fenceRun(body) {
                fence = open
                continue
            }
            text.append(line)
        }
        let joined = text.joined(separator: "\n")
        return kinds.filter { joined.range(of: $0.pattern, options: [.regularExpression]) != nil }.map(\.name)
    }

    /// Notion-flavored Markdown back to the app's Markdown (for restoring from Notion). Reverses
    /// `export`: `<empty-block/>` becomes a blank line, `<br>` a new line (inside a quote, a new `>`
    /// line), escapes are removed outside code, and links whose text is their URL become bare URLs
    /// again. Tabs are kept; tags the app does not know (callouts, toggles, …) are left as they are.
    static func fromNotion(_ markdown: String) -> String {
        var out: [String] = []
        var fence: (character: Character, length: Int)?
        for line in markdown.components(separatedBy: "\n") {
            let indentation = String(line.prefix { $0 == "\t" || $0 == " " })
            let body = String(line.dropFirst(indentation.count))
            if let open = fence {
                out.append(line)
                if let close = fenceRun(body), close.character == open.character, close.length >= open.length,
                   body.dropFirst(close.length).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    fence = nil
                }
                continue
            }
            if let open = fenceRun(body) {
                fence = open
                out.append(line)
                continue
            }
            if body == emptyBlock {
                out.append("")
                continue
            }
            if body.hasPrefix(">") {
                let content = body.hasPrefix("> ") ? body.dropFirst(2) : body.dropFirst()
                for part in lineBreaks(String(content)) {
                    out.append(indentation + (part.isEmpty ? ">" : "> " + unescape(part)))
                }
                continue
            }
            let prefix = blockPrefix(of: body)
            let parts = lineBreaks(String(body.dropFirst(prefix.count)))
            out.append(indentation + prefix + unescape(parts[0]))
            out += parts.dropFirst().map { indentation + unescape($0) }
        }
        return out.joined(separator: "\n")
    }

    private static let notionBlockPrefix = makeRegex(#"^(?:#{1,6}[ \t]+|[-*+][ \t]+\[[ xX]\][ \t]+|[-*+][ \t]+|\d{1,9}[.)][ \t]+)"#)

    /// Heading, list and to-do markers, which are never escaped.
    private static func blockPrefix(of line: String) -> String {
        guard let m = notionBlockPrefix.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        else { return "" }
        return (line as NSString).substring(with: m.range)
    }

    private static func fenceRun(_ line: String) -> (character: Character, length: Int)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let length = line.prefix { $0 == first }.count
        return length >= 3 ? (first, length) : nil
    }

    private static func lineBreaks(_ text: String) -> [String] {
        text.replacingOccurrences(of: "<br />", with: "<br>")
            .replacingOccurrences(of: "<br/>", with: "<br>")
            .components(separatedBy: "<br>")
    }

    /// Removes backslash escapes (before any ASCII punctuation, as in CommonMark: the export also
    /// escapes block syntax such as `\#`), except inside code spans and link URLs.
    private static func unescape(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1].isASCII, chars[i + 1].isPunctuation || chars[i + 1].isSymbol {
                out.append(chars[i + 1])
                i += 2
            } else if c == "`" {
                let run = chars[i...].prefix { $0 == "`" }.count
                if let close = closingBackticks(chars, from: i + run, length: run) {
                    out += String(chars[i..<(close + run)])
                    i = close + run
                } else {
                    out += String(repeating: "`", count: run)
                    i += run
                }
            } else if c == "[", let link = link(chars, at: i) {
                let label = unescape(link.label)
                let isBare = label == link.url && (link.url.hasPrefix("https://") || link.url.hasPrefix("http://"))
                out += isBare ? link.url : "[" + label + "](" + link.url + ")"
                i = link.end
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
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

    /// `[label](url)` starting at `start`: the raw (still escaped) label, the URL and the index after ")".
    private static func link(_ chars: [Character], at start: Int) -> (label: String, url: String, end: Int)? {
        var i = start + 1
        while i < chars.count, chars[i] != "]" {
            i += chars[i] == "\\" ? 2 : 1
        }
        guard i + 1 < chars.count, chars[i] == "]", chars[i + 1] == "(" else { return nil }
        let label = String(chars[(start + 1)..<i])
        var j = i + 2
        while j < chars.count, chars[j] != ")" {
            if chars[j] == "(" || chars[j].isWhitespace { return nil }
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
