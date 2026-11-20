import AppKit
import Testing
@testable import FusenCore

/// Notes put together without a plan from the lines a note can have: every kind of block at every
/// indentation, text full of characters that are syntax somewhere, cards and rows that are closed or
/// not. For the tests that must hold for any note. A failure can be repeated from its seed.
struct RandomNote {
    private var state: UInt64

    init(seed: Int) { state = UInt64(seed) &* 2654435761 &+ 12345 }

    private mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(max(bound, 1)))
    }

    private static let texts = [
        "本文", "価格は $5 | a", "**太字** と *斜体*", "~~消す~~ `code`", "x_y と _z_", "<tag> & &amp;", "# 見出し風", "- 項目風", "1. 番号風",
        "> 引用風", "https://example.com/a_b", "[リンク](https://a.b)", "a\\*b \\_c", "---", "", "{color=\"blue\"}", "<p />", "a<br />b",
        "**「強調」**です", "```", "| a | b |", "$x$ と $$", "!", "*", "_", "\\", "[x](note.md)", "***x***", "__init__", "&#35;", "--", "+ x",
        "2) 番号風", "=", "#", ">", "<b>x</b>", "</todo>", "[ ] x", "~~~", "a  b", "末尾\\",
    ]
    private static let prefixes = ["", "", "", "- ", "- ", "* ", "1. ", "2. ", "10. ", "- [ ] ", "- [x] ", "- [/] ", "- [>] ", "> ", "> ", "# ", "## ", "#### "]

    /// `plain`: only what Markdown itself can say — no cards, and no signals (they are tags in Notion).
    mutating func note(plain: Bool = false) -> String {
        var lines: [String] = []
        var inCard = false, inRow = false, inCode = false
        for _ in 0..<(3 + next(14)) {
            switch next(24) {
            case 0 where !plain && !inCard && !inCode:
                if !inRow, next(3) == 0 {
                    lines.append("::::columns")
                    inRow = true
                }
                lines.append(":::card " + ["orange", "blue", "", "default", "red 名前", "purple a*b <c>"][next(6)] + ["", " タイトル", " "][next(3)])
                inCard = true
            case 1 where inCard && !inCode:
                lines.append(":::")
                inCard = false
                if inRow, next(2) == 0 {
                    lines.append("::::")
                    inRow = false
                }
            case 2:
                lines.append(inCode ? "```" : ["```", "```swift", "~~~", "````"][next(4)])
                inCode.toggle()
            case 3:
                lines.append("")
            case 4:
                lines.append("---")
            default:
                if inRow, !inCard {
                    lines.append("::::")
                    inRow = false
                }
                let indentation = String(repeating: "\t", count: [0, 0, 0, 1, 1, 2, 3][next(7)])
                var prefix = Self.prefixes[next(Self.prefixes.count)]
                if plain, prefix.hasPrefix("- [/") || prefix.hasPrefix("- [>") { prefix = "- [ ] " }
                lines.append(indentation + prefix + Self.texts[next(Self.texts.count)])
            }
        }
        if inCode, next(2) == 0 { lines.append("```") }
        if inCard, next(4) != 0 { lines.append(":::") }
        if inRow, next(4) != 0 { lines.append("::::") }
        return lines.joined(separator: "\n")
    }
}

/// Notion-flavored Markdown is CommonMark (with GFM's tables, task lists and strikethrough) plus
/// Notion's tags. No test talks to Notion, but the CommonMark part can be checked against a real
/// parser: Foundation's `AttributedString(markdown:)`, which is cmark-gfm. These tests read what the
/// app exports with it and compare the blocks it finds — their kind, their nesting, their text — with
/// what the note shows.
///
/// What this cannot check is everything that is a tag: to Foundation's parser `<todo>`, `<callout>`
/// or `<p>` are HTML it does not understand. So the notes here have no cards, no signals and no
/// children other than list items under list items. (An empty list item is not compared either: the
/// parser reports no text for it.) `<b>`, `<i>` and `<s>` are skipped as the formatting they are, and
/// `<p />` and `<br />` are read as the empty paragraph and the line break Notion documents.
@MainActor
struct NotionCommonMarkTests {
    let styler = MarkdownStyler()

