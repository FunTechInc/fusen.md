import AppKit
import Testing
@testable import FusenCore

/// Importing from Notion (NotionMarkdown.fromNotion) must show exactly what Notion shows, and a note the
/// app exported must come back unchanged. What Notion sends is Notion-flavored Markdown ("v2").
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

    private func isBold(_ text: String, at sub: String) -> Bool {
        let storage = NSTextStorage(string: text)
        styler.restyle(storage)
        let r = (text as NSString).range(of: sub)
        let font = storage.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
        return font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
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

    /// Any note: what comes back from its export is the note as Notion holds it, so it exports to the
    /// same Markdown again, importing that changes nothing more, and none of it is Notion-only. (The
    /// notes are put together at random, see RandomNote. Kept short, as these tests run on the main
    /// actor; more seeds are worth a run after a change.)
    @Test func anyNoteIsStableOnceItCameBack() {
        // Numbered items count on in Notion, and so they do in the note that comes back; a wider number
        // indents its children further. Neither is a difference.
        func comparable(_ markdown: String) -> String {
            markdown.replacingOccurrences(of: #"(?m)^ *\d+\. "#, with: "1. ", options: .regularExpression)
                .replacingOccurrences(of: #"(?m)^ +"#, with: "", options: .regularExpression)
        }
        for seed in 0..<100 {
            var random = RandomNote(seed: seed)
            let note = random.note()
            let exported = export(note)
            let back = fromNotion(exported)
            #expect(comparable(export(back)) == comparable(exported), "seed \(seed): \(note.debugDescription) came back as \(back.debugDescription)")
            #expect(fromNotion(export(back)) == back, "seed \(seed): \(back.debugDescription)")
            #expect(NotionMarkdown.notionOnlyElements(in: exported).isEmpty, "seed \(seed): \(exported.debugDescription)")
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
            (#"\<b>太字ではない\</b> と \<br />"#, "<b>太字ではない</b> と <br />"),
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

    @Test func characterReferencesAreTheirCharacters() {
        // Notion's format lets a tag in text be written "&lt;tag&gt;" as well as "\<tag>".
        #expect(fromNotion("&lt;div&gt; と &amp; と &quot;x&quot; と &#42;x&#42; と &#x3C;") == "<div> と & と \"x\" と \\*x\\* と <")
        #expect(shown(fromNotion("&#42;x&#42;")) == "*x*")
        // Not a reference: as written. Neither is one in code.
        #expect(fromNotion("A&B と R&D; と &unknown; と `&lt;`") == "A&B と R&D; と &unknown; と `&lt;`")
        // What the app sends for such text comes back as it was.
        for note in ["&amp; と &lt;b&gt;", "A&B&#35;", "a &nbsp; b"] {
            #expect(fromNotion(export(note)) == note, "\(export(note))")
        }
    }

    @Test func aBackslashIsOnlyKeptWhereTheAppHidesIt() {
        // The app's backslash escapes its own syntax characters only: before "$", "<" or "|" it would
        // be shown. So where a line needs an escape to stay text ("# " would be a heading), only the
        // characters the app escapes get one.
        #expect(fromNotion(##"\# \$x\$ と \<tag> \| \&amp;"##) == ##"\# $x$ と <tag> | &amp;"##)
        #expect(shown(fromNotion(##"\# \$x\$ と \<tag> \| \&amp;"##)) == "# $x$ と <tag> | &amp;")
        #expect(fromNotion(#"\- \<p /> \{a\}"#) == #"\- <p /> {a}"#)
        #expect(fromNotion(#"1\. \$5"#) == #"1\. $5"#)
    }

    @Test func underscoresNotionNeverEscapesStayLiteral() {
        let text = fromNotion("def __init__(self): と if __name__ == \"__main__\": と snake_case_name")
        #expect(shown(text) == "def __init__(self): と if __name__ == \"__main__\": と snake_case_name")
        #expect(!isStyled(text, .mdMarker, at: "init"))
        #expect(text.contains("snake_case_name")) // intraword underscores need no escape
        // Escaped by Notion, they are the same text.
        #expect(fromNotion(#"def \_\_init\_\_(self): と snake\_case\_name"#) == #"def \_\_init\_\_(self): と snake_case_name"#)
    }

    // MARK: Formatting tags

    @Test func formattingTagsBecomeTheAppsSyntax() {
        // Notion writes bold, italic, strikethrough and inline code as tags.
        #expect(fromNotion("<b>太字</b> と <i>斜体</i> と <s>取り消し</s> と <code>code</code>") == "**太字** と *斜体* と ~~取り消し~~ と `code`")
        #expect(fromNotion("<b><i>両方</i></b> と <s><b>消した太字</b></s>") == "***両方*** と ~~**消した太字**~~")
        #expect(fromNotion("<b>a <i>b</i> c</b>") == "**a *b* c**")
        #expect(fromNotion("[<b>太字のリンク</b>](https://a.b)") == "[**太字のリンク**](https://a.b)")
        // The app's own forms are still read (Notion accepts them as input).
        #expect(fromNotion("**太字** と *斜体* と ~~取り消し~~ と `code`") == "**太字** と *斜体* と ~~取り消し~~ と `code`")
        // The app's delimiters must touch the text: spaces at the edge of a span move outside it.
        #expect(fromNotion("前<b> 太字 </b>後") == "前 **太字** 後")
        #expect(isBold(fromNotion("<b>「強調」</b>です"), at: "強調"))
        // What a tag holds is text: an escaped character in it stays text in the app (its backslash
        // is kept only where the app would read the character as syntax).
        #expect(fromNotion(#"<b>2\*3 と \_x\_</b>"#) == #"**2*3 と \_x\_**"#)
        #expect(shown(fromNotion(#"<b>2\*3 と \_x\_</b>"#)) == "2*3 と _x_")
        #expect(fromNotion(#"<i>a\*b</i>"#) == #"*a\*b*"#)
        // Code is literal: nothing in it is a tag, an escape or a reference.
        #expect(fromNotion(#"<code>a < b && c\* &lt; <b>x</b></code>"#) == #"`a < b && c\* &lt; <b>x</b>`"#)
        #expect(fromNotion("<code>a`b</code> と <code>`x`</code>") == "``a`b`` と `` `x` ``")
        // Tags the app has nothing for stay as they are, and a tag that is never closed is text.
        #expect(fromNotion("<u>下線</u> と <span color=\"red\">赤</span>") == "<u>下線</u> と <span color=\"red\">赤</span>")
        #expect(fromNotion("<b>閉じない") == "<b>閉じない")
    }

    // MARK: Line breaks

    @Test func lineBreaksInsideCodeAreText() {
        #expect(fromNotion("HTML の改行は `<br>` を使う") == "HTML の改行は `<br>` を使う")
        #expect(fromNotion("> 引用の `<br/>` タグ") == "> 引用の `<br/>` タグ")
        #expect(fromNotion("HTML の改行は <code><br /></code> を使う") == "HTML の改行は `<br />` を使う")
    }

    @Test func lineBreaksInListItemsStayInTheItem() {
        #expect(fromNotion("- 項目<br />続き") == "- 項目\n\t続き")
        #expect(fromNotion("- [ ] タスク<br />メモ") == "- [ ] タスク\n\tメモ")
        #expect(fromNotion("- 親\n  - 子<br />続き") == "- 親\n\t- 子\n\t\t続き")
        #expect(fromNotion("段落<br />次の行") == "段落\n次の行")
        #expect(NotionMarkdown.notionOnlyElements(in: "# 見出し<br />続き") == ["ブロック内の改行"])
        #expect(fromNotion("# 見出し<br />続き") == "# 見出し\n続き")
    }

    @Test func linesOfOneBlockAreJoined() {
        // In this format a single newline does not start a block: the lines are one paragraph. A "\"
        // at the end of a line is a line break.
        #expect(fromNotion("一行目\n二行目\n\n次の段落") == "一行目 二行目\n次の段落")
        #expect(fromNotion("一行目\\\n二行目") == "一行目\n二行目")
        #expect(fromNotion("- 項目\\\n  続き\n- 次") == "- 項目\n\t続き\n- 次")
        #expect(fromNotion("- 項目\n  続きの文\n\n  子の段落") == "- 項目 続きの文\n\t子の段落")
        // A block of its own ends the paragraph, without a blank line too.
        #expect(fromNotion("本文\n# 見出し\n本文\n- 項目\n> 引用\n---") == "本文\n# 見出し\n本文\n- 項目\n> 引用\n---")
        // Lines of a quote are lines of the quote; a line right under it belongs to it.
        #expect(fromNotion("> 一行目\n> 二行目\n続き\n\n> 別の引用") == "> 一行目\n> 二行目 続き\n> 別の引用")
        #expect(fromNotion("> 一行目\\\n> 二行目") == "> 一行目\n> 二行目")
    }

    @Test func blockSyntaxAfterALineBreakStaysText() {
        #expect(fromNotion("段落<br /># 見出し") == "段落\n\\# 見出し")
        #expect(fromNotion("段落<br />---") == "段落\n\\---")
        #expect(fromNotion("段落<br />- x") == "段落\n\\- x")
        #expect(fromNotion("- 項目<br />- 続き") == "- 項目\n\t\\- 続き")
        #expect(fromNotion("- 項目<br />1. 続き") == "- 項目\n\t1\\. 続き")
    }

    // MARK: Nesting

    @Test func childrenComeBackIndentedUnderTheirBlock() {
        // List items under list items: indented with spaces to where the parent's text starts (as
        // Notion writes them), or with tabs.
        #expect(fromNotion("- 親\n  - 子\n    - 孫\n  - 子2\n- 次") == "- 親\n\t- 子\n\t\t- 孫\n\t- 子2\n- 次")
        #expect(fromNotion("1. 手順\n   - [ ] 確認\n   1. 子の手順\n      - 孫\n2. 次") == "1. 手順\n\t- [ ] 確認\n\t1. 子の手順\n\t\t- 孫\n2. 次")
        #expect(fromNotion("- 親\n\t- 子\n\t\t- 孫") == "- 親\n\t- 子\n\t\t- 孫")
        #expect(fromNotion("- 親\n\n  - 子\n\n  2. 番号\n- 次") == "- 親\n\t- 子\n\t2. 番号\n- 次")
        // Any other block with children is a tag: its text, a blank line, its children.
        #expect(fromNotion("<p>\n本文\n\n- 項目\n\n続き\n</p>") == "本文\n\t- 項目\n\t続き")
        #expect(fromNotion("<quote>\n引用\n\n子の本文\n</quote>") == "> 引用\n\t子の本文")
        #expect(fromNotion("<ul>\n<li>\n項目\n\n続きの行\n\n<p />\n\n- 子\n</li>\n</ul>") == "- 項目\n\t続きの行\n\n\t- 子")
        #expect(fromNotion("<ul>\n<li>\n親\n\n<ul>\n<li>\n子\n\n本文\n</li>\n</ul>\n</li>\n</ul>") == "- 親\n\t- 子\n\t\t本文")
        // Without text of its own: an empty paragraph where the text would be.
        #expect(fromNotion("<ul>\n<li>\n<p />\n\n- 子\n</li>\n</ul>") == "- \n\t- 子")
        // The same children, written indented under a Markdown item.
        #expect(fromNotion("- 項目\n\n  続きの行\n\n  <p />\n\n  - 子") == "- 項目\n\t続きの行\n\n\t- 子")
        #expect(fromNotion("- 親\n\n  <todo checked=\"false\" color=\"blue\">\n  子\n  </todo>") == "- 親\n\t- [/] 子")
    }

    @Test func numberedItemsCountOnAsInNotion() {
        // A tag has no number: the item counts on from the one before it.
        #expect(fromNotion("1. 一\n\n<ol>\n<li>\n二\n\n補足\n</li>\n</ol>\n\n3. 三") == "1. 一\n2. 二\n\t補足\n3. 三")
        #expect(fromNotion("<ol>\n<li>\n一\n</li>\n<li>\n二\n</li>\n</ol>") == "1. 一\n2. 二")
        #expect(fromNotion("5. 五\n6. 六") == "5. 五\n6. 六")
        // Notion numbers a list itself, so in Markdown every item may be "1.": the app, which shows the
        // number that is written, counts on. Another block starts a new list.
        #expect(fromNotion("1. 一\n1. 二\n1. 三\n   1. 子\n   1. 子2\n1. 四") == "1. 一\n2. 二\n3. 三\n\t1. 子\n\t2. 子2\n4. 四")
        #expect(fromNotion("3. 三\n1. 次\n\n- 箇条書き\n\n1. 一") == "3. 三\n4. 次\n- 箇条書き\n1. 一")
        // Numbers that count up are the note's own: kept.
        #expect(fromNotion("1. 一\n2. 二\n10. 十") == "1. 一\n2. 二\n10. 十")
    }

    @Test func aBlocksTagsMayStandOnOneLine() {
        // Notion writes the two tags of a block on lines of their own; it reads them on one line too.
        #expect(fromNotion("<todo checked=\"false\" color=\"blue\">進行中</todo>") == "- [/] 進行中")
        #expect(fromNotion("<quote>引用</quote>\n\n<p>段落</p>\n\n<h3>見出し</h3>") == "> 引用\n段落\n### 見出し")
        #expect(fromNotion("<callout icon=\"💡\" color=\"red_bg\"><b>名前</b></callout>") == ":::card red 名前\n:::")
        // A block without text may close in its own tag.
        #expect(fromNotion("<todo checked=\"false\" color=\"orange\" />\n\n<callout icon=\"💡\" />") == "- [>] \n:::card default \n:::")
        // A formatting tag at the start of a line is not a block.
        #expect(fromNotion("<b>太字</b>\n\n<u>下線</u>\n\n<code>p</code>") == "**太字**\n<u>下線</u>\n`p`")
    }

    @Test func blocksTheAppCannotNestComeBackAtTheTop() {
        // A code block nested under a list item: indented under it, or between the item's tags.
        let indented = "- 項目\n\n  ```swift\n  let x = 1\n  \tindented()\n  ```"
        #expect(fromNotion(indented) == "- 項目\n```swift\nlet x = 1\n\tindented()\n```")
        #expect(NotionMarkdown.notionOnlyElements(in: indented) == ["入れ子のコードブロック"])
        let tagged = "<ul>\n<li>\n項目\n\n```swift\nlet x = 1\n\tindented()\n```\n</li>\n</ul>"
        #expect(fromNotion(tagged) == "- 項目\n```swift\nlet x = 1\n\tindented()\n```")
        #expect(NotionMarkdown.notionOnlyElements(in: tagged) == ["入れ子のコードブロック"])
        // In a callout it is not nested: a card holds code blocks.
        #expect(NotionMarkdown.notionOnlyElements(in: "<callout icon=\"💡\">\n名前\n\n```\ncode\n```\n</callout>").isEmpty)
        // Headings, quotes and dividers are top level in the app too.
        #expect(fromNotion("<ul>\n<li>\n項目\n\n## 見出し\n\n> 引用\n\n---\n</li>\n</ul>") == "- 項目\n## 見出し\n> 引用\n---")
    }

    @Test func aColorTheAppCannotShowKeepsItsTagAsText() {
        // The block stays the block it is; the two lines of its tag stay around it, as text.
        #expect(fromNotion("<h2 color=\"blue\">\n見出し\n</h2>") == "<h2 color=\"blue\">\n## 見出し\n</h2>")
        #expect(fromNotion("<p color=\"gray_bg\">\n段落\n\n- 子\n</p>") == "<p color=\"gray_bg\">\n段落\n\t- 子\n</p>")
        #expect(fromNotion("<quote color=\"purple_bg\">\n引用\n</quote>") == "<quote color=\"purple_bg\">\n> 引用\n</quote>")
        #expect(fromNotion("<ol>\n<li color=\"red\">\n一\n</li>\n</ol>") == "<li color=\"red\">\n1. 一\n</li>")
        for markdown in ["<h2 color=\"blue\">\n見出し\n</h2>", "<p color=\"gray_bg\">\n段落\n</p>", "<quote color=\"purple_bg\">\n引用\n</quote>"] {
            #expect(NotionMarkdown.notionOnlyElements(in: markdown) == ["文字色・下線"], "\(markdown)")
        }
        // Without a color the tag is only how the block was written.
        #expect(fromNotion("<h2>\n見出し\n</h2>\n\n<p>\n段落\n</p>\n\n<quote>\n引用\n</quote>") == "## 見出し\n段落\n> 引用")
        #expect(fromNotion("<p color=\"default\">\n段落\n</p>") == "段落")
        #expect(fromNotion("<p>\n</p>") == "")
    }

    // MARK: Notion's own examples

    /// The example of the format's reference (guides/data-apis/notion-flavored-markdown): a quote in a
    /// color, with its text, a blank line, and its children — a bullet and a callout.
    @Test func theExampleOfNotionsReference() {
        let example = """
        <quote color="purple_bg">
        Title text

        - child bullet

        <callout icon="💡" color="yellow_bg">
        Callout body child
        </callout>
        </quote>
        """
        #expect(fromNotion(example) == """
        <quote color="purple_bg">
        > Title text
        \t- child bullet
        :::card yellow 
        Callout body child
        :::
        </quote>
        """)
        #expect(NotionMarkdown.notionOnlyElements(in: example) == ["文字色・下線"])
    }

    /// What the migration guide (guides/data-apis/migrate-to-notion-flavored-markdown) shows of the
    /// API's output for the blocks and the text the app has nothing for: they stay as they are, each
    /// under its name.
    @Test func blocksOfTheMigrationGuideStayAsTheyAre() {
        func stays(_ markdown: String, _ names: [String], sourceLocation: SourceLocation = #_sourceLocation) {
            // (As text: one line per line, the blank lines between blocks gone.)
            let lines = markdown.components(separatedBy: "\n").filter { !$0.isEmpty }.joined(separator: "\n")
            #expect(fromNotion(markdown) == lines, sourceLocation: sourceLocation)
            #expect(NotionMarkdown.notionOnlyElements(in: markdown) == names, sourceLocation: sourceLocation)
        }
        stays("<toggle>\nTitle\n\nChildren\n</toggle>", ["トグル"])
        stays("<toggle heading=\"h2\">\nTitle\n\nChildren\n</toggle>", ["トグル"])
        stays("<file source=\"https://a.b/c.zip\">\nCaption\n</file>", ["画像・ファイル"])
        stays("<pdf source=\"https://a.b/c.pdf\" />", ["画像・ファイル"])
        stays("<bookmark source=\"https://a.b\" />", ["ブックマーク・埋め込み"])
        stays("<embed source=\"https://a.b\" />", ["ブックマーク・埋め込み"])
        stays("<table-of-contents />", ["目次"])
        stays("<synced-block url=\"https://www.notion.so/x\">\n中身\n</synced-block>", ["同期ブロック"])
        stays("<page url=\"https://www.notion.so/x\">\nTitle\n</page>", ["サブページ・データベース"])
        stays("<database url=\"https://www.notion.so/x\" data-source-url=\"collection://y\" inline=\"true\">\nTitle\n</database>", ["サブページ・データベース"])
        stays("<meeting-notes view-url=\"https://www.notion.so/x\">\n<meeting-notes-section-summary>\n要約\n</meeting-notes-section-summary>\n</meeting-notes>", ["会議メモ"])
        stays("<table>\n<tr>\n<td>\nName\n</td>\n</tr>\n</table>", ["表"])
        stays("<mention url=\"user://1\" /> と <mention url=\"https://www.notion.so/x\">Title</mention> と <date start=\"2026-11-02\" start-time=\"09:30\" />", ["メンション"])
        stays("<u>text</u> と <span color=\"red\">text</span>", ["文字色・下線"])
        stays("$E=mc^2$", ["数式"])
        stays("<unknown url=\"https://www.notion.so/x#y\" alt=\"breadcrumb\" />", ["取得できなかったブロック"])
        // And what the app has something for.
        #expect(fromNotion("<p color=\"gray_bg\">\nText\n</p>\n\n<h1 color=\"blue\">\nHeading\n</h1>") == "<p color=\"gray_bg\">\nText\n</p>\n<h1 color=\"blue\">\n# Heading\n</h1>")
        #expect(fromNotion("<callout icon=\"💡\" color=\"yellow_bg\">\nText\n\nChildren\n</callout>") == ":::card yellow \nText\nChildren\n:::")
        #expect(fromNotion("<ul>\n<li color=\"blue\">\nItem\n</li>\n</ul>") == "<li color=\"blue\">\n- Item\n</li>")
        #expect(fromNotion("<todo checked=\"false\" color=\"green\">\nTask\n</todo>") == "<todo checked=\"false\" color=\"green\">\n- [ ] Task\n</todo>")
        #expect(fromNotion("<b>text</b>, <i>text</i>, <s>text</s>, <code>code</code>, \\<tag>") == "**text**, *text*, ~~text~~, `code`, <tag>")
        #expect(fromNotion("| Name | Owner |\n| --- | --- |\n| Spec | Ada |") == "| Name | Owner |\n| --- | --- |\n| Spec | Ada |")
    }

    // MARK: Code, tables, links, equations

    @Test func codeBlocksAreCopied() {
        #expect(fromNotion("```swift\nlet a = \"<b>\\*</b>\" // &amp;\n\n</callout>\n```\n\n後") == "```swift\nlet a = \"<b>\\*</b>\" // &amp;\n\n</callout>\n```\n後")
        #expect(fromNotion("````\n```\ncode\n```\n````") == "````\n```\ncode\n```\n````")
        // Notion names a block without a language "txt": the app writes that as no language.
        #expect(fromNotion("```txt\nplain\n```") == "```\nplain\n```")
        #expect(fromNotion("```py\nprint(1)\n```") == "```py\nprint(1)\n```")
    }

    @Test func tableRowsStayLines() {
        // A plain table is a pipe table in this format: the app shows its rows as text.
        let table = "| Name | Owner |\n| --- | --- |\n| Spec | Ada |"
        #expect(fromNotion(table) == table)
        #expect(NotionMarkdown.notionOnlyElements(in: table) == ["表"])
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

    /// What Notion shows for plain-text Markdown: its backslash escapes removed. (Blocks, which a blank
    /// line separates, one per line.)
    private func notionShown(_ markdown: String) -> String {
        var out = ""
        var escaping = false
        for c in markdown.replacingOccurrences(of: "\n\n", with: "\n") {
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
        // A literal backslash, then 重要 in italics: as Notion writes it, and as the app's own form.
        for markdown in ["\\\\<i>重要</i>", "\\\\*重要*"] {
            let text = fromNotion(markdown)
            #expect(isStyled(text, .obliqueness, at: "重要"), "\(markdown) → \(text)")
            #expect(export(text) == "\\\\<i>重要</i>", "\(markdown) → \(export(text))")
        }
    }

    @Test func lineBreaksInsideCodeAreNotReported() {
        #expect(NotionMarkdown.notionOnlyElements(in: "HTML の改行は `<br>` を使う").isEmpty)
        #expect(NotionMarkdown.notionOnlyElements(in: "HTML の改行は <code><br /></code> を使う").isEmpty)
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
        #expect(kinds(#"\<callout> と \<span color="red"> と \$5 と \$6 と &lt;toggle&gt;"#).isEmpty)
        #expect(kinds("`$x$` と `<span>` と <code><u>x</u></code> と [a](https://x.y/?q=<u>)").isEmpty)
        #expect(kinds("<meeting-notes>議事録</meeting-notes>") == ["会議メモ"])
        #expect(kinds("出典 [^https://example.com]") == ["引用元"])
        #expect(kinds(#"![図\]1](https://x.y/a.png)"#) == ["画像・ファイル"])
        #expect(kinds(#"<unknown url="https://www.notion.so/x" alt="breadcrumb" />"#) == ["取得できなかったブロック"])
    }

    @Test func escapedCharactersAreExportedOnce() {
        #expect(export(##"a\*b と \# x と \_x\_"##) == ##"a\*b と \# x と \_x\_"##)
        #expect(export("C:\\Users") == "C:\\\\Users") // a backslash before a letter is text: escaped
    }
}
