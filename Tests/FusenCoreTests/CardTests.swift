import AppKit
import Testing
@testable import FusenCore

/// Cards: ":::card <color> <title>" … ":::". (ConcealedEditor is in ConcealmentTests, TestNote in
/// NoteFocusTests.)
@MainActor
struct CardTests {
    private let theme = MarkdownTheme()
    private let sample = "本文\n:::card orange プロジェクトA\n- [/] 進行中のタスク\n- [>] 待機のタスク\n:::\nおわり"

    private func kind(_ e: ConcealedEditor, _ text: String) -> MarkdownLine {
        ConcealedEditing.line(at: e.index(of: text), in: e.storage).kind
    }

    // MARK: Markdown

    @Test func aCardIsItsTwoLinesAndTheTextBetweenThem() {
        let e = ConcealedEditor(sample)
        #expect(kind(e, ":::card") == .cardOpen)
        #expect(kind(e, "進行中") == .task)                       // the lines between keep their kinds
        #expect(kind(e, ":::\nおわり") == .cardClose)
        #expect(kind(e, "おわり") == .text)
        let card = NSRange(location: e.index(of: ":::card"), length: e.index(of: "おわり") - e.index(of: ":::card"))
        var run = NSRange()
        #expect(e.storage.attribute(.mdCard, at: e.index(of: "進行中"), longestEffectiveRange: &run,
                                    in: NSRange(location: 0, length: e.storage.length)) as? Int == 0)
        #expect(run == card)
        #expect(e.storage.attribute(.mdCardColor, at: card.location, effectiveRange: nil) as? String == "orange")
        #expect(e.storage.attribute(.mdCard, at: 0, effectiveRange: nil) == nil)
        #expect(e.storage.attribute(.mdCard, at: e.index(of: "おわり"), effectiveRange: nil) == nil)
        // The syntax is hidden; the title is shown.
        #expect(e.property(at: e.index(of: ":::card")) == .controlCharacter)  // a box of no width
        #expect(e.property(at: e.index(of: ":::card") + 1) == .null)
        #expect(e.property(at: e.index(of: "orange")) == .null)
        #expect(e.property(at: e.index(of: "プロジェクトA")) != .null)
        #expect(e.property(at: e.index(of: ":::\nおわり") + 1) == .null)
    }

    @Test func theColorAndTheTitle() {
        func parse(_ line: String) -> (CardColor, String, String) {
            let ns = line as NSString
            let parts = CardSyntax.parseOpen(ns, line: NSRange(location: 0, length: ns.length))
            return (parts.color, ns.substring(with: parts.prefix), ns.substring(with: parts.title))
        }
        #expect(parse(":::card orange プロジェクトA") == (.orange, ":::card orange ", "プロジェクトA"))
        #expect(parse(":::card purple") == (.purple, ":::card purple", ""))
        #expect(parse(":::card purple ") == (.purple, ":::card purple ", ""))
        #expect(parse(":::card") == (.default, ":::card", ""))
        #expect(parse(":::card プロジェクトA") == (.default, ":::card ", "プロジェクトA"))   // no color: the default one
        #expect(parse(":::card default orange") == (.default, ":::card default ", "orange"))
        #expect(parse(":::card  red  二つの 単語") == (.red, ":::card  red  ", "二つの 単語"))
        #expect(CardColor.allCases.count == 10)
        #expect(CardSyntax.openLine(color: .blue, title: "A") == ":::card blue A")
    }

    @Test func anOpeningLineWithoutItsClosingLineStaysText() {
        let e = ConcealedEditor("本文\n:::card orange プロジェクトA\n- [ ] タスク\nおわり")
        #expect(kind(e, ":::card") == .text)
        #expect(e.property(at: e.index(of: ":::card")) != .null)       // shown as typed
        #expect(e.storage.attribute(.mdCard, at: e.index(of: "タスク"), effectiveRange: nil) == nil)
        // Typing the closing line makes the card.
        e.click((e.text as NSString).length)
        e.type("\n:::")
        #expect(kind(e, ":::card") == .cardOpen)
        #expect(e.storage.attribute(.mdCard, at: e.index(of: "おわり"), effectiveRange: nil) != nil)
    }

    @Test func cardsDoNotNestAndStrayLinesAreText() {
        // A second opening line before the first is closed: the first one is text.
        let e = ConcealedEditor(":::card orange A\n:::card purple B\n中身\n:::\n:::")
        #expect(ConcealedEditing.line(at: 0, in: e.storage).kind == .text)
        #expect(kind(e, ":::card purple") == .cardOpen)
        #expect(e.storage.attribute(.mdCardColor, at: e.index(of: "中身"), effectiveRange: nil) as? String == "purple")
        #expect(ConcealedEditing.line(at: (e.text as NSString).length, in: e.storage).kind == .text) // the stray ":::"
        // "::::" and ":::cards" are not card lines.
        let other = ConcealedEditor(":::cards\n::::\n:::card\n::::\n:::")
        #expect(ConcealedEditing.line(at: 0, in: other.storage).kind == .text)
        #expect(ConcealedEditing.line(at: other.index(of: ":::card\n"), in: other.storage).kind == .cardOpen)
    }

    @Test func nothingInACodeBlockIsACard() {
        let e = ConcealedEditor("```\n:::card orange A\n:::\n```\n:::card blue B\n```\n:::\n```\n:::")
        #expect(kind(e, ":::card orange") == .code)
        #expect(kind(e, ":::card blue") == .cardOpen)
        // The ":::" inside the card's code block does not close the card; the last line does.
        #expect(e.storage.attribute(.mdCard, at: (e.text as NSString).length - 1, effectiveRange: nil) as? Int == 0)
        #expect(ConcealedEditing.line(at: e.index(of: ":::\n```\n:::"), in: e.storage).kind == .code)
    }

    @Test func twoCardsInARowAreTwoCards() {
        let e = ConcealedEditor(":::card orange A\n一\n:::\n:::card purple B\n二\n:::")
        #expect(e.storage.attribute(.mdCard, at: e.index(of: "一"), effectiveRange: nil) as? Int == 0)
        #expect(e.storage.attribute(.mdCard, at: e.index(of: "二"), effectiveRange: nil) as? Int == 1)
        #expect(e.layoutManager.cardGeometries().map(\.color) == [.orange, .purple])
    }

    // MARK: The caret

    private func end(_ e: ConcealedEditor, _ text: String) -> Int { e.index(of: text) + (text as NSString).length }

    @Test func theCaretNeverStopsOnTheLinesAroundACard() {
        let e = ConcealedEditor(sample)
        let title = e.index(of: "プロジェクトA"), lastEnd = end(e, "待機のタスク"), after = e.index(of: "おわり")
        // → from the end of the card's text passes the closing line; ← comes back.
        e.click(lastEnd)
        e.key { e.textView.moveRight(nil) }
        #expect(e.caret == after)
        e.key { e.textView.moveLeft(nil) }
        #expect(e.caret == lastEnd)
        // ← from the start of the title goes to the line above (the opening line's syntax is hidden).
        e.click(title)
        e.key { e.textView.moveLeft(nil) }
        #expect(e.caret == end(e, "本文"))
        e.key { e.textView.moveRight(nil) }
        #expect(e.caret == title)
        // → from the end of the title goes to the first line of the text.
        e.click(end(e, "プロジェクトA"))
        e.key { e.textView.moveRight(nil) }
        #expect(e.caret == e.index(of: "進行中"))
        // A click that lands on a hidden line is moved to where text is.
        e.click(e.index(of: ":::card") + 3)
        #expect(e.caret == title)
        e.click(after)
        e.click(e.index(of: ":::\nおわり") + 1)
        #expect(e.caret == lastEnd)
    }

    @Test func upAndDownGoThroughTheCard() {
        let e = ConcealedEditor(sample)
        e.click(0)
        var seen: [Int] = []
        for _ in 0..<5 {
            e.key { e.textView.moveDown(nil) }
            seen.append(ConcealedEditing.line(at: e.caret, in: e.storage).range.location)
        }
        #expect(seen == [e.index(of: ":::card"), e.index(of: "- [/]"), e.index(of: "- [>]"), e.index(of: "おわり"), e.index(of: "おわり")])
        seen = []
        for _ in 0..<4 {
            e.key { e.textView.moveUp(nil) }
            seen.append(ConcealedEditing.line(at: e.caret, in: e.storage).range.location)
        }
        #expect(seen == [e.index(of: "- [>]"), e.index(of: "- [/]"), e.index(of: ":::card"), 0])
    }

    @Test func aCardThatEndsTheNoteKeepsTheCaretInside() {
        let e = ConcealedEditor("本文\n:::card blue A\n一行\n:::")
        e.click(end(e, "一行"))
        e.key { e.textView.moveRight(nil) }
        #expect(e.caret == end(e, "一行"))
        e.key { e.textView.moveDown(nil) }
        #expect(e.caret == end(e, "一行"))
        e.click((e.text as NSString).length)
        #expect(e.caret == end(e, "一行"))
    }

    // MARK: Return

    @Test func returnInTheTitleGoesOnToTheText() {
        // To the first line of the text if it is empty...
        let empty = ConcealedEditor(":::card default 名前\n\n:::\n")
        empty.click(end(empty, "名前"))
        empty.key { empty.textView.insertNewline(nil) }
        #expect(empty.text == ":::card default 名前\n\n:::\n")
        #expect(empty.caret == end(empty, "名前") + 1)
        // ...otherwise to a new line above it; also from the middle of the title, which is not split.
        let e = ConcealedEditor(sample)
        e.click(e.index(of: "ジェクトA"))
        e.key { e.textView.insertNewline(nil) }
        #expect(e.text == "本文\n:::card orange プロジェクトA\n\n- [/] 進行中のタスク\n- [>] 待機のタスク\n:::\nおわり")
        #expect(e.caret == end(e, "プロジェクトA") + 1)
        // A card without text gets its first line.
        let bare = ConcealedEditor(":::card blue 名前\n:::")
        bare.click(end(bare, "名前"))
        bare.key { bare.textView.insertNewline(nil) }
        #expect(bare.text == ":::card blue 名前\n\n:::")
        #expect(bare.caret == end(bare, "名前") + 1)
        bare.type("本文")
        #expect(bare.text == ":::card blue 名前\n本文\n:::")
    }

    @Test func returnAtTheStartOfATitleMakesALineAboveTheCard() {
        let e = ConcealedEditor(":::card orange 名前\n中身\n:::")
        e.click(e.index(of: "名前"))
        e.key { e.textView.insertNewline(nil) }
        #expect(e.text == "\n:::card orange 名前\n中身\n:::")
        #expect(e.caret == e.index(of: "名前"))
    }

    @Test func returnOnTheEmptyLastLineLeavesTheCard() {
        // The empty line goes, and the caret is on a new line after the card.
        let e = ConcealedEditor("本文\n:::card orange A\n一行\n\n:::\nおわり")
        e.click(e.index(of: "\n\n:::") + 1)
        e.key { e.textView.insertNewline(nil) }
        #expect(e.text == "本文\n:::card orange A\n一行\n:::\n\nおわり")
        #expect(e.caret == e.index(of: "\nおわり"))
        // An empty line after the card is used; at the end of the note one is made.
        let used = ConcealedEditor(":::card orange A\n一行\n\n:::\n\nおわり")
        used.click(used.index(of: "\n\n:::") + 1)
        used.key { used.textView.insertNewline(nil) }
        #expect(used.text == ":::card orange A\n一行\n:::\n\nおわり")
        #expect(used.caret == used.index(of: "\nおわり"))
        let last = ConcealedEditor(":::card orange A\n一行\n\n:::")
        last.click(last.index(of: "\n\n:::") + 1)
        last.key { last.textView.insertNewline(nil) }
        #expect(last.text == ":::card orange A\n一行\n:::\n")
        #expect(last.caret == (last.text as NSString).length)
        // The card's only line stays.
        let only = ConcealedEditor(":::card orange A\n\n:::")
        only.click(only.index(of: "\n\n:::") + 1)
        only.key { only.textView.insertNewline(nil) }
        #expect(only.text == ":::card orange A\n\n:::\n")
        #expect(only.caret == (only.text as NSString).length)
        // Typing, Return, Return: out of the card.
        let flow = ConcealedEditor(":::card orange A\n\n:::")
        flow.click(flow.index(of: "\n\n:::") + 1)
        flow.type("やること")
        flow.key { flow.textView.insertNewline(nil) }
        flow.key { flow.textView.insertNewline(nil) }
        flow.type("続き")
        #expect(flow.text == ":::card orange A\nやること\n:::\n続き")
        // In the middle of the text an empty line is an empty line.
        let middle = ConcealedEditor(":::card orange A\n一\n\n二\n:::")
        middle.click(middle.index(of: "\n\n二") + 1)
        middle.key { middle.textView.insertNewline(nil) }
        #expect(middle.text == ":::card orange A\n一\n\n\n二\n:::")
    }

    // MARK: Deleting

    @Test func backspaceAtTheStartOfTheTitleTakesTheCardAway() {
        let e = ConcealedEditor(sample)
        e.click(e.index(of: "プロジェクトA"))
        e.key { e.textView.deleteBackward(nil) }
        #expect(e.text == "本文\nプロジェクトA\n- [/] 進行中のタスク\n- [>] 待機のタスク\nおわり")
        #expect(e.caret == e.index(of: "プロジェクトA"))
        e.undo.undo()
        #expect(e.text == sample)
        // Without a title its line goes too; a card that ends the note leaves no empty line behind.
        let untitled = ConcealedEditor(":::card blue \n中身\n:::")
        untitled.click(untitled.index(of: "\n中身"))
        untitled.key { untitled.textView.deleteBackward(nil) }
        #expect(untitled.text == "中身")
        let empty = ConcealedEditor("前\n:::card blue \n:::\n後")
        empty.click(empty.index(of: "\n:::\n後"))
        empty.key { empty.textView.deleteBackward(nil) }
        #expect(empty.text == "前\n後")
    }

    @Test func backspaceNeverJoinsTextToTheLinesAroundACard() {
        // At the start of the first line of the text: the caret moves to the end of the title.
        let e = ConcealedEditor(":::card orange 名前\n一行目\n二行目\n:::\n後ろ")
        e.click(e.index(of: "一行目"))
        e.key { e.textView.deleteBackward(nil) }
        #expect(e.text == ":::card orange 名前\n一行目\n二行目\n:::\n後ろ")
        #expect(e.caret == end(e, "名前"))
        // At the start of the line after the card: to the end of the card's text.
        e.click(e.index(of: "後ろ"))
        e.key { e.textView.deleteBackward(nil) }
        #expect(e.text == ":::card orange 名前\n一行目\n二行目\n:::\n後ろ")
        #expect(e.caret == end(e, "二行目"))
        // Empty lines there go.
        let empty = ConcealedEditor(":::card orange 名前\n\n二行目\n:::\n\n後ろ")
        empty.click(empty.index(of: "\n二行目"))
        empty.key { empty.textView.deleteBackward(nil) }
        #expect(empty.text == ":::card orange 名前\n二行目\n:::\n\n後ろ")
        #expect(empty.caret == end(empty, "名前"))
        empty.click(empty.index(of: "\n後ろ"))
        empty.key { empty.textView.deleteBackward(nil) }
        #expect(empty.text == ":::card orange 名前\n二行目\n:::\n後ろ")
        #expect(empty.caret == end(empty, "二行目"))
        // The empty line that ends the note.
        let last = ConcealedEditor(":::card orange 名前\n中身\n:::\n")
        last.click((last.text as NSString).length)
        last.key { last.textView.deleteBackward(nil) }
        #expect(last.text == ":::card orange 名前\n中身\n:::")
        #expect(last.caret == end(last, "中身"))
        // The card's only line of text stays, empty.
        let only = ConcealedEditor(":::card orange 名前\n\n:::")
        only.click(only.index(of: "\n\n:::") + 1)
        only.key { only.textView.deleteBackward(nil) }
        #expect(only.text == ":::card orange 名前\n\n:::")
        #expect(only.caret == end(only, "名前"))
        // A list item there first becomes text, as everywhere.
        let item = ConcealedEditor(":::card orange 名前\n- 項目\n:::")
        item.click(item.index(of: "項目"))
        item.key { item.textView.deleteBackward(nil) }
        #expect(item.text == ":::card orange 名前\n項目\n:::")
    }

    @Test func deleteForwardLeavesTheCardWhole() {
        let text = "前\n:::card orange 名前\n一行目\n二行目\n:::\n後ろ"
        let e = ConcealedEditor(text)
        for needle in ["前", "名前", "二行目"] {
            e.click(end(e, needle))
            e.key { e.textView.deleteForward(nil) }
            #expect(e.text == text, "after \(needle)")
        }
        // Inside the text lines join as always.
        e.click(end(e, "一行目"))
        e.key { e.textView.deleteForward(nil) }
        #expect(e.text == "前\n:::card orange 名前\n一行目二行目\n:::\n後ろ")
        // An empty line above a card goes.
        let empty = ConcealedEditor("前\n\n:::card orange 名前\n中身\n:::")
        empty.click(2)
        empty.key { empty.textView.deleteForward(nil) }
        #expect(empty.text == "前\n:::card orange 名前\n中身\n:::")
        // ⌥⌫ and ⌘⌫ at those edges do not get past them either.
        let word = ConcealedEditor(text)
        word.click(word.index(of: "一行目"))
        word.key { word.textView.deleteWordBackward(nil) }
        word.click(word.index(of: "後ろ"))
        word.key { word.textView.deleteToBeginningOfLine(nil) }
        #expect(word.text == text)
    }

    @Test func aSelectionTakesACardWholeOrLeavesItsLinesAlone() {
        let e = ConcealedEditor(sample)
        let card = NSRange(location: e.index(of: ":::card"), length: e.index(of: "おわり") - e.index(of: ":::card"))
        // Inside the text: as selected.
        let inside = NSRange(location: e.index(of: "進行中"), length: e.index(of: "待機の") - e.index(of: "進行中"))
        e.textView.setSelectedRange(inside)
        #expect(e.textView.selectedRange() == inside)
        // Within the title: as selected.
        let title = NSRange(location: e.index(of: "プロジェクトA"), length: 5)
        e.textView.setSelectedRange(title)
        #expect(e.textView.selectedRange() == title)
        // From before the card into it, from the title into the text, from the text out of the card: the whole card.
        e.textView.setSelectedRange(NSRange(location: 1, length: e.index(of: "進行中") - 1))
        #expect(e.textView.selectedRange() == NSRange(location: 1, length: NSMaxRange(card) - 1))
        e.textView.setSelectedRange(NSRange(location: title.location, length: e.index(of: "進行中") - title.location))
        #expect(e.textView.selectedRange() == card)
        e.textView.setSelectedRange(NSRange(location: e.index(of: "待機の"), length: e.index(of: "わり") - e.index(of: "待機の")))
        #expect(e.textView.selectedRange() == NSRange(location: card.location, length: e.index(of: "わり") - card.location))
        // Deleting it deletes the card.
        e.textView.setSelectedRange(NSRange(location: title.location, length: e.index(of: "進行中") - title.location))
        e.key { e.textView.deleteBackward(nil) }
        #expect(e.text == "本文\nおわり")
        e.undo.undo()
        #expect(e.text == sample)
        // Everything selected: everything.
        e.textView.selectAll(nil)
        #expect(e.textView.selectedRange() == NSRange(location: 0, length: (sample as NSString).length))
    }

    @Test func typingInTheTitleAndTheText() {
        let e = ConcealedEditor(":::card orange \n\n:::")
        e.click(e.index(of: "\n\n:::"))
        e.type("名前")
        #expect(e.text == ":::card orange 名前\n\n:::")
        e.key { e.textView.insertNewline(nil) }
        e.type("[]買う")
        #expect(e.text == ":::card orange 名前\n- [ ] 買う\n:::")
        // Markdown in a title is not Markdown.
        let plain = ConcealedEditor(":::card orange **太字**\n\n:::")
        #expect(plain.property(at: plain.index(of: "**")) != .null)
        plain.click(plain.index(of: "太字"))
        plain.key { plain.textView.toggleBold(nil) }
        #expect(plain.text == ":::card orange **太字**\n\n:::")
    }

    // MARK: The card's commands

    private func item(_ tag: Int = 0, card location: Int? = nil) -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = tag
        item.representedObject = location
        return item
    }

    @Test func insertingACard() {
        // On an empty line: there. The caret is in the title.
        let e = ConcealedEditor("本文\n\nおわり")
        e.click(3)
        e.key { e.textView.insertCard(nil) }
        #expect(e.text == "本文\n:::card default \n\n:::\nおわり")
        #expect(e.caret == e.index(of: "\n\n:::"))
        e.type("名前")
        e.key { e.textView.insertNewline(nil) }
        e.type("中身")
        #expect(e.text == "本文\n:::card default 名前\n中身\n:::\nおわり")
        // On a line with text: below it.
        let below = ConcealedEditor("本文\nおわり")
        below.click(1)
        below.key { below.textView.insertCard(nil) }
        #expect(below.text == "本文\n:::card default \n\n:::\nおわり")
        // In an empty note, and at the end of one: with a line after the card.
        let empty = ConcealedEditor("")
        empty.key { empty.textView.insertCard(nil) }
        #expect(empty.text == ":::card default \n\n:::\n")
        let last = ConcealedEditor("本文")
        last.click(2)
        last.key { last.textView.insertCard(nil) }
        #expect(last.text == "本文\n:::card default \n\n:::\n")
        last.undo.undo()
        #expect(last.text == "本文")
        // In a card: after it.
        let nested = ConcealedEditor(":::card orange A\n中身\n:::\nおわり")
        nested.click(nested.index(of: "中身"))
        nested.key { nested.textView.insertCard(nil) }
        #expect(nested.text == ":::card orange A\n中身\n:::\n:::card default \n\n:::\nおわり")
        #expect(nested.layoutManager.cardGeometries().count == 2)
    }

    @Test func selectedLinesBecomeTheCardsText() {
        let e = ConcealedEditor("前\n- [ ] 一\n- [/] 二\n後")
        e.textView.setSelectedRange(NSRange(location: e.index(of: "一"), length: e.index(of: "二") - e.index(of: "一")))
        e.key { e.textView.insertCard(nil) }
        #expect(e.text == "前\n:::card default \n- [ ] 一\n- [/] 二\n:::\n後")
        #expect(e.caret == e.index(of: "\n- [ ] 一"))
        // Whole lines selected, up to the start of the next line.
        let lines = ConcealedEditor("一\n二\n三")
        lines.textView.setSelectedRange(NSRange(location: 0, length: 4))
        lines.key { lines.textView.insertCard(nil) }
        #expect(lines.text == ":::card default \n一\n二\n:::\n三")
    }

    @Test func theCardsMenuChangesItsColorAndTakesItAway() {
        let e = ConcealedEditor(sample)
        let location = e.index(of: ":::card")
        let menu = e.textView.cardMenu(forCardAt: location)
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title)
                == CardColor.allCases.map(\.title) + ["カードを解除", "カードを削除"])
        #expect(menu.items.first { $0.state == .on }?.title == CardColor.orange.title)
        // The color.
        let blue = CardColor.allCases.firstIndex(of: .blue)!
        e.key { e.textView.setCardColor(item(blue, card: location)) }
        #expect(e.text == "本文\n:::card blue プロジェクトA\n- [/] 進行中のタスク\n- [>] 待機のタスク\n:::\nおわり")
        #expect(e.layoutManager.cardGeometries().first?.color == .blue)
        // From the 書式 menu it is the card the caret is in.
        e.click(e.index(of: "待機"))
        e.key { e.textView.setCardColor(item(CardColor.allCases.firstIndex(of: .red)!)) }
        #expect(e.text.contains(":::card red プロジェクトA"))
        e.click(0)
        let outside = NSMenuItem(title: "", action: #selector(MarkdownTextView.setCardColor(_:)), keyEquivalent: "")
        #expect(!e.textView.validateUserInterfaceItem(outside))
        // A card written without a color gets one.
        let plain = ConcealedEditor(":::card 名前\n\n:::")
        plain.key { plain.textView.setCardColor(item(blue, card: 0)) }
        #expect(plain.text == ":::card blue 名前\n\n:::")
        // Taking the card away, with and without what is in it.
        let unwrap = ConcealedEditor(sample)
        unwrap.key { unwrap.textView.unwrapCard(item(card: location)) }
        #expect(unwrap.text == "本文\nプロジェクトA\n- [/] 進行中のタスク\n- [>] 待機のタスク\nおわり")
        let delete = ConcealedEditor(sample)
        delete.key { delete.textView.deleteCard(item(card: location)) }
        #expect(delete.text == "本文\nおわり")
        delete.undo.undo()
        #expect(delete.text == sample)
        let atEnd = ConcealedEditor("本文\n:::card blue A\n中身\n:::")
        atEnd.key { atEnd.textView.deleteCard(item(card: 3)) }
        #expect(atEnd.text == "本文")
    }

    // MARK: Clicks

    private func mouseDown(_ note: TestNote, at point: NSPoint, type: NSEvent.EventType = .leftMouseDown) -> NSEvent {
        let inWindow = note.textView.convert(NSPoint(x: point.x + note.textView.textContainerOrigin.x,
                                                     y: point.y + note.textView.textContainerOrigin.y), to: nil)
        return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: 0,
                                  windowNumber: note.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func aClickOnTheFrameUnderTheTextPutsTheCaretAtTheEndOfTheText() throws {
        let note = TestNote("本文\n:::card orange A\n一行目\n二行目\n:::\nおわり")
        let layout = try #require(note.textView.layoutManager as? ConcealingLayoutManager)
        let card = try #require(layout.cardGeometries().first)
        note.textView.setSelectedRange(NSRange(location: 0, length: 0))
        // The press is followed until the button is released (see CardDragTests for drags).
        let point = NSPoint(x: card.frame.midX, y: card.frame.maxY - 3)
        var release: NSEvent? = mouseDown(note, at: point, type: .leftMouseUp)
        note.textView.trackingEvents = { _ in defer { release = nil }; return release }
        note.textView.mouseDown(with: mouseDown(note, at: point))
        let text = note.textView.string as NSString
        #expect(note.textView.selectedRange() == NSRange(location: NSMaxRange(text.range(of: "二行目")), length: 0))
    }

    @Test func aClickUnderACardThatEndsTheNoteMakesALineThere() throws {
        let note = TestNote(":::card orange A\n中身\n:::")
        let layout = try #require(note.textView.layoutManager as? ConcealingLayoutManager)
        let card = try #require(layout.cardGeometries().first)
        note.textView.mouseDown(with: mouseDown(note, at: NSPoint(x: card.frame.midX, y: card.frame.maxY + 30)))
        #expect(note.textView.string == ":::card orange A\n中身\n:::\n")
        #expect(note.textView.selectedRange().location == (note.textView.string as NSString).length)
        #expect(layout.cardGeometries().count == 1)
    }

    @Test func aRightClickOnTheFrameShowsTheCardsMenu() throws {
        let note = TestNote("本文\n:::card purple A\n中身\n:::")
        let layout = try #require(note.textView.layoutManager as? ConcealingLayoutManager)
        let card = try #require(layout.cardGeometries().first)
        let onFrame = note.textView.menu(for: mouseDown(note, at: NSPoint(x: card.dots.minX - 20, y: card.dots.midY), type: .rightMouseDown))
        #expect(onFrame?.items.last?.title == "カードを削除")
        #expect(onFrame?.items.first { $0.state == .on }?.title == CardColor.purple.title)
        #expect(card.menuArea.contains(NSPoint(x: card.dots.midX, y: card.dots.midY)))
        #expect(card.frame.contains(card.menuArea))
    }

    // MARK: Elsewhere

    @Test func theNotesTitleIsTheCardsTitle() {
        #expect(NoteTitle.derive(from: ":::card orange プロジェクトA\n- [ ] 一\n:::") == "プロジェクトA")
        #expect(NoteTitle.derive(from: ":::card orange \n- [/] 資料を作る\n:::") == "資料を作る")   // no title: the first line of its text
        #expect(NoteTitle.derive(from: ":::card\n:::\n\n# 見出し") == "見出し")
        #expect(NoteTitle.derive(from: ":::\n本文") == "本文")
    }

    @Test func emphasisDarkensTheCardsAndKeepsOnlyTheEmphasizedToDosLight() throws {
        let text = "- [/] 外の進行中\n:::card orange A\n- [/] 中の進行中\n- [>] 中の待機\n:::\n:::card blue B\n- [ ] 未着手\n:::"
        let note = TestNote(text, size: CGSize(width: 280, height: 330), focus: .doing)
        let storage = try #require(note.textView.textStorage)
        let ns = text as NSString
        func index(_ needle: String) -> Int { ns.range(of: needle).location }
        func alpha(_ needle: String) -> CGFloat {
            (storage.attribute(.foregroundColor, at: index(needle), effectiveRange: nil) as? NSColor)?.alphaComponent ?? -1
        }
        // The to-dos in progress are white, outside a card and in one: the cards go dark with the paper.
        for needle in ["外の進行中", "中の進行中"] {
            #expect(storage.attribute(.mdInk, at: index(needle), effectiveRange: nil) as? NSColor == theme.focusInk, "\(needle)")
            #expect(storage.attribute(.foregroundColor, at: index(needle), effectiveRange: nil) as? NSColor == theme.focusInk, "\(needle)")
        }
        // Everything else in the cards is in the light ink, fainter: their titles too (on their darkened tags),
        // also in the card that holds one.
        #expect(storage.attribute(.foregroundColor, at: index("A\n"), effectiveRange: nil) as? NSColor
                == theme.focusInk.withAlphaComponent(theme.focusFade))
        #expect(abs(alpha("中の待機") - theme.focusFade) < 0.001)
        #expect(abs(alpha("未着手") - theme.focusFade) < 0.001)
        for needle in [":::card orange", "中の進行中", "中の待機", ":::card blue", "未着手"] {
            #expect(storage.attribute(.mdCardShade, at: index(needle), effectiveRange: nil) != nil, "\(needle)")
        }
        let layout = try #require(note.textView.layoutManager as? ConcealingLayoutManager)
        #expect(layout.cardGeometries().map(\.isShaded) == [true, true])
        // The caret is white everywhere.
        for needle in ["外の進行中", "中の待機", "未着手"] {
            note.textView.setSelectedRange(NSRange(location: index(needle), length: 0))
            #expect(note.textView.insertionPointColor == theme.focusInk, "\(needle)")
        }
        try note.write("cards-focus-doing")
        note.controller.setFocus(.waiting)
        try note.write("cards-focus-waiting")
        note.controller.setFocus(nil)
        #expect(layout.cardGeometries().map(\.isShaded) == [false, false])
        #expect(storage.attribute(.mdCardShade, at: index("中の待機"), effectiveRange: nil) == nil)
        try note.write("cards-note")
    }

    @Test func textComposedOnAnEmptyLineOfACardStaysInTheCard() throws {
        let note = TestNote(":::card orange A\n\n:::\n")
        let storage = try #require(note.textView.textStorage)
        let line = (note.textView.string as NSString).range(of: "\n\n").location + 1
        note.textView.setSelectedRange(NSRange(location: line, length: 0))
        note.textView.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        // Not restyled while it is being composed: it has the line's indent and belongs to the card.
        let style = try #require(storage.attribute(.paragraphStyle, at: line, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.firstLineHeadIndent == theme.cardContentInset)
        #expect(storage.attribute(.mdCard, at: line, effectiveRange: nil) != nil)
        let layout = try #require(note.textView.layoutManager as? ConcealingLayoutManager)
        #expect(layout.cardGeometries().count == 1)
        note.textView.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(note.textView.string == ":::card orange A\n日本\n:::\n")
    }

    // MARK: Drawing

    @Test func theCardIsARectangleWithATagAndItsTextRightOnIt() throws {
        let e = ConcealedEditor(sample)
        let card = try #require(e.layoutManager.cardGeometries().first)
        let container = e.layoutManager.textContainers[0]
        #expect(card.color == .orange)
        // The card spans the line, and its text is right on it, the card's padding from its edges.
        #expect(abs(card.frame.minX - container.lineFragmentPadding) < 0.5)
        #expect(abs(card.frame.maxX - (container.size.width - container.lineFragmentPadding)) < 0.5)
        let content = try #require(card.content)
        #expect(card.frame.contains(content))
        #expect(abs(content.minX - card.frame.minX - theme.cardPadding) < 0.5)
        #expect(abs(card.frame.maxX - content.maxX - theme.cardPadding) < 0.5)
        #expect(abs(e.x(at: e.index(of: "- [/]")) - content.minX) < 0.5)
        let task = e.layoutManager.lineFragmentRect(forGlyphAt: e.layoutManager.glyphIndexForCharacter(at: e.index(of: "進行中")),
                                                    effectiveRange: nil)
        let last = e.layoutManager.lineFragmentRect(forGlyphAt: e.layoutManager.glyphIndexForCharacter(at: e.index(of: "待機")),
                                                    effectiveRange: nil)
        #expect(abs(task.minY - content.minY) < 0.5)
        #expect(abs(content.maxY - last.maxY) < 0.5)
        #expect(abs(card.frame.maxY - content.maxY - theme.cardPaddingBottom) < 0.5)
        // The tag is around the title, at the frame's top left; "•••" is at its top right.
        let tag = try #require(card.tags.first)
        #expect(card.tags.count == 1)
        #expect(tag.height == theme.cardTagHeight)
        #expect(abs(tag.minX - content.minX) < 0.5)                       // the text starts under the tag's edge
        #expect(abs(tag.minY - card.frame.minY - theme.cardPaddingTop) < 1.5)
        #expect(abs(content.minY - tag.maxY - theme.cardTagGap) < 1.5)
        #expect(abs(card.dots.maxX - (card.frame.maxX - theme.cardDotsInset)) < 0.5)
        #expect(abs(card.dots.midY - tag.midY) < 0.5)
        // The lines around the card are not moved by it.
        #expect(abs(e.x(at: 0) - container.lineFragmentPadding) < 0.5)
        #expect(abs(e.x(at: e.index(of: "おわり")) - container.lineFragmentPadding) < 0.5)
    }

    @Test func rendersTheCard() throws {
        let text = """
        通常のmd記法
        :::card orange プロジェクトA
        - [/] 進行中のタスク
        - [>] 待機のタスク
        - [ ] 未着手のタスク
        :::
        :::card purple プロジェクトB
        カード内は通常のmd記法。**太字**や `code`、長い行は折り返します。
        1. 番号付き
        > 引用
        ---
        ```
        let x = 1
        ```
        :::
        :::card blue
        :::
        通常のmd記法
        """
        let e = ConcealedEditor(text, width: 280)
        let data = try #require(e.png())
        let rep = try #require(NSBitmapImageRep(data: data))
        let cards = e.layoutManager.cardGeometries()
        #expect(cards.count == 3)
        #expect(cards[2].content == nil && cards[2].titleIsEmpty)     // no text, no title: the placeholder's tag
        // The card is painted in its color, under its text too (no panel of another color).
        let scale = CGFloat(rep.pixelsWide) / e.textView.bounds.width
        let origin = e.textView.textContainerOrigin
        func color(_ point: NSPoint) -> NSColor? {
            rep.colorAt(x: Int((origin.x + point.x) * scale), y: Int((origin.y + point.y) * scale))?.usingColorSpace(.sRGB)
        }
        func close(_ a: NSColor?, _ b: NSColor) -> Bool {
            guard let a, let b = b.usingColorSpace(.sRGB) else { return false }
            return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) < 0.03
        }
        let frame = cards[0].frame, content = try #require(cards[0].content)
        #expect(close(color(NSPoint(x: frame.minX + 3, y: frame.midY)), CardColor.orange.frame))
        #expect(close(color(NSPoint(x: content.maxX - 4, y: content.midY)), CardColor.orange.frame))
        #expect(close(color(NSPoint(x: content.maxX - 4, y: content.minY + 2)), CardColor.orange.frame))
        #expect(close(color(NSPoint(x: cards[0].tags[0].minX + 2, y: cards[0].tags[0].minY + 2)), CardColor.orange.tag))
        if let dir = ProcessInfo.processInfo.environment["MARKDOWN_STICKIES_RENDER_DIR"] {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("cards.png"))
            e.setConceals(false)
            try e.png()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("cards-revealed.png"))
        }
    }

    // MARK: Found in review (2026-11-20)

    @Test func deletingASelectedCardKeepsTheBlockAfterIt() {
        // Selected from its title to the end of its text, the selection takes the whole card, line break and
        // all: the to-do after it stays a to-do.
        let e = ConcealedEditor(":::card blue A\n本文\n:::\n- [>] 返信")
        e.textView.setSelectedRange(NSRange(location: e.index(of: "A\n"), length: 3))
        e.key { e.textView.deleteBackward(nil) }
        #expect(e.text == "- [>] 返信")
        // Whole lines of text likewise; joining part of a line to the next still drops the next one's marker.
        let lines = ConcealedEditor("- 一\n- 二")
        lines.textView.setSelectedRange(NSRange(location: 0, length: 4))
        lines.key { lines.textView.deleteBackward(nil) }
        #expect(lines.text == "- 二")
        let join = ConcealedEditor("- 一\n- 二")
        join.textView.setSelectedRange(NSRange(location: 2, length: 2))
        join.key { join.textView.deleteBackward(nil) }
        #expect(join.text == "- 二")
        #expect(join.caret == 2)
    }

    @Test func typingOverASelectedCardDoesNotTypeIntoTheNextOne() {
        let e = ConcealedEditor(":::card blue A\n本文\n:::\n:::card red B\n二\n:::")
        e.textView.setSelectedRange(NSRange(location: e.index(of: "A\n"), length: 3))
        e.type("X")
        #expect(e.text == "X\n:::card red B\n二\n:::")
        #expect(e.caret == 1)
        e.undo.undo()
        #expect(e.text == ":::card blue A\n本文\n:::\n:::card red B\n二\n:::")
    }

    @Test func theSelectionShowsOnACard() throws {
        let note = TestNote(":::card orange A\n本文です本文です\n:::\n外の文です外の文", size: CGSize(width: 280, height: 220))
        note.window.makeFirstResponder(note.textView)
        let layout = try #require(note.textView.layoutManager as? ConcealingLayoutManager)
        let ns = note.textView.string as NSString
        let bounds = note.textView.bounds
        func color(selecting needle: String) throws -> (selected: NSColor, beside: NSColor) {
            let range = ns.range(of: needle)
            note.textView.setSelectedRange(range)
            let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                                           in: note.textView.textContainer!)
            let rep = try #require(note.textView.bitmapImageRepForCachingDisplay(in: bounds))
            note.textView.cacheDisplay(in: bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / bounds.width, origin = note.textView.textContainerOrigin
            func at(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
                try #require(rep.colorAt(x: Int((origin.x + x) * scale), y: Int((origin.y + y) * scale))?.usingColorSpace(.sRGB))
            }
            // The corner of the selection (no glyph there), and the card (or paper) right of it.
            return (try at(rect.minX + 1.5, rect.minY + 1.5), try at(rect.maxX + 30, rect.minY + 1.5))
        }
        func differs(_ a: NSColor, _ b: NSColor) -> Bool {
            abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.05
        }
        let inCard = try color(selecting: "本文です")
        #expect(differs(inCard.selected, inCard.beside))
        #expect(!differs(inCard.beside, CardColor.orange.frame))
    }

    @Test func aCardAtTheVeryStartHasTheSpaceAboveItsTitleToo() throws {
        // TextKit gives the first paragraph of a text no space before it; the card makes up for it.
        for text in [":::card orange A\n本文\n:::", "前\n:::card orange A\n本文\n:::"] {
            let e = ConcealedEditor(text)
            let card = try #require(e.layoutManager.cardGeometries().first)
            let tag = try #require(card.tags.first)
            #expect(abs(tag.minY - card.frame.minY - theme.cardPaddingTop) < 1.5, "\(text.debugDescription)")
            #expect(abs(card.frame.minY - e.layoutManager.lineFragmentRect(
                forGlyphAt: e.layoutManager.glyphIndexForCharacter(at: e.index(of: ":::card")), effectiveRange: nil).minY - theme.cardGap) < 0.5)
        }
        let note = TestNote(":::card orange A\n本文\n:::\nおわり")
        try note.write("card-at-the-start")
    }
}
