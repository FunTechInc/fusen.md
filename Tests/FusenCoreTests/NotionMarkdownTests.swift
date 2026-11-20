import AppKit
import Testing
@testable import FusenCore

/// Headless: the exporter only needs an NSTextStorage and the styler. The expectations are
/// Notion-flavored Markdown ("v2"): blocks separated by a blank line, `<p />` for an empty paragraph,
/// `<br />` for a line break, tags for a block with children or a color.
@MainActor
struct NotionMarkdownTests {
    let styler = MarkdownStyler()

    private func export(_ text: String) -> String { NotionMarkdown.export(text, styler: styler) }

    @Test func plainTextAndBlankLines() {
        #expect(export("") == "")
        // A blank line separates blocks; a blank line of the note is an empty paragraph.
        #expect(export("一行目\n二行目") == "一行目\n\n二行目")
        #expect(export("こんにちは\n\n世界") == "こんにちは\n\n<p />\n\n世界")
        #expect(export("a\n   \nb") == "a\n\n<p />\n\nb")              // whitespace-only is blank too
        #expect(export("a\n\n\n") == "a")                             // trailing blank lines are dropped
        #expect(export("\n\na") == "<p />\n\n<p />\n\na")
    }

    @Test func headingsUpToFourLevels() {
        #expect(export("# 見出し1\n## 見出し2\n### 見出し3\n#### 見出し4") == "# 見出し1\n\n## 見出し2\n\n### 見出し3\n\n#### 見出し4")
        #expect(export("##### 五\n###### 六") == "#### 五\n\n#### 六")
        #expect(export("  #   余白  ") == "# 余白")
        #expect(export("# **太字** の見出し") == "# <b>太字</b> の見出し")
    }