    struct Block: Equatable, CustomStringConvertible {
        var kind: String
        var depth = 0
        var text = ""

        var description: String { "\(String(repeating: "  ", count: depth))\(kind): \(text.debugDescription)" }
    }

    /// The blocks the note shows: one per line (the lines of a quote and of a code block are one block),
    /// with the text that is visible when the Markdown is concealed.
    private func shown(_ note: String) -> [Block] {
        let storage = NSTextStorage(string: note)
        styler.restyle(storage)
        let ns = note as NSString
        var blocks: [Block] = []
        var blank = 0
        var inCode = false
        var location = 0
        while location < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            let raw = ns.substring(with: paragraph).trimmingCharacters(in: .newlines)
            let kind = (storage.attribute(.mdLine, at: paragraph.location, effectiveRange: nil) as? String).flatMap(MarkdownLine.init) ?? .text
            var visible = ""
            for i in paragraph.location..<NSMaxRange(paragraph) where storage.attribute(.mdMarker, at: i, effectiveRange: nil) == nil {
                visible += ns.substring(with: NSRange(location: i, length: 1))
            }
            visible = visible.trimmingCharacters(in: .whitespacesAndNewlines)
            if kind == .text, visible.isEmpty {
                blank += 1 // written before the next block; dropped at the end of the note
                continue
            }
            if kind != .code, !(kind == .fence && inCode) {
                blocks += Array(repeating: Block(kind: "empty"), count: blank)
                blank = 0
            }
            let depth = raw.prefix { $0 == "\t" }.count
            switch kind {
            case .fence:
                if inCode {
                    inCode = false
                } else {
                    inCode = true
                    let fence = raw.trimmingCharacters(in: .whitespaces)
                    blocks.append(Block(kind: "code:" + fence.drop { $0 == "`" || $0 == "~" }.trimmingCharacters(in: .whitespaces)))
                }
            case .code:
                blocks[blocks.count - 1].text += raw + "\n"
            case .quote:
                if blocks.last?.kind == "quote", blank == 0, location > 0, wasQuote(storage, before: paragraph.location) {
                    blocks[blocks.count - 1].text += "\n" + visible
                } else {
                    blocks.append(Block(kind: "quote", text: visible))
                }
            case .h1, .h2, .h3, .h4:
                blocks.append(Block(kind: "heading\(kind.headingLevel ?? 0)", text: visible))
            case .rule:
                blocks.append(Block(kind: "divider"))
            case .bullet:
                blocks.append(Block(kind: "bullet", depth: depth, text: visible))
            case .ordered:
                blocks.append(Block(kind: "ordered", depth: depth, text: visible))
            case .task:
                let checked = raw.range(of: #"\[[xX]\]"#, options: .regularExpression) != nil
                blocks.append(Block(kind: checked ? "todo[x]" : "todo[ ]", depth: depth, text: visible))
            default:
                blocks.append(Block(kind: "paragraph", depth: depth, text: visible))
            }
        }
        return blocks
    }

    private func wasQuote(_ storage: NSTextStorage, before location: Int) -> Bool {
        guard location > 0 else { return false }
        return storage.attribute(.mdLine, at: location - 1, effectiveRange: nil) as? String == MarkdownLine.quote.rawValue
    }

