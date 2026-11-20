import AppKit
import Testing
@testable import FusenCore

/// Cards, rows of cards and signals in Notion: callouts, columns and colored to-dos, in the
/// Notion-flavored Markdown ("v2") the app sends and reads (see NotionMarkdown). In it a callout's
/// children are not indented, a blank line follows its own text, and a color is an attribute of the
/// block's tag.
@MainActor
struct NotionCardTests {
    let styler = MarkdownStyler()

    private func export(_ text: String) -> String { NotionMarkdown.export(text, styler: styler) }
    private func fromNotion(_ markdown: String) -> String { NotionMarkdown.fromNotion(markdown) }

    // MARK: To Notion

    @Test func aCardIsACalloutInItsColor() {
        #expect(export(":::card orange プロジェクトA\n- [/] 進行中\n- [>] 待機\n- [ ] 未着手\n- [x] 完了\n:::") == """
        <callout icon="📌" color="orange_bg">
        <b>プロジェクトA</b>

        <todo checked="false" color="blue">
        進行中
        </todo>

        <todo checked="false" color="yellow">
        待機
        </todo>

        - [ ] 未着手
        - [x] 完了
        </callout>
        """)
        // The default color is no color.
        #expect(export(":::card default 名前\n:::") == "<callout icon=\"📌\">\n<b>名前</b>\n</callout>")
        #expect(export(":::card 名前\n:::") == "<callout icon=\"📌\">\n<b>名前</b>\n</callout>")
        // The title is text: what Notion would read as syntax is escaped.
        #expect(export(":::card red a*b <c> _d_\n:::") == "<callout icon=\"📌\" color=\"red_bg\">\n<b>a\\*b \\<c> \\_d\\_</b>\n</callout>")
    }

    @Test func aCardWithoutATitleStartsWithItsText() {
        // As a callout written in Notion does: its first paragraph is the callout's own text.
        #expect(export(":::card blue\n本文\n:::") == "<callout icon=\"📌\" color=\"blue_bg\">\n本文\n</callout>")
        #expect(export(":::card blue\n本文\n- 項目\n:::") == "<callout icon=\"📌\" color=\"blue_bg\">\n本文\n\n- 項目\n</callout>")
        #expect(export(":::card green \n:::") == "<callout icon=\"📌\" color=\"green_bg\">\n</callout>")
        // Anything else cannot be the callout's own text: that is an empty paragraph then, and the
        // card's text follows as children. So does a paragraph that would come back as a title, or
        // that has children of its own.
        #expect(export(":::card red \n- 項目\n:::") == "<callout icon=\"📌\" color=\"red_bg\">\n<p />\n\n- 項目\n</callout>")
        #expect(export(":::card red \n\n本文\n:::") == "<callout icon=\"📌\" color=\"red_bg\">\n<p />\n\n<p />\n\n本文\n</callout>")
        #expect(export(":::card red \n**太字だけ**\n:::") == "<callout icon=\"📌\" color=\"red_bg\">\n<p />\n\n<b>太字だけ</b>\n</callout>")
        #expect(export(":::card red \n本文\n\t子\n:::") == "<callout icon=\"📌\" color=\"red_bg\">\n<p />\n\n<p>\n本文\n\n子\n</p>\n</callout>")
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
        // Not indented, also not the code block; blank lines at the end of a card are dropped.
        #expect(export(note) == """
        前

        <callout icon="📌" color="purple_bg">
        <b>計画</b>

        # 見出し

        - 親
          - 子

        1. 番号

        <p />

        > 引用<br />二行目

        ---

        ```swift
        let x = 1
        ```
        </callout>

        後
        """)
        // Blank lines before a card stay outside it.
        #expect(export("前\n\n:::card 名前\n:::\n\n後") == "前\n\n<p />\n\n<callout icon=\"📌\">\n<b>名前</b>\n</callout>\n\n<p />\n\n後")
    }

    @Test func cardsSideBySideAreColumns() {
        #expect(export("::::columns\n:::card orange A\n- [/] 一\n:::\n:::card purple B\n二\n:::\n::::\n後") == """
        <columns>
        <column>
        <callout icon="📌" color="orange_bg">
        <b>A</b>

        <todo checked="false" color="blue">
        一
        </todo>
        </callout>
        </column>
        <column>
        <callout icon="📌" color="purple_bg">
        <b>B</b>

        二
        </callout>
        </column>
        </columns>

        後
        """)
    }

    @Test func linesThatAreNotCardsStayText() {
        // An opening line without its closing line, and the lines of a row that is not one.
        #expect(export(":::card orange A\n本文") == ":::card orange A\n\n本文")
        #expect(export("::::columns\n本文\n::::") == "::::columns\n\n本文\n\n::::")
    }

    @Test func aWaitingToDoIsYellowAndAnOrangeOneFromBeforeIsWaitingToo() {
        #expect(fromNotion("<todo checked=\"false\" color=\"yellow\">\n次\n</todo>") == "- [>] 次")
        #expect(fromNotion("<todo checked=\"false\" color=\"yellow_bg\">\n次\n</todo>") == "- [>] 次")
        #expect(fromNotion("<todo checked=\"false\" color=\"orange\">\n前の版\n</todo>") == "- [>] 前の版")
        #expect(NotionMarkdown.signal(forColor: "red") == nil && NotionMarkdown.signal(forColor: nil) == nil)
    }

    @Test func aSignalIsAToDoTagInItsColor() {
        // A color is an attribute, so a signal is always written as a tag; other to-dos stay Markdown.
        #expect(export("- [/] 進行中\n- [>] 待機\n- [ ] 未着手") ==
                "<todo checked=\"false\" color=\"blue\">\n進行中\n</todo>\n\n<todo checked=\"false\" color=\"yellow\">\n待機\n</todo>\n\n- [ ] 未着手")
        #expect(export("- [/] ") == "<todo checked=\"false\" color=\"blue\">\n</todo>") // no text yet
        // What is nested in a signal, or holds one, is written between the tags of its parent.
        #expect(export("- [/] 親\n\t- [ ] 子\n\t\t- 孫") == "<todo checked=\"false\" color=\"blue\">\n親\n\n- [ ] 子\n  - 孫\n</todo>")
        #expect(export("- [ ] 親\n\t- [>] 子") == "<todo checked=\"false\">\n親\n\n<todo checked=\"false\" color=\"yellow\">\n子\n</todo>\n</todo>")
        #expect(export("- 親\n\t- [/] 子") == "<ul>\n<li>\n親\n\n<todo checked=\"false\" color=\"blue\">\n子\n</todo>\n</li>\n</ul>")
        // Braces the note itself has are text; this format has no syntax in them.
        #expect(export("- [ ] 文字 {color=\"blue\"}") == "- [ ] 文字 {color=\"blue\"}")
    }

    // MARK: From Notion

    @Test func whatTheAppSentComesBackUnchanged() {
        for note in [
            ":::card orange プロジェクトA\n- [/] 進行中\n- [>] 待機\n- [ ] 未着手\n- [x] 完了\n:::",
            "前\n:::card default 名前\n本文\n:::\n後",
            ":::card blue \n本文\n:::",
            ":::card blue \n本文\n- 項目\n\n最後\n:::",
            ":::card red a*b <c> {d} _e_ &amp;\n- 項目\n\t- 子\n:::",
            ":::card purple 計画\n# 見出し\n\n> 引用\n> 二行目\n---\n```swift\nlet x = 1\n```\n:::\n後",
            "::::columns\n:::card orange A\n- [/] 一\n:::\n:::card purple B\n二\n:::\n::::\n後",
            "- [/] 外の進行中\n\t- [>] 子の待機\n本文",
            "- [ ] 親\n\t- [/] 子\n\t\t- 孫\n\t- [ ] 子2\n- 箇条書き\n\t- [>] 待機\n1. 番号\n\t- [/] 進行中",
            "- [/] \n- [>] \n- [ ] 文字 {color=\"blue\"}",
            ":::card green \n:::",
            ":::card red \n- 項目\n:::",
            ":::card red \n\n本文\n:::",
            ":::card red \n**太字だけ**\n:::",
            ":::card red \n本文\n\t子\n:::",
        ] {
            #expect(fromNotion(export(note)) == note, "\(export(note))")
            #expect(NotionMarkdown.notionOnlyElements(in: export(note)).isEmpty, "\(note)")
        }
        // Written without a color, the default one comes back written out.
        #expect(fromNotion(export(":::card 名前\n:::")) == ":::card default 名前\n:::")
    }

    @Test func aCalloutMadeInNotionIsACard() {
        // Its color is the card's (a text color too); the icon is not kept. Its own text is the card's
        // title if it is all bold (as the app sends titles), otherwise the first line of the card's text.
        #expect(fromNotion("<callout icon=\"💡\" color=\"blue_bg\">\nメモ\n\n- 項目\n  - 子\n</callout>") == ":::card blue \nメモ\n- 項目\n\t- 子\n:::")
        #expect(fromNotion("<callout icon=\"💡\" color=\"green\">\n<b>太字の名前</b>\n</callout>") == ":::card green 太字の名前\n:::")
        #expect(fromNotion("<callout icon=\"💡\" color=\"green\">\n**太字の名前**\n</callout>") == ":::card green 太字の名前\n:::")
        #expect(fromNotion("<callout icon=\"💡\">\n<b>太字</b>と本文\n</callout>") == ":::card default \n**太字**と本文\n:::")
        #expect(fromNotion("<callout icon=\"💡\">\n<b><i>斜体の太字</i></b>\n</callout>") == ":::card default \n***斜体の太字***\n:::")
        // An escaped character in a title is that character.
        #expect(fromNotion("<callout icon=\"💡\">\n<b>a\\*b \\<c> &amp; d</b>\n</callout>") == ":::card default a*b <c> & d\n:::")
        // Without text of its own (an empty paragraph), what it holds is the card's text.
        #expect(fromNotion("<callout icon=\"💡\">\n<p />\n\n<todo checked=\"false\" color=\"orange\">\n最初からタスク\n</todo>\n</callout>") == ":::card default \n- [>] 最初からタスク\n:::")
        #expect(fromNotion("<callout icon=\"💡\">\n- [ ] 最初からタスク\n</callout>") == ":::card default \n- [ ] 最初からタスク\n:::")
        #expect(fromNotion("<callout>\n</callout>") == ":::card default \n:::")
        // A color the app has no card for: the default one.
        #expect(fromNotion("<callout icon=\"💡\" color=\"teal_bg\">\n<b>名前</b>\n</callout>") == ":::card default 名前\n:::")
        // A callout in a callout stays as it came: cards do not nest.
        let nested = "<callout icon=\"💡\">\n外\n\n<callout icon=\"💡\">\n中\n</callout>\n</callout>"
        #expect(fromNotion(nested) == ":::card default \n外\n<callout icon=\"💡\">\n中\n</callout>\n:::")
        #expect(NotionMarkdown.notionOnlyElements(in: nested) == ["コールアウト"])
        // A callout nested in another block is a card too (cards stand at the start of their lines).
        #expect(fromNotion("<ul>\n<li>\n項目\n\n<callout icon=\"💡\" color=\"pink_bg\">\n中\n</callout>\n</li>\n</ul>") == "- 項目\n:::card pink \n中\n:::")
        // In a code block nothing is a callout.
        #expect(fromNotion("```\n<callout>\n</callout>\n```") == "```\n<callout>\n</callout>\n```")
        // A callout that is never closed stays as it came.
        #expect(fromNotion("<callout icon=\"💡\">\n本文") == "<callout icon=\"💡\">\n本文")
    }

    @Test func columnsOfCalloutsAreARowOfCards() {
        // Notion may give a column its share of the width, and may leave blank lines between the tags.
        let columns = """
        <columns>
        <column ratio="50">
        <callout icon="💡" color="orange_bg">
        A

        一
        </callout>
        </column>

        <column ratio="50">
        <callout icon="💡">
        B
        </callout>
        </column>
        </columns>
        """
        #expect(fromNotion(columns) == "::::columns\n:::card orange \nA\n一\n:::\n:::card default \nB\n:::\n::::")
        #expect(NotionMarkdown.notionOnlyElements(in: columns).isEmpty)
        // Other columns: what they hold comes one below the other, and the note says so.
        let mixed = """
        <columns>
        <column>
        左の本文

        - 項目
        </column>
        <column>
        <callout icon="💡" color="pink_bg">
        B
        </callout>

        右の本文
        </column>
        </columns>

        後
        """
        #expect(fromNotion(mixed) == "左の本文\n- 項目\n:::card pink \nB\n:::\n右の本文\n後")
        #expect(NotionMarkdown.notionOnlyElements(in: mixed) == ["段組み"])
        // Columns in a card stay as they came.
        let inCard = "<callout icon=\"💡\">\n名前\n\n<columns>\n<column>\n左\n</column>\n<column>\n右\n</column>\n</columns>\n</callout>"
        #expect(fromNotion(inCard) == ":::card default \n名前\n<columns>\n<column>\n左\n</column>\n<column>\n右\n</column>\n</columns>\n:::")
        #expect(NotionMarkdown.notionOnlyElements(in: inCard) == ["段組み"])
    }

    @Test func aToDoInASignalsColorIsThatSignal() {
        // As a text color or as a background.
        #expect(fromNotion("<todo checked=\"false\" color=\"blue\">\n進行中\n</todo>\n\n<todo checked=\"false\" color=\"orange_bg\">\n待機\n\n<todo checked=\"false\" color=\"blue_bg\">\n子\n</todo>\n</todo>")
                == "- [/] 進行中\n- [>] 待機\n\t- [/] 子")
        #expect(fromNotion("<todo checked=\"false\" color=\"blue\">\n</todo>") == "- [/] ")
        #expect(NotionMarkdown.notionOnlyElements(in: "<todo checked=\"false\" color=\"blue\">\n進行中\n</todo>").isEmpty)
        // A to-do written as a tag without a color is a to-do, with what is nested in it.
        #expect(fromNotion("<todo checked=\"false\">\n親\n\n- [x] 子\n</todo>\n\n<todo checked=\"true\">\n済み\n</todo>") == "- [ ] 親\n\t- [x] 子\n- [x] 済み")
        // A checked one is done, and other colors are not signals: the color is one the app cannot
        // show, so the two lines of the tag stay, as text, around the to-do.
        #expect(fromNotion("<todo checked=\"true\" color=\"blue\">\n済み\n</todo>") == "<todo checked=\"true\" color=\"blue\">\n- [x] 済み\n</todo>")
        #expect(fromNotion("<todo checked=\"false\" color=\"red\">\n赤\n</todo>") == "<todo checked=\"false\" color=\"red\">\n- [ ] 赤\n</todo>")
        #expect(NotionMarkdown.notionOnlyElements(in: "<todo checked=\"false\" color=\"red\">\n赤\n</todo>") == ["文字色・下線"])
        #expect(fromNotion("<ul>\n<li color=\"blue\">\n箇条書き\n</li>\n</ul>") == "<li color=\"blue\">\n- 箇条書き\n</li>")
        // The older format's color syntax means nothing in this one: it is the text it looks like.
        #expect(fromNotion("- [ ] 文字 {color=\"blue\"}") == "- [ ] 文字 {color=\"blue\"}")
        #expect(NotionMarkdown.notionOnlyElements(in: "- [ ] 文字 {color=\"blue\"}").isEmpty)
    }
}
