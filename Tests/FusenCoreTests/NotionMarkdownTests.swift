import AppKit
import Testing
@testable import FusenCore

/// Headless: the exporter only needs an NSTextStorage and the styler.
@MainActor
struct NotionMarkdownTests {
    let styler = MarkdownStyler()

    private func export(_ text: String) -> String { NotionMarkdown.export(text, styler: styler) }

    @Test func plainTextAndBlankLines() {
        #expect(export("") == "")
        #expect(export("こんにちは\n\n世界") == "こんにちは\n<empty-block/>\n世界")
        #expect(export("a\n   \nb") == "a\n<empty-block/>\nb")        // whitespace-only is blank too
        #expect(export("a\n\n\n") == "a")                             // trailing blank lines are dropped
        #expect(export("\n\na") == "<empty-block/>\n<empty-block/>\na")
    }

    @Test func headingsUpToFourLevels() {
        #expect(export("# 見出し1\n## 見出し2\n### 見出し3\n#### 見出し4") == "# 見出し1\n## 見出し2\n### 見出し3\n#### 見出し4")
        #expect(export("##### 五\n###### 六") == "#### 五\n#### 六")
        #expect(export("  #   余白  ") == "# 余白")
        #expect(export("# **太字** の見出し") == "# **太字** の見出し")
    }