    /// The blocks a CommonMark parser finds in `markdown`.
    private func parsed(_ markdown: String) throws -> [Block] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        let attributed = try AttributedString(markdown: markdown, options: options)
        var blocks: [Block] = []
        var current: Int?
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            let inline = run.inlinePresentationIntent ?? []
            guard let intent = run.presentationIntent, let innermost = intent.components.first else {
                // Not in a block: HTML on lines of its own (the parser gives those that follow each other
                // as one run). The only such line the export writes outside a tag is the empty paragraph.
                current = nil
                for line in text.split(separator: "\n") {
                    blocks.append(line == NotionMarkdown.emptyParagraph ? Block(kind: "empty") : Block(kind: "html", text: String(line)))
                }
                continue
            }
            if current != innermost.identity {
                current = innermost.identity
                var block = Block(kind: "paragraph")
                let items = intent.components.filter { if case .listItem = $0.kind { true } else { false } }
                // The list the block's own item is in: the first list after that item.
                let list = intent.components.first { component in
                    switch component.kind {
                    case .orderedList, .unorderedList: true
                    default: false
                    }
                }
                switch innermost.kind {
                case .header(let level): block.kind = "heading\(level)"
                case .codeBlock(let language): block.kind = "code:" + (language ?? "")
                case .thematicBreak: block.kind = "divider"
                default:
                    if intent.components.contains(where: { $0.kind == .blockQuote }) {
                        block.kind = "quote"
                    } else if let list {
                        block.kind = list.kind == .orderedList ? "ordered" : "bullet"
                        block.depth = items.count - 1
                    }
                }
                blocks.append(block)
            }
            if blocks[blocks.count - 1].kind == "divider" { continue }
            if inline.contains(.inlineHTML) {
                // A line break is the only tag that is text; the others are formatting around text.
                // (Tags that follow each other come as one run.)
                let breaks = text.components(separatedBy: NotionMarkdown.lineBreak).count - 1
                blocks[blocks.count - 1].text += String(repeating: "\n", count: breaks)
            } else if inline.contains(.softBreak) {
                blocks[blocks.count - 1].text += "⏎" // two lines read as one block: never what the export means
            } else if inline.contains(.lineBreak) {
                blocks[blocks.count - 1].text += "\n"
            } else {
                blocks[blocks.count - 1].text += text
            }
        }
        // A task list item is a list item whose text starts with a checkbox.
        return blocks.map { block in
            var block = block
            if block.kind == "bullet" || block.kind == "ordered" {
                for (box, kind) in [("[ ]", "todo[ ]"), ("[x]", "todo[x]")] where block.text == box || block.text.hasPrefix(box + " ") {
                    block.kind = kind
                    block.text = String(block.text.dropFirst(box.count + 1))
                }
            }
            return block
        }
    }

    /// Blocks without text (an empty list item, quote, heading or code block): the parser reports
    /// nothing for them, so they are left out on both sides.
    private func withText(_ blocks: [Block]) -> [Block] {
        blocks.filter { !$0.text.isEmpty || $0.kind == "empty" || $0.kind == "divider" }
    }

    private func expectSameBlocks(_ note: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let exported = NotionMarkdown.export(note, styler: styler)
        let found = withText(try parsed(exported))
        let expected = withText(shown(note))
        #expect(found == expected, """
        note:
        \(note)
        exported:
        \(exported)
        a CommonMark parser reads:
        \(found.map(\.description).joined(separator: "\n"))
        the note shows:
        \(expected.map(\.description).joined(separator: "\n"))
        """, sourceLocation: sourceLocation)
    }

    @Test func paragraphsHeadingsAndBlankLines() throws {
        try expectSameBlocks("一行目\n二行目\n\n空行のあと\n\n\n二つの空行のあと")
        try expectSameBlocks("# 見出し1\n## 見出し2\n### 見出し3\n#### 見出し4\n##### 見出し5\n本文\n# **太字** の見出し\n## 課題 #\n# #\n# C# の話")
        try expectSameBlocks("\n\n空行から始まるメモ")
    }

    @Test func textThatLooksLikeSyntaxIsReadAsText() throws {
        try expectSameBlocks("価格は $5、{a} | b <c> ^d ~e ~~f [g] \\h &amp; A&B &#35; &copy; x_y _ z _ a_ _b a > b #タグ 1.5 倍 -1 `code`")
        try expectSameBlocks("2 * 3 * 4 と **not** bold ではない \\*\\*これ\\*\\* と snake_case_name と __init__.py と \\_\\_init\\_\\_")
        // (An indented line after a divider: after a paragraph it would be that paragraph's child, a tag.)
        try expectSameBlocks("---\n    # 見出しではない\n---\n    ---\n---\n    ___\n---\n    > 引用ではない\n---\n    1) 字下げした番号付き")
        try expectSameBlocks("***\n_ _ _\n+ - 0\n=\n==\n1.5\n2.\n3)\n#\n-\n+\n>\n>x\n|\n| a | b |\n| --- | --- |\n| 1 | 2 |\n$$\nE = mc^2\n$$")
        try expectSameBlocks("<callout>中身</callout>\n<p />\n<b>太字</b> と a<br />b\n</todo>\n<!-- comment -->\n<https://example.com>\n[x]: https://example.com\n![logo](https://example.com/a.png)")
        try expectSameBlocks("C:\\Users\\name\\\n行末のバックスラッシュ\\\n次の行\n末尾の空白  \n次の行")
    }

    @Test func formattingIsOnlyAroundTheText() throws {
        try expectSameBlocks("**太字** と *斜体* と ~~取り消し~~ と ***両方*** と __太字__ と _斜体_ と `code` と **a *b* c**")
        try expectSameBlocks("**「強調」**です と **重要！**です と これは**（注）**です と **a *b** c* と snake__case__name")
        // (Not a bold link: Foundation's parser gives a tag inside a link's text as text.)
        try expectSameBlocks("[Apple](https://www.apple.com) と https://example.com/a_b を参照 と **[太字](https://a.b)の外** と 見て!https://example.com")
    }

    @Test func listsAndTheirNesting() throws {
        try expectSameBlocks("- a\n* b\n+ c\n1. 一\n2) 二\n10. 十\n- [ ] やること\n- [x] 完了\n* [X] 大文字\n- d")
        try expectSameBlocks("- 親\n\t- 子\n\t\t- 孫\n\t\t\t- ひ孫\n\t- 子2\n- 次\n\t1. 番号の子\n\t2. 番号の子2\n\t\t- [ ] タスクの孫\n\t- 箇条書きの子")
        try expectSameBlocks("1. 手順\n\t- [ ] 確認\n\t\t1. 孫\n2. 次\n10. 十\n\t- 十の子\n\t\t- 十の孫\n100. 百\n\t1. 百の子")
        // Children that Markdown would read as more of the parent's text, were they right under it.
        try expectSameBlocks("- 親\n\t2. 二から始まる子\n\t3. 次\n- 親\n\t5. 五\n1. 親\n\t7. 七\n\t\t9. 九")
        // Lists of different kinds that follow each other, at every depth.
        try expectSameBlocks("- a\n1. b\n- c\n\t1. d\n\t- e\n\t2. f\n3. g\n- [ ] h\n4. i")
    }

    @Test func blockSyntaxInsideABlockIsReadAsText() throws {
        try expectSameBlocks("- # foo\n- - foo\n- + foo\n1. - foo\n- 1. foo\n- 2) foo\n- [ ] # 見出し風\n- > 引用風\n* --\n* - -\n- ---x\n- 1.5 倍\n- ```\n- | a |")
        try expectSameBlocks("> # 引用内の見出し風\n\n> >x\n\n> >>> print(1)\n\n>     字下げした引用\n\n> ---\n\n> 1.5 倍")
    }

    @Test func quotes() throws {
        try expectSameBlocks("> 一行目\n> 二行目\n>\n> 四行目\n\n> 引用B\n本文\n> **強調** と a > b\n本文")
        try expectSameBlocks("- 項目\n> 引用\n- 項目\n# 見出し\n> 引用\n---\n> 引用")
    }

    @Test func codeBlocks() throws {
        try expectSameBlocks("```swift\nlet a = [1, 2] // $x {y} | <z> **b** &amp;\n\nprint(\"\\(a)\")\n```\n後")
        try expectSameBlocks("~~~\n$x$ <b>\n~~~\n~~~swift\nlet a = 1\n~~~\n~~~\n```\n~~~\n```\nlet s = \"```` と ``\"\n```\n````\n```\n````")
        try expectSameBlocks("本文\n```\n- 箇条書きではない\n# 見出しではない\n</callout>\n```\n- 項目\n```js\nconst a = 1")
        try expectSameBlocks("  ```\n  インデント\n  ```")
    }

    @Test func blocksWithoutTextDoNotChangeTheirNeighbours() throws {
        // (Right under "親", an empty item would be read as the line that makes "親" a heading.)
        try expectSameBlocks("- 親\n\t- \n\t- 子\n- \n- 最後\n1. \n2. 二\n\t1. \n- [ ] \n- [x] 済み\n\t- [ ] \n本文")
        try expectSameBlocks("本文\n> \n本文\n# \n本文\n- \n本文\n1. \n本文\n- [ ] \n本文\n---\n- ")
    }

    @Test func dividers() throws {
        try expectSameBlocks("上\n---\n- - -\n下\n---\n---\n# 見出し\n---\n- 項目\n---")
    }

    /// Any note that the export writes without tags: what a CommonMark parser reads in it is what the
    /// note shows. (Read from the note as it comes back from Notion's Markdown: there every block is
    /// indented by as many tabs as it is nested. Lines the helper cannot describe are left out: a link
    /// that is sent as text, a marker inside a quote, which the app draws.)
    @Test func randomNotesWithoutTags() throws {
        var compared = 0
        for seed in 0..<Self.randomNotes {
            var random = RandomNote(seed: seed)
            let note = NotionMarkdown.fromNotion(NotionMarkdown.export(random.note(plain: true), styler: styler))
            let exported = NotionMarkdown.export(note, styler: styler)
            let tags = exported.components(separatedBy: "\n").filter { $0.hasPrefix("<") && $0 != NotionMarkdown.emptyParagraph && !$0.hasPrefix("<b>") && !$0.hasPrefix("<i>") && !$0.hasPrefix("<s>") }
            guard tags.isEmpty, !note.contains("(note.md)"), note.range(of: #"(?m)^> ([-*+]|\d+[.)])( |$)"#, options: .regularExpression) == nil
            else { continue }
            compared += 1
            let found = withText(try parsed(exported)), expected = withText(shown(note))
            #expect(found == expected, """
            seed \(seed), note:
            \(note)
            exported:
            \(exported)
            a CommonMark parser reads:
            \(found.map(\.description).joined(separator: "\n"))
            the note shows:
            \(expected.map(\.description).joined(separator: "\n"))
            """)
        }
        #expect(compared > Self.randomNotes / 10) // enough notes were of the kind that can be compared
    }

    /// (Kept short, as these tests run on the main actor. More seeds are worth a run after a change.)
    private static let randomNotes = 100

    /// Why bold is written as a tag: with "**", CommonMark's rules about what may stand next to a
    /// delimiter leave the bold of everyday Japanese unread (the app reads it as bold).
    @Test func delimitersWouldNotBeReadWhereTagsAre() throws {
        let note = "**「強調」**です"
        let storage = NSTextStorage(string: note)
        styler.restyle(storage)
        let font = storage.attribute(.font, at: (note as NSString).range(of: "強調").location, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true) // bold in the app
        let asWritten = try AttributedString(markdown: note, options: .init(interpretedSyntax: .full))
        #expect(!asWritten.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }) // not in CommonMark
        #expect(NotionMarkdown.export(note, styler: styler) == "<b>「強調」</b>です")
    }
}