    @Test func listsTasksAndNesting() {
        // The items of one list follow each other directly, as in any Markdown.
        #expect(export("- a\n* b\n+ c") == "- a\n- b\n- c")
        #expect(export("1. 一\n2) 二\n10. 十") == "1. 一\n2. 二\n10. 十")
        #expect(export("- [ ] やること\n- [x] 完了\n* [X] 大文字\n1. [ ] 番号付き") ==
                "- [ ] やること\n- [x] 完了\n- [x] 大文字\n- [ ] 番号付き")
        // Another kind of list is another block.
        #expect(export("- a\n1. b\n- [ ] c\n- d") == "- a\n\n1. b\n\n- [ ] c\n- d")
        // Nested items are indented to where their parent's text starts: 2 spaces under "-", 3 under "1.".
        #expect(export("- 親\n\t- 子\n\t\t- 孫\n  - 子（スペース）\n    - 孫（スペース）") ==
                "- 親\n  - 子\n    - 孫\n  - 子（スペース）\n    - 孫（スペース）")
        #expect(export("1. 手順\n\t- [ ] 確認") == "1. 手順\n   - [ ] 確認")
        #expect(export("10. 十\n\t- 子\n\t\t1. 孫") == "10. 十\n    - 子\n      1. 孫")
    }

    @Test func aChildThatMarkdownWouldReadAsTextGetsABlankLine() {
        // Right under its parent's text, an empty item would make that text a heading ("親" over "-"),
        // and a number other than 1 would be more of the text.
        #expect(export("- 親\n\t- ") == "- 親\n\n  - ")
        #expect(export("- 親\n\t2. 子\n\t3. 孫ではない") == "- 親\n\n  2. 子\n  3. 孫ではない")
        #expect(export("- 親\n\t1. 子") == "- 親\n  1. 子")
        #expect(export("- 親\n\t- [ ] ") == "- 親\n\n  - [ ] ")
    }

    @Test func nestingNeverSkipsALevelOrHangsOffAHeading() {
        #expect(export("- a\n\t\t\t- b") == "- a\n  - b")
        #expect(export("# 見出し\n\t- a") == "# 見出し\n\n- a")   // headings cannot have children
        #expect(export("\t- 最初") == "- 最初")
    }

    @Test func childrenThatAreNotListItemsNeedTheParentAsATag() {
        // Only list items nest by indentation. Any other block with children is a tag: its text right
        // after the opening tag, its children after a blank line, not indented.
        #expect(export("- 項目\n  続きの行") == "<ul>\n<li>\n項目\n\n続きの行\n</li>\n</ul>")
        #expect(export("1. 手順\n\t補足\n2. 次") == "<ol>\n<li>\n手順\n\n補足\n</li>\n</ol>\n\n2. 次")
        #expect(export("- [x] 済み\n\tメモ") == "<todo checked=\"true\">\n済み\n\nメモ\n</todo>")
        #expect(export("本文\n\t- 項目\n\t続き") == "<p>\n本文\n\n- 項目\n\n続き\n</p>")
        #expect(export("> 引用\n\t子の本文") == "<quote>\n引用\n\n子の本文\n</quote>")
        // The parent of such a parent is a tag too (a tag is never indented under a Markdown item).
        #expect(export("- 親\n\t- 子\n\t\t本文") == "<ul>\n<li>\n親\n\n<ul>\n<li>\n子\n\n本文\n</li>\n</ul>\n</li>\n</ul>")
        // A parent without text starts with an empty paragraph, so that its first child is not read as its text.
        #expect(export("- \n\t- 子") == "<ul>\n<li>\n<p />\n\n- 子\n</li>\n</ul>")
    }

    @Test func quotesBecomeOneBlockWithLineBreaks() {
        #expect(export("> 一行目\n> 二行目\n>\n> 四行目") == "> 一行目<br />二行目<br /><br />四行目")
        #expect(export("> 引用A\n\n> 引用B") == "> 引用A\n\n<p />\n\n> 引用B")
        #expect(export("> 引用\n本文") == "> 引用\n\n本文")
        #expect(export("> **強調** と a > b") == "> <b>強調</b> と a > b")
        #expect(export("> - [ ] 引用内のタスク") == "> \\- \\[ \\] 引用内のタスク")
    }

    @Test func codeIsVerbatim() {
        let code = "```swift\nlet a = [1, 2] // $x {y} | <z> **b** &amp;\n\nprint(\"\\(a)\")\n```"
        #expect(export(code + "\n後") == code + "\n\n後")
        #expect(export("  ```\n  インデント\n  ```") == "```\n  インデント\n```")
        // An unclosed fence is closed, since the app shows the rest of the note as code.
        #expect(export("```js\nconst a = 1") == "```js\nconst a = 1\n```")
    }

    @Test func tildeFencesBecomeBacktickFences() {
        // The format only has ``` fences.
        #expect(export("~~~\n$x$ <b>\n~~~") == "```\n$x$ <b>\n```")
        #expect(export("~~~swift\nlet a = 1\n~~~") == "```swift\nlet a = 1\n```")
        #expect(export("~~~\n未完") == "```\n未完\n```")
    }

    @Test func aFenceIsLongerThanTheBackticksInItsCode() {
        // Notion asks for a fence longer than every run of backticks in the code, wherever the run is.
        #expect(export("~~~\n```\n~~~") == "````\n```\n````")
        #expect(export("```\nlet s = \"```` と ``\"\n```") == "`````\nlet s = \"```` と ``\"\n`````")
        #expect(export("````\n```\n````") == "````\n```\n````")
        #expect(export("```\n`x`\n```") == "```\n`x`\n```")
    }

    @Test func textAfterAFenceWithBackticksIsItsFirstLine() {
        // The app opens a code block; in Markdown this line would be text with inline code.
        #expect(export("```ls -la```\n本文 *a*\n```") == "````\nls -la```\n本文 *a*\n````")
        #expect(export("~~~ `x`\ncode\n~~~") == "```\n`x`\ncode\n```")
    }

    @Test func blankLinesKeepTheNesting() {
        // A blank line inside a nesting is an empty paragraph among the children.
        #expect(export("- a\n\n\t- b") == "<ul>\n<li>\na\n\n<p />\n\n- b\n</li>\n</ul>")
        #expect(export("- [ ] a\n\n\t- [ ] b") == "<todo checked=\"false\">\na\n\n<p />\n\n- [ ] b\n</todo>")
        #expect(export("- a\n\n  続き") == "<ul>\n<li>\na\n\n<p />\n\n続き\n</li>\n</ul>")
        #expect(export("- a\n\nb") == "- a\n\n<p />\n\nb")
        #expect(export("# 見出し\n\n\t- a") == "# 見出し\n\n<p />\n\n- a")
    }

    @Test func dividers() {
        // Only dashes make a divider, as in Notion; "***" and "_ _ _" stay text (escaped for Notion).
        #expect(export("上\n---\n- - -\n***\n_ _ _\n下") == "上\n\n---\n\n---\n\n\\*\\*\\*\n\n\\_ \\_ \\_\n\n下")
    }

    @Test func plainTextIsEscapedButSyntaxAndCodeAreNot() {
        // "{", "}", "^" and a ">" inside a line are not syntax in this format.
        #expect(export("価格は $5、{a} | b <c> ^d ~e [f] \\g") ==
                "価格は \\$5、{a} \\| b \\<c> ^d \\~e \\[f\\] \\\\g")
        #expect(export("`$x | {y} <z>` と $") == "`$x | {y} <z>` と \\$")
        #expect(export("2 * 3 = 6") == "2 \\* 3 = 6")
        #expect(export("[リンク$](https://example.com/a?b=$c&d={e})") == "[リンク\\$](https://example.com/a?b=$c&d={e})")
        #expect(export("# 見出しの $ と `$`") == "# 見出しの \\$ と `$`")
        #expect(export("- 項目の <tag>") == "- 項目の \\<tag>")
        // "&" only where Markdown would decode a character reference.
        #expect(export("&amp; と A&B と R&D; と &#35; と &#x3C;") == "\\&amp; と A&B と R&D; と \\&#35; と \\&#x3C;")
    }

    @Test func emphasisBecomesTags() {
        // Tags have no rules about what stands next to them; "**" has, and CommonMark would not read
        // these as bold where a Japanese bracket or mark touches the delimiter.
        #expect(export("**太字** と *斜体* と ~~取り消し~~") == "<b>太字</b> と <i>斜体</i> と <s>取り消し</s>")
        #expect(export("**「強調」**です と これは**（注）**です") == "<b>「強調」</b>です と これは<b>（注）</b>です")
        #expect(export("***両方*** と ~~**消した太字**~~") == "<b><i>両方</i></b> と <s><b>消した太字</b></s>")
        #expect(export("**a *b* c**") == "<b>a <i>b</i> c</b>")
        #expect(export("[**太字のリンク**](https://a.b)") == "[<b>太字のリンク</b>](https://a.b)")
        // Spans that cross are written so that the tags nest.
        #expect(export("**a *b** c*") == "<b>a <i>b</i></b><i> c</i>")
        // "_" and "__" are the same spans.
        #expect(export("__太字__ と _斜体_") == "<b>太字</b> と <i>斜体</i>")
        #expect(export("snake__case__name") == "snake<b>case</b>name") // bold in the app, so bold in Notion
    }

    @Test func underscoresThatAreTextStayText() {
        // Between letters "_" is never emphasis, in the app or in Markdown: no escape.
        #expect(export("snake_case_name と file_2_name") == "snake_case_name と file_2_name")
        #expect(export("[a_b](https://example.com/a_b_c)") == "[a_b](https://example.com/a_b_c)")
        // Anywhere else Markdown could read it as emphasis.
        #expect(export("_ x _ と a_ と _b") == "\\_ x \\_ と a\\_ と \\_b")
        #expect(export("**a**_b") == "<b>a</b>\\_b") // next to a tag it is not between letters any more
        #expect(export(#"def \_\_init\_\_(self):"#) == #"def \_\_init\_\_(self):"#) // escaped in the note already
    }

    @Test func blockSyntaxThatTheAppShowsAsTextStaysText() {
        // Headings and dividers take at most three spaces of indentation in the app.
        #expect(export("    # 見出しではない") == "\\# 見出しではない")
        #expect(export("本文\n\t# タブ付き") == "<p>\n本文\n\n\\# タブ付き\n</p>")
        #expect(export("    ---") == "\\---")
        #expect(export("    ___") == "\\_\\_\\_")
        // In a list item, block syntax would become an empty item with a child block.
        #expect(export("- # foo") == "- \\# foo")
        #expect(export("- - foo") == "- \\- foo")
        #expect(export("- + foo") == "- \\+ foo")
        #expect(export("1. - foo") == "1. \\- foo")
        #expect(export("- 1. foo") == "- 1\\. foo")
        #expect(export("- 2) foo") == "- 2\\) foo")
        #expect(export("- [ ] # 見出し風") == "- [ ] \\# 見出し風")
        #expect(export("> # 引用内の見出し風") == "> \\# 引用内の見出し風")
        #expect(export(">     字下げした引用") == "> 字下げした引用")
        // ">" starts a quote only at the start of a block.
        #expect(export("- > 引用風 > と") == "- \\> 引用風 > と")
        #expect(export("    > 字下げした行") == "\\> 字下げした行")
        #expect(export("> >x") == "> \\>x")
        // "- --" would be a divider.
        #expect(export("* --") == "- \\--")
        // Not block syntax: unchanged.
        #expect(export("#タグ と 1.5 倍 と -1") == "#タグ と 1.5 倍 と -1")
        #expect(export("- 1.5 倍") == "- 1.5 倍")
        // A heading's trailing " #" is text in the app but a closing sequence in Markdown.
        #expect(export("## 課題 #") == "## 課題 \\#")
        #expect(export("# #") == "# \\#")
        #expect(export("# C# の話") == "# C# の話")
        // "!" right before a link would make it an image.
        #expect(export("![logo](https://example.com/a.png)") == "\\![logo](https://example.com/a.png)")
        #expect(export("見て!https://example.com") == "見て\\![https://example.com](https://example.com)")
    }

    @Test func linksNotionCannotOpenStayText() {
        #expect(export("[メモ](note.md) と [x](#a) と [x]($5)") == "\\[メモ\\](note.md) と \\[x\\](#a) と \\[x\\](\\$5)")
        #expect(export("[a](https://x.com \"題\")") == "[a](https://x.com)") // no titles in the format
        #expect(export("[a](mailto:a@example.com)") == "[a](mailto:a@example.com)")
        // Links cannot nest: a URL in a label stays text.
        #expect(export("[see https://x.com](https://y.com)") == "[see https://x.com](https://y.com)")
        #expect(export("https:///x") == "https:///x")
    }

    @Test func bareURLsBecomeLinks() {
        #expect(export("https://example.com/pathを参照") == "[https://example.com/path](https://example.com/path)を参照")
        #expect(export("見て https://x.y/~u") == "見て [https://x.y/\\~u](https://x.y/~u)")
        #expect(export("[Apple](https://www.apple.com)") == "[Apple](https://www.apple.com)")
    }

    @Test func textThatLooksLikeNotionSyntaxStaysText() {
        #expect(export("$$\nE = mc^2\n$$") == "\\$\\$\n\nE = mc^2\n\n\\$\\$")
        #expect(export("<callout>中身</callout>") == "\\<callout>中身\\</callout>")
        #expect(export("| a | b |\n| --- | --- |") == "\\| a \\| b \\|\n\n\\| --- \\| --- \\|")
        // The tags of the format itself, typed in a note.
        #expect(export("<p />\n<todo checked=\"false\">\nやること\n</todo>") == "\\<p />\n\n\\<todo checked=\"false\">\n\nやること\n\n\\</todo>")
        #expect(export("一行目<br />二行目 と <b>太字</b>") == "一行目\\<br />二行目 と \\<b>太字\\</b>")
        // The color syntax of the older format is text in this one: nothing to escape.
        #expect(export("見出し {color=\"blue\"}") == "見出し {color=\"blue\"}")
    }

    // MARK: fromNotion

    @Test func importReversesTheSpecialForms() {
        #expect(NotionMarkdown.fromNotion("a\n\n<p />\n\nb") == "a\n\nb")
        #expect(NotionMarkdown.fromNotion("a\n\nb\n\n\n\nc") == "a\nb\nc") // blank lines only separate blocks
        #expect(NotionMarkdown.fromNotion("> 一<br />二<br /><br />四") == "> 一\n> 二\n>\n> 四")
        #expect(NotionMarkdown.fromNotion("行1<br />行2<br>行3") == "行1\n行2\n行3")
        #expect(NotionMarkdown.fromNotion("\\$5 {a} \\| \\<b> \\\\ \\*") == "$5 {a} | <b> \\ *")
        #expect(NotionMarkdown.fromNotion("`\\$ stays` と \\$") == "`\\$ stays` と $")
        #expect(NotionMarkdown.fromNotion("```\n\\$ stays\n\n<p />\n```") == "```\n\\$ stays\n\n<p />\n```")
        #expect(NotionMarkdown.fromNotion("[https://a.b/\\~c](https://a.b/~c) と [ラベル\\*](https://a.b)") ==
                "https://a.b/~c と [ラベル*](https://a.b)")
        #expect(NotionMarkdown.fromNotion("- [ ] a\n  - [x] b") == "- [ ] a\n\t- [x] b")
        // A callout is a card (see NotionCardTests); tags the app does not know stay as they are.
        #expect(NotionMarkdown.fromNotion("<callout icon=\"💡\">\n中身\n</callout>") == ":::card default \n中身\n:::")
        #expect(NotionMarkdown.fromNotion("<toggle>\n見出し\n\n中身\n</toggle>") == "<toggle>\n見出し\n中身\n</toggle>")
    }

    /// Representative notes: exporting and importing again gives the note back, normalized the way
    /// Notion stores it (2 spaces → tab, "*" → "-", "1)" → "1.", H5 → H4, no trailing blank lines).
    @Test func roundTrip() {
        let unchanged = [
            AppDelegate.welcomeText,
            """
            # 買い物リスト
            - [ ] 牛乳 $3
            - [x] パン {全粒粉}
            \t- 子の項目 | メモ
            1. 番号付き
            2. **二番目** は `code | $x`

            > 引用の一行目
            > 引用の二行目 https://example.com/a_b
            ---
            ```swift
            let dict = ["a": 1] // <T> $ { } |
            ```
            最後の行 \\ バックスラッシュ
            """,
            "日本語だけのメモ。記号なし。",
            "- # 見出し風の項目\n- 1. 番号風\n\t# 字下げした #",
            "**「強調」**です と *斜体* と ~~**消した太字**~~ と ***両方***",
            "- 親\n\t続きの行\n\n\t- 子\n\t\t孫の本文\n本文\n\t- 字下げした箇条書き\n> 引用\n\t子の本文",
            "- 親\n\t- \n- 親2\n\t2. 子\n\t- 子3\n- \n1. \n- [ ] ",
            "&amp; と A&B と &#35; と <p /> と a<br />b と {color=\"blue\"}",
        ]
        for note in unchanged {
            #expect(NotionMarkdown.fromNotion(export(note)) == note, "\(export(note))")
        }

        let original = "* 項目\n  + 子\n1) 一\n##### 小見出し\n  > 引用\n- [X] 完了\n- - -\n\n\n"
        let normalized = "- 項目\n\t- 子\n1. 一\n#### 小見出し\n> 引用\n- [x] 完了\n---"
        #expect(NotionMarkdown.fromNotion(export(original)) == normalized)
        #expect(export(normalized) == export(original))
    }

    @Test func detectsNotionOnlyElements() {
        func kinds(_ markdown: String) -> [String] { NotionMarkdown.notionOnlyElements(in: markdown) }
        #expect(kinds("# 見出し\n\n- [ ] a\n\n> 引用\n\n<b>太字</b> <code>code</code> [x](https://a.b)\n\n価格は\\$5 と \\$6").isEmpty)
        #expect(kinds("<toggle>\n開く\n\n中身\n</toggle>") == ["トグル"])
        #expect(kinds("<toggle heading=\"h2\">\n見出し\n</toggle>") == ["トグル"])
        #expect(kinds("<table header-row=\"true\">\n<tr>\n<td>\na\n</td>\n</tr>\n</table>") == ["表"])
        #expect(kinds("| Name | Owner |\n| --- | --- |\n| Spec | Ada |") == ["表"])
        #expect(kinds("<table-of-contents />") == ["目次"])
        #expect(kinds("![写真](https://a.b/c.png)") == ["画像・ファイル"])
        #expect(kinds("<pdf source=\"https://a.b/c.pdf\" />") == ["画像・ファイル"])
        #expect(kinds("<bookmark source=\"https://a.b\" />") == ["ブックマーク・埋め込み"])
        #expect(kinds("<mention url=\"user://u\">Ada</mention> と <date start=\"2026-11-20\" />") == ["メンション"])
        #expect(kinds("<p color=\"blue\">\n段落\n</p>") == ["文字色・下線"])
        #expect(kinds("<span color=\"red\">赤</span> と <u>下線</u>") == ["文字色・下線"])
        #expect(kinds("$$\nE=mc^2\n$$") == ["数式"])
        #expect(kinds("インライン $x^2$ の式") == ["数式"])
        #expect(kinds("<page url=\"https://www.notion.so/p\">\n子ページ\n</page>") == ["サブページ・データベース"])
        #expect(kinds("<synced-block url=\"x\">\n中身\n</synced-block>") == ["同期ブロック"])
        // A tag without a name of its own in this list.
        #expect(kinds("<tabs>\n<tab>\nタブ1\n</tab>\n</tabs>") == ["その他のブロック"])
        #expect(kinds("```html\n<callout>コードの中</callout>\n```").isEmpty)
        // The older format's color syntax is plain text in this one.
        #expect(kinds("段落 {color=\"blue\"}").isEmpty)
    }
}
