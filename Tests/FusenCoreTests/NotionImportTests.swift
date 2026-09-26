import AppKit
import Testing
@testable import FusenCore

/// Importing from Notion (NotionMarkdown.fromNotion) must show exactly what Notion shows, and a note the
/// app exported must come back unchanged.
@MainActor
struct NotionImportTests {
    let styler = MarkdownStyler()

    private func export(_ text: String) -> String { NotionMarkdown.export(text, styler: styler) }
    private func fromNotion(_ markdown: String) -> String { NotionMarkdown.fromNotion(markdown) }

    /// The text the app shows for `text` with all Markdown syntax concealed.
    private func shown(_ text: String) -> String {
        let storage = NSTextStorage(string: text)
        styler.restyle(storage)
        var out = ""
        let ns = storage.string as NSString
        for i in 0..<ns.length where storage.attribute(.mdMarker, at: i, effectiveRange: nil) == nil {
            out += ns.substring(with: NSRange(location: i, length: 1))
        }
        return out
    }

    private func isStyled(_ text: String, _ key: NSAttributedString.Key, at sub: String) -> Bool {
        let storage = NSTextStorage(string: text)
        styler.restyle(storage)
        let r = (text as NSString).range(of: sub)
        return storage.attribute(key, at: r.location, effectiveRange: nil) != nil
    }

    @Test func notesTheAppExportedComeBackUnchanged() {
        for note in [
            "価格は$5 と a | b と {x} と <tag> と ^",
            "**太字** と *斜体* と ~~消す~~ と `code *x*`",
            "# 見出し\n- [ ] タスク\n- [x] 済み\n\t- 子\n1. 番号",
            "> 引用\n> 二行目",
            "snake_case と 2 * 3 と C:\\Users\\name",
            "[リンク](https://example.com) と https://example.com/path",
            "本文\n\n空行のあと",
        ] {
            #expect(fromNotion(export(note)) == note, "\(note)")
        }
    }

