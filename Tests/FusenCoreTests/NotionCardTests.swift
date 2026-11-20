import AppKit
import Testing
@testable import FusenCore

/// Cards, rows of cards and signals in Notion: callouts, columns and colored to-dos (the "enhanced
/// markdown" the app sends and reads, see NotionMarkdown).
@MainActor
struct NotionCardTests {
    let styler = MarkdownStyler()

    private func export(_ text: String) -> String { NotionMarkdown.export(text, styler: styler) }
    private func fromNotion(_ markdown: String) -> String { NotionMarkdown.fromNotion(markdown) }

    // MARK: To Notion

    @Test func aCardIsACalloutInItsColor() {
        #expect(export(":::card orange プロジェクトA\n- [/] 進行中\n- [>] 待機\n- [ ] 未着手\n:::") == """
        <callout icon="📌" color="orange_bg">
        \t**プロジェクトA**
        \t- [ ] 進行中 {color="blue"}
        \t- [ ] 待機 {color="orange"}
        \t- [ ] 未着手
        </callout>
        """)
        // The default color is no color; without a title the callout starts with its text.
        #expect(export(":::card default 名前\n:::") == "<callout icon=\"📌\">\n\t**名前**\n</callout>")
        #expect(export(":::card 名前\n:::") == "<callout icon=\"📌\">\n\t**名前**\n</callout>")
        #expect(export(":::card blue\n本文\n:::") == "<callout icon=\"📌\" color=\"blue_bg\">\n\t本文\n</callout>")
        // The title is text: what Notion would read as syntax is escaped.
        #expect(export(":::card red a*b <c>\n:::") == "<callout icon=\"📌\" color=\"red_bg\">\n\t**a\\*b \\<c\\>**\n</callout>")
    }

    @Test func aCardsTextIsTheCalloutsChildren() {
        let note = """
        前
        :::card purple 計画
        # 見出し
        - 親
        \t- 子
        1. 番号

        > 引用
        > 二行目
        ---
        ```swift
        let x = 1
        ```

        :::
        後
        """
        #expect(export(note) == """
        前
        <callout icon="📌" color="purple_bg">
        \t**計画**
        \t# 見出し
        \t- 親
        \t\t- 子
        \t1. 番号
        \t<empty-block/>
        \t> 引用<br>二行目
        \t---
        \t```swift
        \tlet x = 1
        \t```
        </callout>
        後
        """)
        // Blank lines before a card stay outside it.
        #expect(export("前\n\n:::card 名前\n:::\n\n後") == "前\n<empty-block/>\n<callout icon=\"📌\">\n\t**名前**\n</callout>\n<empty-block/>\n後")
    }

    @Test func cardsSideBySideAreColumns() {
        #expect(export("::::columns\n:::card orange A\n- [/] 一\n:::\n:::card purple B\n二\n:::\n::::\n後") == """
        <columns>
        \t<column>
        \t\t<callout icon="📌" color="orange_bg">
        \t\t\t**A**
        \t\t\t- [ ] 一 {color="blue"}
        \t\t</callout>
        \t</column>
        \t<column>
        \t\t<callout icon="📌" color="purple_bg">
        \t\t\t**B**
        \t\t\t二
        \t\t</callout>
        \t</column>
        </columns>
        後
        """)
    }

    @Test func linesThatAreNotCardsStayText() {
        // An opening line without its closing line, and the lines of a row that is not one.
        #expect(export(":::card orange A\n本文") == ":::card orange A\n本文")
        #expect(export("::::columns\n本文\n::::") == "::::columns\n本文\n::::")
    }

    // MARK: From Notion

    @Test func whatTheAppSentComesBackUnchanged() {
        for note in [
            ":::card orange プロジェクトA\n- [/] 進行中\n- [>] 待機\n- [ ] 未着手\n- [x] 完了\n:::",
            "前\n:::card default 名前\n本文\n:::\n後",
            ":::card blue \n本文\n:::",
            ":::card red a*b <c> {d}\n- 項目\n\t- 子\n:::",
            ":::card purple 計画\n# 見出し\n\n> 引用\n> 二行目\n---\n```swift\nlet x = 1\n```\n:::\n後",
            "::::columns\n:::card orange A\n- [/] 一\n:::\n:::card purple B\n二\n:::\n::::\n後",
            "- [/] 外の進行中\n\t- [>] 子の待機\n本文",
            ":::card green \n:::",
        ] {
            #expect(fromNotion(export(note)) == note, "\(note)")
            #expect(NotionMarkdown.notionOnlyElements(in: export(note)).isEmpty, "\(note)")
        }
        // Written without a color, the default one comes back written out.
        #expect(fromNotion(export(":::card 名前\n:::")) == ":::card default 名前\n:::")
    }

    @Test func aCalloutMadeInNotionIsACard() {
        // Its color is the card's (a text color too); the icon is not kept. Its own text is the card's
        // title if it is all bold (as the app sends titles), otherwise the first line of the card's text.
        #expect(fromNotion("<callout icon=\"💡\" color=\"blue_bg\">\n\tメモ\n\t- 項目\n\t\t- 子\n</callout>") == ":::card blue \nメモ\n- 項目\n\t- 子\n:::")
        #expect(fromNotion("<callout icon=\"💡\" color=\"green\">\n\t**太字の名前**\n</callout>") == ":::card green 太字の名前\n:::")
        #expect(fromNotion("<callout icon=\"💡\">\n\t**太字**と本文\n</callout>") == ":::card default \n**太字**と本文\n:::")
        #expect(fromNotion("<callout icon=\"💡\">\n\t- [ ] 最初からタスク {color=\"orange\"}\n</callout>") == ":::card default \n- [>] 最初からタスク\n:::")
        #expect(fromNotion("<callout>\n</callout>") == ":::card default \n:::")
        // A color the app has no card for: the default one.
        #expect(fromNotion("<callout icon=\"💡\" color=\"teal_bg\">\n\t**名前**\n</callout>") == ":::card default 名前\n:::")
        // A callout in a callout stays as it came: cards do not nest.
        let nested = "<callout icon=\"💡\">\n\t外\n\t<callout icon=\"💡\">\n\t\t中\n\t</callout>\n</callout>"
        #expect(fromNotion(nested) == ":::card default \n外\n<callout icon=\"💡\">\n\t中\n</callout>\n:::")
        #expect(NotionMarkdown.notionOnlyElements(in: nested) == ["コールアウト"])
        // In a code block nothing is a callout.
        #expect(fromNotion("```\n<callout>\n</callout>\n```") == "```\n<callout>\n</callout>\n```")
        // A callout that is never closed stays as it came.
        #expect(fromNotion("<callout icon=\"💡\">\n\t本文") == "<callout icon=\"💡\">\n\t本文")
    }

    @Test func columnsOfCalloutsAreARowOfCards() {
        let columns = """
        <columns>
        \t<column>
        \t\t<callout icon="💡" color="orange_bg">
        \t\t\tA
        \t\t\t一
        \t\t</callout>
        \t</column>
        \t<column>
        \t\t<callout icon="💡">
        \t\t\tB
        \t\t</callout>
        \t</column>
        </columns>
        """
        #expect(fromNotion(columns) == "::::columns\n:::card orange \nA\n一\n:::\n:::card default \nB\n:::\n::::")
        #expect(NotionMarkdown.notionOnlyElements(in: columns).isEmpty)
        // Other columns: what they hold comes one below the other, and the note says so.
        let mixed = """
        <columns>
        \t<column>
        \t\t左の本文
        \t\t- 項目
        \t</column>
        \t<column>
        \t\t<callout icon="💡" color="pink_bg">
        \t\t\tB
        \t\t</callout>
        \t\t右の本文
        \t</column>
        </columns>
        後
        """
        #expect(fromNotion(mixed) == "左の本文\n- 項目\n:::card pink \nB\n:::\n右の本文\n後")
        #expect(NotionMarkdown.notionOnlyElements(in: mixed) == ["段組み"])
    }

    @Test func aToDoInASignalsColorIsThatSignal() {
        #expect(fromNotion("- [ ] 進行中 {color=\"blue\"}\n- [ ] 待機 {color=\"orange_bg\"}\n\t- [ ] 子 {color=\"blue_bg\"}")
                == "- [/] 進行中\n- [>] 待機\n\t- [/] 子")
        #expect(fromNotion("- [ ] {color=\"blue\"}") == "- [/] ")
        // A checked one is done; other colors and other blocks are not signals.
        #expect(fromNotion("- [x] 済み {color=\"blue\"}") == "- [x] 済み {color=\"blue\"}")
        #expect(fromNotion("- [ ] 赤 {color=\"red\"}") == "- [ ] 赤 {color=\"red\"}")
        #expect(fromNotion("- 箇条書き {color=\"blue\"}") == "- 箇条書き {color=\"blue\"}")
        #expect(NotionMarkdown.notionOnlyElements(in: "- [ ] 進行中 {color=\"blue\"}").isEmpty)
        #expect(NotionMarkdown.notionOnlyElements(in: "- [ ] 赤 {color=\"red\"}") == ["文字色・下線"])
        // Braces the note itself has are text: the app escapes them when it sends them.
        #expect(export("- [ ] 文字 {color=\"blue\"}") == "- [ ] 文字 \\{color=\"blue\"\\}")
        #expect(fromNotion(export("- [ ] 文字 {color=\"blue\"}")) == "- [ ] 文字 {color=\"blue\"}")
    }
}