    @Test func listsTasksAndNesting() {
        #expect(export("- a\n* b\n+ c") == "- a\n- b\n- c")
        #expect(export("1. 一\n2) 二\n10. 十") == "1. 一\n2. 二\n10. 十")
        #expect(export("- [ ] やること\n- [x] 完了\n* [X] 大文字\n1. [ ] 番号付き") ==
                "- [ ] やること\n- [x] 完了\n- [x] 大文字\n- [ ] 番号付き")
        // Tabs are kept, two spaces are one level; children are tab-indented as the spec requires.
        #expect(export("- 親\n\t- 子\n\t\t- 孫\n  - 子（スペース）\n    - 孫（スペース）") ==
                "- 親\n\t- 子\n\t\t- 孫\n\t- 子（スペース）\n\t\t- 孫（スペース）")
        #expect(export("1. 手順\n\t- [ ] 確認") == "1. 手順\n\t- [ ] 確認")
    }

    @Test func nestingNeverSkipsALevelOrHangsOffAHeading() {
        #expect(export("- a\n\t\t\t- b") == "- a\n\t- b")
        #expect(export("# 見出し\n\t- a") == "# 見出し\n- a")   // headings cannot have children
        #expect(export("\t- 最初") == "- 最初")
        #expect(export("- 項目\n  続きの行") == "- 項目\n\t続きの行")
    }

    @Test func quotesBecomeOneBlockWithLineBreaks() {
        #expect(export("> 一行目\n> 二行目\n>\n> 四行目") == "> 一行目<br>二行目<br><br>四行目")
        #expect(export("> 引用A\n\n> 引用B") == "> 引用A\n<empty-block/>\n> 引用B")
        #expect(export("> 引用\n本文") == "> 引用\n本文")
        #expect(export("> **強調** と a > b") == "> **強調** と a \\> b")
        #expect(export("> - [ ] 引用内のタスク") == "> \\- \\[ \\] 引用内のタスク")
    }

    @Test func codeIsVerbatim() {
        let note = "```swift\nlet a = [1, 2] // $x {y} | <z>\n\nprint(\"\\(a)\")\n```\n後"
        #expect(export(note) == note)
        #expect(export("  ```\n  インデント\n  ```") == "```\n  インデント\n```")
        // An unclosed fence is closed, since the app shows the rest of the note as code.
        #expect(export("```js\nconst a = 1") == "```js\nconst a = 1\n```")
    }

    @Test func tildeFencesBecomeBacktickFences() {
        // The format only documents ``` fences.
        #expect(export("~~~\n$x$ <b>\n~~~") == "```\n$x$ <b>\n```")
        #expect(export("~~~swift\nlet a = 1\n~~~") == "```swift\nlet a = 1\n```")
        #expect(export("~~~\n```\n~~~") == "````\n```\n````") // longer than the backticks inside
        #expect(export("~~~\n未完") == "```\n未完\n```")
    }

    @Test func textAfterAFenceWithBackticksIsItsFirstLine() {
        // The app opens a code block; in Markdown this line would be text with inline code.
        #expect(export("```ls -la```\n本文 *a*\n```") == "```\nls -la```\n本文 *a*\n```")
        #expect(export("~~~ `x`\ncode\n~~~") == "```\n`x`\ncode\n```")
    }

    @Test func blankLinesKeepTheNesting() {
        #expect(export("- a\n\n\t- b") == "- a\n\t<empty-block/>\n\t- b")
        #expect(export("- [ ] a\n\n\t- [ ] b") == "- [ ] a\n\t<empty-block/>\n\t- [ ] b")
        #expect(export("- a\n\n  続き") == "- a\n\t<empty-block/>\n\t続き")
        #expect(export("- a\n\nb") == "- a\n<empty-block/>\nb")
        #expect(export("# 見出し\n\n\t- a") == "# 見出し\n<empty-block/>\n- a")
    }

    @Test func dividers() {
        // Only dashes make a divider, as in Notion; "***" and "_ _ _" stay text (escaped for Notion).
        #expect(export("上\n---\n- - -\n***\n_ _ _\n下") == "上\n---\n---\n\\*\\*\\*\n\\_ _ _\n下")
    }

    @Test func plainTextIsEscapedButSyntaxAndCodeAreNot() {
        #expect(export("価格は $5、{a} | b <c> ^d ~e [f] \\g") ==
                "価格は \\$5、\\{a\\} \\| b \\<c\\> \\^d \\~e \\[f\\] \\\\g")
        #expect(export("`$x | {y} <z>` と $") == "`$x | {y} <z>` と \\$")
        #expect(export("**太字** と *斜体* と ~~取り消し~~") == "**太字** と *斜体* と ~~取り消し~~")
        #expect(export("2 * 3 = 6") == "2 \\* 3 = 6")
        #expect(export("[リンク$](https://example.com/a?b=$c&d={e})") == "[リンク\\$](https://example.com/a?b=$c&d={e})")
        #expect(export("# 見出しの $ と `$`") == "# 見出しの \\$ と `$`")
        #expect(export("- 項目の <tag>") == "- 項目の \\<tag\\>")
    }

    @Test func blockSyntaxThatTheAppShowsAsTextStaysText() {
        // Headings and dividers take at most three spaces of indentation in the app.
        #expect(export("    # 見出しではない") == "\\# 見出しではない")
        #expect(export("本文\n\t# タブ付き") == "本文\n\t\\# タブ付き")
        #expect(export("    ---") == "\\---")
        #expect(export("    ___") == "\\___")
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

    @Test func underscoreEmphasisBecomesStars() {
        // The format only has *italic* and **bold**.
        #expect(export("__太字__ と _斜体_") == "**太字** と *斜体*")
        #expect(export("snake__case__name") == "snake**case**name") // bold in the app, so bold in Notion
        #expect(export("snake_case_name") == "snake_case_name")     // text in both
        #expect(export("[a_b](https://example.com/a_b_c)") == "[a_b](https://example.com/a_b_c)")
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
        #expect(export("$$\nE = mc^2\n$$") == "\\$\\$\nE = mc\\^2\n\\$\\$")
        #expect(export("<callout>中身</callout>") == "\\<callout\\>中身\\</callout\\>")
        #expect(export("見出し {color=\"blue\"}") == "見出し \\{color=\"blue\"\\}")
        #expect(export("| a | b |") == "\\| a \\| b \\|")
    }

    // MARK: fromNotion

    @Test func importReversesTheSpecialForms() {
        #expect(NotionMarkdown.fromNotion("a\n<empty-block/>\nb") == "a\n\nb")
        #expect(NotionMarkdown.fromNotion("> 一<br>二<br><br>四") == "> 一\n> 二\n>\n> 四")
        #expect(NotionMarkdown.fromNotion("行1<br>行2") == "行1\n行2")
        #expect(NotionMarkdown.fromNotion("\\$5 \\{a\\} \\| \\<b\\> \\\\ \\*") == "$5 {a} | <b> \\ *")
        #expect(NotionMarkdown.fromNotion("`\\$ stays` と \\$") == "`\\$ stays` と $")
        #expect(NotionMarkdown.fromNotion("```\n\\$ stays\n<empty-block/>\n```") == "```\n\\$ stays\n<empty-block/>\n```")
        #expect(NotionMarkdown.fromNotion("[https://a.b/\\~c](https://a.b/~c) と [ラベル\\*](https://a.b)") ==
                "https://a.b/~c と [ラベル*](https://a.b)")
        #expect(NotionMarkdown.fromNotion("- [ ] a\n\t- [x] b") == "- [ ] a\n\t- [x] b")
        #expect(NotionMarkdown.fromNotion("<callout icon=\"💡\">\n\t中身\n</callout>") == "<callout icon=\"💡\">\n\t中身\n</callout>")
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
        ]
        for note in unchanged {
            #expect(NotionMarkdown.fromNotion(export(note)) == note)
        }

        let original = "* 項目\n  + 子\n1) 一\n##### 小見出し\n  > 引用\n- [X] 完了\n- - -\n\n\n"
        let normalized = "- 項目\n\t- 子\n1. 一\n#### 小見出し\n> 引用\n- [x] 完了\n---"
        #expect(NotionMarkdown.fromNotion(export(original)) == normalized)
        #expect(export(normalized) == export(original))
    }

    @Test func detectsNotionOnlyElements() {
        func kinds(_ markdown: String) -> [String] { NotionMarkdown.notionOnlyElements(in: markdown) }
        #expect(kinds("# 見出し\n- [ ] a\n> 引用\n**太字** `code` [x](https://a.b)\n価格は\\$5 と \\$6").isEmpty)
        #expect(kinds("<details>\n<summary>開く</summary>\n\t中身\n</details>") == ["トグル"])
        #expect(kinds("# 見出し {toggle=\"true\"}") == ["トグル"])
        #expect(kinds("<table header-row=\"true\">\n\t<tr><td>a</td></tr>\n</table>") == ["表"])
        #expect(kinds("![写真](https://a.b/c.png)") == ["画像・ファイル"])
        #expect(kinds("<mention-user url=\"u\">Ada</mention-user>") == ["メンション"])
        #expect(kinds("段落 {color=\"blue\"}") == ["文字色・下線"])
        #expect(kinds("$$\nE=mc^2\n$$") == ["数式"])
        #expect(kinds("インライン $x^2$ の式") == ["数式"])
        #expect(kinds("```html\n<callout>コードの中</callout>\n```").isEmpty)
    }
}