    @Test func notionEscapesStayTextInTheApp() {
        // Each: Notion markdown → what Notion shows, which the sticky must show too.
        let cases: [(String, String)] = [
            (#"2\*3\*4 = 24"#, "2*3*4 = 24"),
            (#"\*\*not bold\*\*"#, "**not bold**"),
            (#"\~\~x\~\~ と \`x\`"#, "~~x~~ と `x`"),
            (#"\[x\](https://example.com)"#, "[x](https://example.com)"),
            (##"\# 見出しではない"##, "# 見出しではない"),
            (#"\> 引用ではない"#, "> 引用ではない"),
            (#"\- 箇条書きではない"#, "- 箇条書きではない"),
            (#"1\. 番号ではない"#, "1. 番号ではない"),
            (#"\---"#, "---"),
            (#"- \[ \] チェックボックスではない"#, "[ ] チェックボックスではない"),
        ]
        for (markdown, visible) in cases {
            let text = fromNotion(markdown)
            #expect(shown(text).hasSuffix(visible), "\(markdown) → \(text) shows \(shown(text))")
            // (A bare URL is sent as a link, so that case only has to look the same.)
            if !markdown.contains("https://") {
                #expect(export(text) == markdown, "\(markdown) round trip: \(export(text))")
            }
        }
        // Block syntax stays text.
        #expect(!isStyled(fromNotion(##"\# x"##), .font, at: "x") || shown(fromNotion(##"\# x"##)) == "# x")
        #expect(fromNotion(##"\# 見出しではない"##) == ##"\# 見出しではない"##)
    }

    @Test func underscoresNotionNeverEscapesStayLiteral() {
        let text = fromNotion("def __init__(self): と if __name__ == \"__main__\": と snake_case_name")
        #expect(shown(text) == "def __init__(self): と if __name__ == \"__main__\": と snake_case_name")
        #expect(!isStyled(text, .mdMarker, at: "init"))
        #expect(text.contains("snake_case_name")) // intraword underscores need no escape
    }

    @Test func lineBreaksInsideCodeAreText() {
        #expect(fromNotion("HTML の改行は `<br>` を使う") == "HTML の改行は `<br>` を使う")
        #expect(fromNotion("> 引用の `<br/>` タグ") == "> 引用の `<br/>` タグ")
    }

    @Test func lineBreaksInListItemsStayInTheItem() {
        #expect(fromNotion("- 項目<br>続き") == "- 項目\n\t続き")
        #expect(fromNotion("- [ ] タスク<br>メモ") == "- [ ] タスク\n\tメモ")
        #expect(fromNotion("\t- 子<br>続き") == "\t- 子\n\t\t続き")
        #expect(fromNotion("段落<br>次の行") == "段落\n次の行")
        #expect(NotionMarkdown.notionOnlyElements(in: "# 見出し<br>続き") == ["ブロック内の改行"])
    }

    @Test func nestedCodeBlocksComeBackAtTheTop() {
        let markdown = "- 項目\n\t```swift\n\tlet x = 1\n\t\tindented()\n\t```"
        #expect(fromNotion(markdown) == "- 項目\n```swift\nlet x = 1\n\tindented()\n```")
        #expect(NotionMarkdown.notionOnlyElements(in: markdown) == ["入れ子のコードブロック"])
    }

    @Test func linkTargetsSurvive() {
        let wiki = "https://en.wikipedia.org/wiki/Swift_(language)"
        let encoded = "https://en.wikipedia.org/wiki/Swift_%28language%29"
        #expect(fromNotion("[\(wiki)](\(wiki))") == encoded)
        #expect(fromNotion("[Swift](\(wiki))") == "[Swift](\(encoded))")
        #expect(isStyled(fromNotion("[Swift](\(wiki))"), .mdLink, at: "Swift"))
        let japanese = "https://ja.wikipedia.org/wiki/日本"
        #expect(fromNotion("[\(japanese)](\(japanese))") == "[\(japanese)](\(japanese))")
        #expect(fromNotion("[ラベル\\*](https://a.b)") == "[ラベル*](https://a.b)")
    }

    /// What Notion shows for plain-text Markdown: its backslash escapes removed.
    private func notionShown(_ markdown: String) -> String {
        var out = ""
        var escaping = false
        for c in markdown {
            if !escaping, c == "\\" { escaping = true; continue }
            if escaping, !(c.isASCII && (c.isPunctuation || c.isSymbol)) { out.append("\\") }
            escaping = false
            out.append(c)
        }
        return out
    }

    @Test func equationsKeepTheirSource() {
        // The app shows an equation as its source text, and sends that text back unchanged in meaning.
        for (markdown, source) in [
            ("$x \\in \\{1,2\\}$ です", "$x \\in \\{1,2\\}$ です"),
            ("速さ $v = \\frac{d}{t} \\, [m/s]$ です", "速さ $v = \\frac{d}{t} \\, [m/s]$ です"),
            ("$a*b*c$", "$a*b*c$"),
            ("$$\n\\frac{a}{b} \\\\ c_{1} \\, \\{x\\} 50\\%\n$$", "$$\n\\frac{a}{b} \\\\ c_{1} \\, \\{x\\} 50\\%\n$$"),
        ] {
            let text = fromNotion(markdown)
            #expect(shown(text) == source, "\(markdown) shows \(shown(text))")
            #expect(notionShown(export(text)) == source, "\(markdown) exported \(export(text))")
        }
    }

    @Test func blockSyntaxAfterALineBreakStaysText() {
        #expect(fromNotion("段落<br># 見出し") == "段落\n\\# 見出し")
        #expect(fromNotion("段落<br>---") == "段落\n\\---")
        #expect(fromNotion("段落<br>- x") == "段落\n\\- x")
        #expect(fromNotion("- 項目<br>- 続き") == "- 項目\n\t\\- 続き")
        #expect(fromNotion("- 項目<br>1. 続き") == "- 項目\n\t1\\. 続き")
    }

    @Test func escapesInsideLinkLabelsKeepTheLink() {
        for markdown in ["[\\_\\_init\\_\\_.py](https://github.com/a/b)", "[\\*\\*重要\\*\\*](https://a.b)", "[a\\[b](https://a.b)"] {
            let text = fromNotion(markdown)
            let label = text.dropFirst().prefix { $0 != "]" }
            #expect(isStyled(text, .mdLink, at: String(label.suffix(2))), "\(markdown) → \(text)")
            #expect(notionShown(export(text)) == notionShown(markdown), "\(markdown) → \(export(text))")
        }
        #expect(fromNotion("[__init__.py](https://github.com/a/b)") == "[\\_\\_init\\_\\_.py](https://github.com/a/b)")
    }

    @Test func backslashesTypedInNotesStayAsTyped() {
        for note in [#"\{x\} 50\%"#, #"{\"k\":\"v\"}"#, #"regex \d+ と \w"#, #"C:\Users\name\"#] {
            #expect(shown(note) == note, "\(note) shows \(shown(note))")
            #expect(fromNotion(export(note)) == note, "\(note)")
        }
    }

    @Test func anEscapedBacktickDoesNotHideALaterCodeSpan() {
        let text = fromNotion("バッククォート（\\`）で囲むと `code` になります")
        #expect(isStyled(text, .mdCode, at: "code"))
        #expect(export(text) == "バッククォート（\\`）で囲むと `code` になります")
    }

    @Test func emphasisRightAfterAnEscapedBackslash() {
        let markdown = "\\\\*重要*"          // a literal backslash, then 重要 in italics
        let text = fromNotion(markdown)
        #expect(isStyled(text, .obliqueness, at: "重要"))
        #expect(export(text) == markdown)
    }

    @Test func lineBreaksInsideCodeAreNotReported() {
        #expect(NotionMarkdown.notionOnlyElements(in: "HTML の改行は `<br>` を使う").isEmpty)
    }

    @Test func manyEscapesStayFast() {
        let line = String(repeating: "\\*", count: 5000)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let storage = NSTextStorage(string: line)
            styler.restyle(storage)
        }
        #expect(elapsed < .milliseconds(500), "\(elapsed)")
    }

    @Test func notionOnlyElementsIgnoreEscapedTextCodeAndLinks() {
        func kinds(_ m: String) -> [String] { NotionMarkdown.notionOnlyElements(in: m) }
        #expect(kinds(#"\<callout\> と \{color="red"\} と \$5 と \$6"#).isEmpty)
        #expect(kinds("`$x$` と `<span>` と [a](https://x.y/?q={a})").isEmpty)
        #expect(kinds("<meeting-notes>議事録</meeting-notes>") == ["会議メモ"])
        #expect(kinds("出典 [^https://example.com]") == ["引用元"])
        #expect(kinds(#"![図\]1](https://x.y/a.png)"#) == ["画像・ファイル"])
        #expect(kinds(#"<unknown alt="bookmark"/>"#) == ["取得できなかったブロック"])
    }

    @Test func escapedCharactersAreExportedOnce() {
        #expect(export(##"a\*b と \# x と \_x\_"##) == ##"a\*b と \# x と \_x\_"##)
        #expect(export("C:\\Users") == "C:\\\\Users") // a backslash before a letter is text: escaped
    }
}
