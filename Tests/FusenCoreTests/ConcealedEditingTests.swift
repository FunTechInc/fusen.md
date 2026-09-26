import AppKit
import Testing
@testable import FusenCore

/// Editing concealed Markdown the way Notion edits rich text: the cases a review reproduced, each as
/// the user would do it (ConcealedEditor is in ConcealmentTests).
@MainActor
struct ConcealedEditingTests {
    private func selection(_ e: ConcealedEditor) -> NSRange { e.textView.selectedRange() }

    // MARK: Deleting next to other spans

    @Test func backspaceAndDeleteLeaveNeighbouringSpansAlone() {
        let e = ConcealedEditor("*a*b`c`")
        e.click(4) // after "b"
        e.key { e.textView.deleteBackward(nil) }
        #expect(e.text == "*a*`c`")
        let link = ConcealedEditor("[リンク](https://example.com)と**太字**")
        link.click(link.index(of: "と") + 1)
        link.key { link.textView.deleteBackward(nil) }
        #expect(link.text == "[リンク](https://example.com)**太字**")
        let forward = ConcealedEditor("**重要**の`設定`")
        forward.click(forward.index(of: "の"))
        forward.key { forward.textView.deleteForward(nil) }
        #expect(forward.text == "**重要**`設定`")
    }

    @Test func aSpanLeftWithoutTextGoesWhole() {
        let e = ConcealedEditor("**太字**[リ](https://x.com)")
        e.click(e.index(of: "リ") + 1)
        e.key { e.textView.deleteBackward(nil) }
        #expect(e.text == "**太字**")
        let nested = ConcealedEditor("[**a**b](https://x.com)")
        nested.click(nested.index(of: "b") + 1)
        nested.key { nested.textView.deleteBackward(nil) }
        #expect(nested.text == "[**a**](https://x.com)")
        let only = ConcealedEditor("前[**a**](https://x.com)後")
        only.click(only.index(of: "a") + 1)
        only.key { only.textView.deleteBackward(nil) }
        #expect(only.text == "前後")
        only.undo.undo()
        #expect(only.text == "前[**a**](https://x.com)後")
    }

    @Test func wordAndLineDeletionKeepHiddenSyntax() {
        let link = ConcealedEditor("[リンク](https://example.com) 後")
        link.click(link.index(of: " 後"))                     // right after "リンク" on screen
        link.key { link.textView.deleteWordBackward(nil) }
        #expect(link.text == " 後")
        for caret in [6, 8] {                                  // before and after the hidden closing "**"
            let e = ConcealedEditor("**bold** text")
            e.click(caret)
            e.key { e.textView.deleteWordBackward(nil) }
            #expect(e.text == " text", "caret \(caret)")
        }
        let word = ConcealedEditor("**one two**")
        word.click(word.index(of: "two") + 3)
        word.key { word.textView.deleteWordBackward(nil) }
        #expect(word.text == "**one** ")                     // not "**one **", which shows its asterisks
        let heading = ConcealedEditor("## 見出し")
        heading.click(heading.text.utf16.count)
        heading.key { heading.textView.deleteToBeginningOfLine(nil) }
        #expect(heading.text == "## ")                        // the text goes, the heading stays
        let task = ConcealedEditor("- [x] 済み")
        task.click(task.text.utf16.count)
        task.key { task.textView.deleteToBeginningOfLine(nil) }
        #expect(task.text == "- [x] ")
        let forward = ConcealedEditor("[リンク](https://example.com)")
        forward.click(1)
        forward.key { forward.textView.deleteWordForward(nil) }
        #expect(forward.text == "")
    }

    @Test func deletingASelectionKeepsTheSyntaxOfSpansReachingOutside() {
        let e = ConcealedEditor("**bold** text")
        e.textView.setSelectedRange(NSRange(location: 4, length: 7)) // "ld te" on screen
        e.key { e.textView.deleteBackward(nil) }
        #expect(e.text == "**bo**xt")
        let typed = ConcealedEditor("**bold** text")
        typed.textView.setSelectedRange(NSRange(location: 4, length: 7))
        typed.type("Z")
        #expect(typed.text == "**boZ**xt")
        let link = ConcealedEditor("[リンク](https://example.com) 後")
        link.textView.setSelectedRange(NSRange(location: 3, length: 25)) // "ク 後"
        link.key { link.textView.deleteForward(nil) }
        #expect(link.text == "[リン](https://example.com)")
    }

    // MARK: Return

    @Test func returnInsideASpanKeepsBothHalvesStyled() {
        let e = ConcealedEditor("**太字の文章**")
        e.click(e.index(of: "文章"))
        e.key { e.textView.insertNewline(nil) }
        #expect(e.text == "**太字の**\n**文章**")
        let link = ConcealedEditor("詳細は[こちら](https://example.com)を参照")
        link.click(link.index(of: "ら"))
        link.key { link.textView.insertNewline(nil) }
        #expect(link.text == "詳細は[こち](https://example.com)\n[ら](https://example.com)を参照")
        let list = ConcealedEditor("- **ab**")
        list.click(list.index(of: "b"))
        list.key { list.textView.insertNewline(nil) }
        #expect(list.text == "- **a**\n- **b**")
    }

    @Test func returnAtTheVisibleStartOfABlocksText() {
        let h = ConcealedEditor("前\n## **見出し**")
        h.click(h.text.utf16.count)
        for _ in 0..<3 { h.key { h.textView.moveLeft(nil) } }
        #expect(h.caret == h.index(of: "見"))
        h.key { h.textView.insertNewline(nil) }
        #expect(h.text == "前\n\n## **見出し**")
        let l = ConcealedEditor("- **a**")
        l.click(l.text.utf16.count)
        l.key { l.textView.moveLeft(nil) }
        l.key { l.textView.insertNewline(nil) }
        #expect(l.text == "- \n- **a**")
        #expect(l.caret == l.index(of: "a"))                  // before the text, which moved down
        let task = ConcealedEditor("- [x] 済んだこと")
        task.click(task.index(of: "済"))
        task.key { task.textView.insertNewline(nil) }
        #expect(task.text == "- [ ] \n- [x] 済んだこと")        // the check mark stays with its text
        let ordered = ConcealedEditor("1. 項目")
        ordered.click(ordered.index(of: "項"))
        ordered.key { ordered.textView.insertNewline(nil) }
        #expect(ordered.text == "1. \n2. 項目")
    }

    @Test func returnAtTheEndOfASpanBreaksAfterIt() {
        let e = ConcealedEditor("- **a**")
        e.click(e.index(of: "a") + 1)                          // before the hidden closing "**"
        e.key { e.textView.insertNewline(nil) }
        #expect(e.text == "- **a**\n- ")
    }

    // MARK: Caret and selection

    @Test func arrowKeysAlwaysMoveTheCaretOnScreen() {
        func moved(_ text: String, from start: Int, forward: Bool) -> Int {
            let e = ConcealedEditor(text)
            e.click(start)
            e.key { forward ? e.textView.moveRight(nil) : e.textView.moveLeft(nil) }
            return e.caret
        }
        #expect(moved("a*b*c", from: 1, forward: true) == 3)
        #expect(moved("a `code` b", from: 2, forward: true) == 4)
        #expect(moved("2\\*3", from: 1, forward: true) == 3)
        #expect(moved("[ラベル](https://a.com)", from: 0, forward: true) == 2)
        #expect(moved("**b**\nc", from: 3, forward: true) == 6)
        #expect(moved("a\n**b**", from: 4, forward: false) == 1)
        #expect(moved("前\n## **見出し**", from: 7, forward: false) == 1)
        #expect(moved("2\\*3", from: 3, forward: false) == 1)    // before the hidden backslash
    }

    @Test func theCaretNeverStopsBetweenAnEscapeAndItsCharacter() {
        let e = ConcealedEditor("\\- 箇条書きではない")
        e.click(e.index(of: " "))                              // after "-"
        e.key { e.textView.moveLeft(nil) }
        #expect(e.caret == 0)
        e.type("x")
        #expect(e.text == "x\\- 箇条書きではない")
        e.click(1)                                             // a click between "\" and "-"
        #expect(e.caret == 1 || e.caret == 3)
        #expect(e.caret != 2)
    }

    @Test func optionLeftLeavesTheStartOfABlocksText() {
        for text in ["前\n1. 項目", "前\n- [x] 項目", "前\n> 引用", "前\n## 見出し"] {
            let e = ConcealedEditor(text)
            e.click(ConcealedEditing.line(at: 2, in: e.storage).contentStart)
            e.key { e.textView.moveWordLeft(nil) }
            #expect(e.caret == 1, "\(text)")
        }
        let selecting = ConcealedEditor("前\n1. 項目")
        selecting.click(5)
        selecting.key { selecting.textView.moveWordLeftAndModifySelection(nil) }
        #expect(selecting.textView.selectedRange() == NSRange(location: 1, length: 4))
    }

    @Test func shiftArrowsMoveTheEndThatMovedLast() {
        let e = ConcealedEditor("abc\ndef")
        e.click(1)
        e.key { e.textView.moveDownAndModifySelection(nil) }
        e.key { e.textView.moveLeftAndModifySelection(nil) }
        #expect(selection(e) == NSRange(location: 1, length: 3))
        let f = ConcealedEditor("abc def ghi")
        f.click(1)
        f.key { f.textView.moveWordRightAndModifySelection(nil) }
        f.key { f.textView.moveWordRightAndModifySelection(nil) }
        f.key { f.textView.moveLeftAndModifySelection(nil) }
        #expect(selection(f) == NSRange(location: 1, length: 5))
    }

    @Test func nothingInvisibleStaysSelected() {
        let e = ConcealedEditor("## 見出し")
        e.click(e.index(of: "見出し"))
        e.key { e.textView.deleteBackward(nil) }
        e.undo.undo()
        #expect(e.text == "## 見出し")
        #expect(!ConcealedEditing.onlySyntax(between: selection(e).location, and: NSMaxRange(selection(e)), in: e.storage)
                || selection(e).length == 0)
        e.type("x")
        #expect(e.text == "## x見出し" || e.text == "## 見出しx")
        let hidden = ConcealedEditor("**大事**な点")
        hidden.textView.setSelectedRange(NSRange(location: 4, length: 2)) // just the hidden closing "**"
        #expect(selection(hidden).length == 0)
    }

    @Test func theCaretLeavesSyntaxThatTypingCreates() {
        let e = ConcealedEditor(" 項目")
        e.click(0)
        e.type("-")
        #expect(ConcealedEditing.line(at: 0, in: e.storage).kind == .bullet)
        e.type("x")
        #expect(e.text == "- x項目")
        let r = ConcealedEditor("手順は1. 開く")
        r.click(r.index(of: "1."))
        r.key { r.textView.insertNewline(nil) }
        #expect(r.text == "手順は\n1. 開く")
        #expect(r.caret == r.index(of: "開"))
    }

    // MARK: Formatting

    @Test func formattingSkipsTheBlockMarker() {
        let h = ConcealedEditor("## 見出し")
        h.click(h.text.utf16.count)
        h.key { h.textView.moveToBeginningOfLineAndModifySelection(nil) }
        h.key { h.textView.toggleBold(nil) }
        #expect(h.text == "## **見出し**")
        #expect(ConcealedEditing.line(at: 0, in: h.storage).kind == .h2)
        let l = ConcealedEditor("- 項目")
        l.textView.setSelectedRange(NSRange(location: 0, length: 4))
        l.key { l.textView.toggleBold(nil) }
        #expect(l.text == "- **項目**")
        let t = ConcealedEditor("本文\n次")
        t.textView.setSelectedRange(NSRange(location: 0, length: 3)) // a triple-click: the line and its newline
        t.key { t.textView.toggleBold(nil) }
        #expect(t.text == "**本文**\n次")
        let lines = ConcealedEditor("一\n- 二\n---\n三")
        lines.textView.setSelectedRange(NSRange(location: 0, length: lines.storage.length))
        lines.key { lines.textView.toggleItalic(nil) }
        #expect(lines.text == "*一*\n- *二*\n---\n*三*")
        #expect(lines.textView.selectedRange() == NSRange(location: 1, length: lines.storage.length - 2))
    }

    @Test func formattingPartOfAStyledSpan() {
        let first = ConcealedEditor("**bold**")
        first.textView.setSelectedRange(NSRange(location: 2, length: 1)) // "b"
        first.key { first.textView.toggleBold(nil) }
        #expect(first.text == "b**old**")
        #expect(first.textView.selectedRange() == NSRange(location: 0, length: 1))
        let end = ConcealedEditor("**bold**")
        end.textView.setSelectedRange(NSRange(location: 3, length: 3)) // "old"
        end.key { end.textView.toggleBold(nil) }
        #expect(end.text == "**b**old")
        let middle = ConcealedEditor("**bold**")
        middle.textView.setSelectedRange(NSRange(location: 3, length: 2)) // "ol"
        middle.key { middle.textView.toggleBold(nil) }
        #expect(middle.text == "**b**ol**d**")
        // Across the edge of a span: all of it becomes bold, in one span.
        let across = ConcealedEditor("**bold** text")
        across.textView.setSelectedRange(NSRange(location: 4, length: 7)) // "ld te"
        across.key { across.textView.toggleBold(nil) }
        #expect(across.text == "**bold te**xt")
        // Italic on the start of bold text needs "__" for the bold ("***b*…" reads differently).
        let italic = ConcealedEditor("**bc**")
        italic.textView.setSelectedRange(NSRange(location: 2, length: 1))
        italic.key { italic.textView.toggleItalic(nil) }
        #expect(styles(of: "b", in: italic) == ["bold", "italic"])
        #expect(styles(of: "c", in: italic) == ["bold"])
    }

    @Test func boldItalicShowsBothWithoutAsterisks() {
        let e = ConcealedEditor("大事な点")
        e.textView.setSelectedRange(NSRange(location: 0, length: 2))
        e.key { e.textView.toggleBold(nil) }
        e.key { e.textView.toggleItalic(nil) }
        #expect(e.text == "***大事***な点")
        #expect(e.property(at: 0) == .null && e.property(at: 6) == .null)
        let font = e.storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(e.storage.attribute(.obliqueness, at: 3, effectiveRange: nil) != nil)
        // Taking bold off one character of bold italic text.
        let part = ConcealedEditor("***abc***")
        part.textView.setSelectedRange(NSRange(location: 4, length: 1))
        part.key { part.textView.toggleBold(nil) }
        #expect(styles(of: "a", in: part) == ["bold", "italic"])
        #expect(styles(of: "b", in: part) == ["italic"])
        #expect(styles(of: "c", in: part) == ["bold", "italic"])
    }

    @Test func formattingWithNothingSelectedStylesWhatIsTypedNext() {
        let e = ConcealedEditor("abc")
        e.click(3)
        e.key { e.textView.toggleBold(nil) }
        #expect(e.text == "abc")                              // no visible "****"
        e.type("xy")
        #expect(e.text == "abc**xy**")
        e.key { e.textView.toggleBold(nil) }                  // at the end of the bold text: bold stops
        e.type("z")
        #expect(e.text == "abc**xy**z")
        let twice = ConcealedEditor("abc")
        twice.click(3)
        twice.key { twice.textView.toggleBold(nil) }
        twice.key { twice.textView.toggleBold(nil) }          // taken back
        twice.type("x")
        #expect(twice.text == "abcx")
        let inside = ConcealedEditor("**abcd**")
        inside.click(4)                                       // between "b" and "c"
        inside.key { inside.textView.toggleBold(nil) }
        inside.type("x")
        #expect(inside.text == "**ab**x**cd**")
        let divider = ConcealedEditor("---")
        divider.click(3)
        divider.key { divider.textView.toggleBold(nil) }
        #expect(divider.text == "---")
        // Composed with the IME.
        let ime = ConcealedEditor("前")
        ime.click(1)
        ime.key { ime.textView.toggleBold(nil) }
        ime.key {
            ime.textView.setMarkedText("ふと", selectedRange: NSRange(location: 2, length: 0),
                                       replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        ime.key { ime.textView.insertText("太", replacementRange: ime.textView.markedRange()) }
        #expect(ime.text == "前**太**")
        ime.type("字")
        #expect(ime.text == "前**太字**")
    }

    /// Markdown that Notion reads the same way: one span, not two side by side.
    @Test func formattingNextToTheSameStyleMakesOneSpan() {
        let typed = ConcealedEditor("**ab**")
        typed.click(6)                                        // after the bold text
        typed.key { typed.textView.toggleBold(nil) }
        typed.type("c")
        #expect(typed.text == "**abc**")
        let selected = ConcealedEditor("**ab**c")
        selected.textView.setSelectedRange(NSRange(location: 6, length: 1))
        selected.key { selected.textView.toggleBold(nil) }
        #expect(selected.text == "**abc**")
        #expect(selected.textView.selectedRange() == NSRange(location: 4, length: 1))
        let nested = ConcealedEditor("***abc***")
        nested.textView.setSelectedRange(NSRange(location: 4, length: 1))
        nested.key { nested.textView.toggleBold(nil) }
        #expect(nested.text == "*__a__b__c__*")
    }

    @Test func linkingTheSelection() {
        let e = ConcealedEditor("詳しくはこちら")
        e.textView.setSelectedRange(NSRange(location: 4, length: 3))
        e.key { e.textView.makeLink(to: "https://example.com/a b") }
        #expect(e.text == "詳しくは[こちら](https://example.com/a%20b)")
        #expect(e.textView.selectedRange() == NSRange(location: 5, length: 3))
        let empty = ConcealedEditor("")
        empty.key { empty.textView.makeLink(to: "https://x.com") }
        #expect(empty.text == "[https://x.com](https://x.com)")
    }

    // MARK: Dividers and IME

    @Test func pastingOnADividerStartsANewLine() {
        let board = NSPasteboard(name: NSPasteboard.Name("fusen-tests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("貼り付け", forType: .string)
        let e = ConcealedEditor("---")
        e.click(3)
        e.key { _ = e.textView.readSelection(from: board, type: .string) }
        #expect(e.text == "---\n貼り付け")
        let over = ConcealedEditor("**bold** text")
        over.textView.setSelectedRange(NSRange(location: 4, length: 7))
        over.key { _ = over.textView.readSelection(from: board, type: .string) }
        #expect(over.text == "**bo貼り付け**xt")
    }

    @Test func composingOnADividerWithAnExplicitRange() {
        let e = ConcealedEditor("---")
        e.click(3)
        e.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: 3, length: 0))
        e.textView.insertText("二", replacementRange: e.textView.markedRange())
        e.restyle()
        #expect(e.text == "---\n二")
    }

    // MARK: Notion

    @Test func quotesStartingWithAGreaterThanSignRoundTrip() {
        let styler = MarkdownStyler()
        for note in ["> >>> print(1)", "> >x", "> a\n>\n> b"] {
            #expect(NotionMarkdown.fromNotion(NotionMarkdown.export(note, styler: styler)) == note)
        }
    }

    // MARK: Notion's "[]"

    @Test func bracketsMakeAToDo() {
        let empty = ConcealedEditor("")
        empty.type("[]")
        #expect(empty.text == "- [ ] ")
        #expect(ConcealedEditing.line(at: 0, in: empty.storage).kind == .task)
        #expect(empty.caret == 6)
        empty.type("牛乳")
        #expect(empty.text == "- [ ] 牛乳")
        let existing = ConcealedEditor("買い物")
        existing.click(0)
        existing.type("[]")
        #expect(existing.text == "- [ ] 買い物")
        #expect(existing.caret == existing.index(of: "買"))
        let bullet = ConcealedEditor("- ")
        bullet.click(2)
        bullet.type("[]")
        #expect(bullet.text == "- [ ] ")
        let ordered = ConcealedEditor("1. ")
        ordered.click(3)
        ordered.type("[]")
        #expect(ordered.text == "1. [ ] ")
        let nested = ConcealedEditor("\t")
        nested.click(1)
        nested.type("[]")
        #expect(nested.text == "\t- [ ] ")
        // Committed by the IME (half-width brackets) too.
        let ime = ConcealedEditor("")
        ime.key {
            ime.textView.setMarkedText("[]", selectedRange: NSRange(location: 2, length: 0),
                                       replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        ime.key { ime.textView.insertText("[]", replacementRange: ime.textView.markedRange()) }
        #expect(ime.text == "- [ ] ")
    }

    @Test func bracketsElsewhereStayAsTyped() {
        let middle = ConcealedEditor("a")
        middle.click(1)
        middle.type("[]")
        #expect(middle.text == "a[]")
        let code = ConcealedEditor("```\n")
        code.click(4)
        code.type("[]")
        #expect(code.text == "```\n[]")
        let heading = ConcealedEditor("## ")
        heading.click(3)
        heading.type("[]")
        #expect(heading.text == "## []")
        let raw = ConcealedEditor("")
        raw.setConceals(false)
        raw.type("[]")
        #expect(raw.text == "[]")
    }

    // MARK: Second review

    /// What the note shows, with the hidden syntax left out.
    private func shown(_ e: ConcealedEditor) -> String {
        (0..<e.storage.length).filter { !ConcealedEditing.onlySyntax(between: $0, and: $0 + 1, in: e.storage) }
            .map { (e.text as NSString).substring(with: NSRange(location: $0, length: 1)) }.joined()
    }

    @Test func typingOverASpansTextKeepsTheSpan() {
        let link = ConcealedEditor("詳細は[こちら](https://example.com)を参照")
        link.textView.setSelectedRange(NSRange(location: link.index(of: "こちら"), length: 3))
        link.type("here")
        #expect(link.text == "詳細は[here](https://example.com)を参照")
        let bold = ConcealedEditor("これは**太字**です")
        bold.textView.setSelectedRange(NSRange(location: bold.index(of: "太字"), length: 2))
        bold.type("強調")
        #expect(bold.text == "これは**強調**です")
        let ime = ConcealedEditor("これは**太字**です")
        ime.textView.setSelectedRange(NSRange(location: ime.index(of: "太字"), length: 2))
        ime.key {
            ime.textView.setMarkedText("きょう", selectedRange: NSRange(location: 3, length: 0),
                                       replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        ime.key { ime.textView.insertText("強調", replacementRange: ime.textView.markedRange()) }
        #expect(ime.text == "これは**強調**です")
        let board = NSPasteboard(name: NSPasteboard.Name("fusen-tests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("here", forType: .string)
        let paste = ConcealedEditor("[こちら](https://example.com)")
        paste.textView.setSelectedRange(NSRange(location: 1, length: 3))
        paste.key { _ = paste.textView.readSelection(from: board, type: .string) }
        #expect(paste.text == "[here](https://example.com)")
        // A space replacing the text cannot stand inside the span: the span goes.
        let space = ConcealedEditor("a**b**c")
        space.textView.setSelectedRange(NSRange(location: 3, length: 1))
        space.type(" ")
        #expect(space.text == "a c")
    }

    @Test func formattingManyLinesIsOneChange() {
        let e = ConcealedEditor((0..<200).map { "行 \($0) の本文です" }.joined(separator: "\n"))
        e.textView.setSelectedRange(NSRange(location: 0, length: e.storage.length))
        let elapsed = ContinuousClock().measure { e.key { e.textView.toggleBold(nil) } }
        #expect(elapsed < .seconds(2), "took \(elapsed)")
        #expect(e.text.hasPrefix("**行 0 の本文です**\n**行 1 の本文です**"))
        e.undo.undo()
        #expect(!e.text.contains("**"))
        let mixed = ConcealedEditor("**太字**\n普通")
        mixed.textView.setSelectedRange(NSRange(location: 0, length: mixed.storage.length))
        mixed.key { mixed.textView.toggleBold(nil) }
        #expect(mixed.text == "**太字**\n**普通**")
    }

    @Test func deletingKeepsWhatIsLeftLookingTheSame() {
        let merged = ConcealedEditor("*重要*と*注意*")
        merged.click(merged.index(of: "と") + 1)
        merged.key { merged.textView.deleteBackward(nil) }
        #expect(merged.text == "*重要注意*")
        #expect(shown(merged) == "重要注意")
        let code = ConcealedEditor("`a`x`b`")
        code.click(4)
        code.key { code.textView.deleteBackward(nil) }
        #expect(code.text == "`ab`")
        let link = ConcealedEditor("**太字**[リ](https://x.com)*重要*")
        link.click(link.index(of: "リ") + 1)
        link.key { link.textView.deleteBackward(nil) }
        #expect(shown(link) == "太字重要")
        #expect(link.property(at: 0) == .null)
        let edge = ConcealedEditor("**very important** note")
        edge.textView.setSelectedRange(NSRange(location: 2, length: 4)) // "very"
        edge.key { edge.textView.deleteBackward(nil) }
        #expect(edge.text == " **important** note")
        #expect(edge.caret == 0)
        let inner = ConcealedEditor("**a b**")
        inner.click(3)
        inner.key { inner.textView.deleteBackward(nil) }
        #expect(inner.text == " **b**")
        let italic = ConcealedEditor("*italic text* after")
        italic.click(italic.index(of: "italic"))
        italic.key { italic.textView.deleteWordForward(nil) }
        #expect(italic.text == " *text* after")
        #expect(ConcealedEditing.line(at: 0, in: italic.storage).kind == .text)
    }

    @Test func undoSelectsOnlyWhatChanged() {
        let e = ConcealedEditor("これは大事な点です。ほかにも長い文章が続きます")
        e.textView.setSelectedRange(NSRange(location: 3, length: 2))
        e.key { e.textView.toggleBold(nil) }
        e.undo.undo()
        #expect(selection(e) == NSRange(location: 3, length: 2))
        let t = ConcealedEditor("長い段落の文章がここにあります。")
        t.click(t.storage.length)
        t.key { t.textView.toggleBold(nil) }
        t.type("x")
        t.undo.undo()
        #expect(selection(t).length == 0)
    }

    @Test func spacesAtTheEndOfBoldText() {
        let e = ConcealedEditor("")
        e.key { e.textView.toggleBold(nil) }
        e.type("hello ")
        #expect(e.property(at: 0) == .null)                   // "**hello** ": nothing shows its syntax
        e.key { e.textView.toggleBold(nil) }                  // bold off
        e.type("world")
        #expect(e.text == "**hello** world")
        let on = ConcealedEditor("")
        on.key { on.textView.toggleBold(nil) }
        on.type("hello world")
        #expect(on.text == "**hello world**")
        let arrow = ConcealedEditor("これは**大事**です")
        arrow.click(arrow.index(of: "事"))
        arrow.key { arrow.textView.moveRight(nil) }           // after "事", inside the bold
        arrow.type(" ")
        #expect(arrow.text == "これは**大事** です")
        arrow.type("x")
        #expect(arrow.text == "これは**大事 x**です")
        let full = ConcealedEditor("")
        full.key { full.textView.toggleBold(nil) }
        full.type("　太")                                      // a full-width space first
        #expect(full.text == "　**太**")
    }

    @Test func returnAtTheEndOfADividerAddsOneLine() {
        let e = ConcealedEditor("a\n---\nb")
        e.click(5)
        e.key { e.textView.insertNewline(nil) }
        #expect(e.text == "a\n---\n\nb")
    }

    @Test func movingByWordsAndParagraphs() {
        let shift = ConcealedEditor("前\n- 項目")
        shift.click(4)
        shift.key { shift.textView.moveParagraphBackwardAndModifySelection(nil) }
        #expect(selection(shift).length > 0)
        let link = ConcealedEditor("[ab](https://x.com)")
        link.click(link.storage.length)
        link.key { link.textView.moveWordLeft(nil) }
        #expect(link.caret == 1)
        let code = ConcealedEditor("x `code` y")
        code.click(0)
        code.key { code.textView.moveWordRight(nil) }
        code.key { code.textView.moveWordRight(nil) }
        #expect(code.caret == code.index(of: "e") + 1)       // the end of "code", as if the "`" were not there
    }

    @Test func killAndYank() {
        let e = ConcealedEditor("first zzkillzz\nnext")
        e.click(5)
        e.key { e.textView.deleteToEndOfParagraph(nil) }
        e.click(e.storage.length)
        e.key { e.textView.yank(nil) }
        #expect(e.text.hasSuffix(" zzkillzz"))
    }

    @Test func deletingAtLineEdges() {
        let last = ConcealedEditor("**a**\n")
        last.click(3)
        last.key { last.textView.deleteForward(nil) }
        #expect(last.text == "**a**")
        let nfd = ConcealedEditor("abce\u{301}日本語")
        nfd.click(2)
        nfd.key { nfd.textView.deleteWordForward(nil) }
        #expect(nfd.text == "ab日本語")
        let several = ConcealedEditor("foo bar foo")
        several.textView.setSelectedRanges([NSValue(range: NSRange(location: 0, length: 3)), NSValue(range: NSRange(location: 8, length: 3))],
                                           affinity: .downstream, stillSelecting: false)
        several.key { several.textView.deleteBackward(nil) }
        #expect(several.text == " bar ")
        let quote = ConcealedEditor("本文\n> 引用")
        quote.textView.setSelectedRange(NSRange(location: 2, length: 1))
        quote.key { quote.textView.deleteBackward(nil) }
        #expect(quote.text == "本文引用")
        let crlf = ConcealedEditor("a\r\n## h")
        crlf.click(crlf.index(of: "h"))
        crlf.key { crlf.textView.moveLeft(nil) }
        #expect(crlf.caret == 1)
        crlf.type("x")
        #expect(crlf.text == "ax\r\n## h")
        let join = ConcealedEditor("a\r\n**b**")
        join.click(join.index(of: "b"))
        join.key { join.textView.deleteBackward(nil) }
        #expect(join.text == "a**b**")
    }

    @Test func boldOffAtTheEndOfBoldItalicLeavesItalic() {
        let e = ConcealedEditor("***ab***")
        e.click(5)
        e.key { e.textView.toggleBold(nil) }
        e.type("x")
        let i = e.index(of: "x")
        #expect(e.storage.attribute(.obliqueness, at: i, effectiveRange: nil) != nil)
        let font = e.storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == false)
        #expect(e.text == "*__ab__x*")
    }

    @Test func otherCommandsLeaveHiddenSyntaxAlone() {
        let upper = ConcealedEditor("[ab](https://x.com/path)c")
        upper.textView.setSelectedRange(NSRange(location: 0, length: upper.storage.length))
        upper.key { upper.textView.uppercaseWord(nil) }
        #expect(upper.text == "[AB](https://x.com/path)C")
        let optionReturn = ConcealedEditor("**太字の文章**")
        optionReturn.click(optionReturn.index(of: "文章"))
        optionReturn.key { optionReturn.textView.insertNewlineIgnoringFieldEditor(nil) }
        #expect(optionReturn.text == "**太字の**\n**文章**")
        let transpose = ConcealedEditor("**ab** c")
        transpose.click(6)
        transpose.key { transpose.textView.transpose(nil) }
        #expect(transpose.text == "**ab** c")
        let decompose = ConcealedEditor("**ab** c")
        decompose.click(6)
        decompose.key { decompose.textView.deleteBackwardByDecomposingPreviousCharacter(nil) }
        #expect(decompose.text == "**a** c")
    }

    // MARK: Robustness

    /// Random notes and keys: nothing may crash, and undoing everything gives the note back.
    @Test func randomEditingNeverCrashesAndUndoesExactly() {
        var seed: UInt64 = 0x5EED
        func random(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        let pieces = ["**太字**", "*斜め*", "`code`", "[リンク](https://x.com)", "~~消~~", "\\*", "***両方***", "文",
                      " ", "\n", "## ", "- ", "- [x] ", "1. ", "> ", "---\n", "👍🏽", "e\u{301}"]
        for _ in 0..<60 {
            let note = (0..<(1 + random(8))).map { _ in pieces[random(pieces.count)] }.joined()
            let e = ConcealedEditor(note)
            for _ in 0..<10 {
                let length = e.storage.length
                let a = random(length + 1), b = random(length + 1)
                if random(3) == 0 {
                    e.textView.setSelectedRange(NSRange(location: min(a, b), length: abs(a - b)))
                } else {
                    e.click(a)
                }
                e.key {
                    switch random(16) {
                    case 0: e.textView.deleteBackward(nil)
                    case 1: e.textView.deleteForward(nil)
                    case 2: e.textView.moveLeft(nil)
                    case 3: e.textView.moveRightAndModifySelection(nil)
                    case 4: e.textView.insertNewline(nil)
                    case 5: e.textView.toggleBold(nil)
                    case 6: e.textView.toggleItalic(nil)
                    case 7: e.textView.toggleInlineCode(nil)
                    case 8: e.textView.deleteWordBackward(nil)
                    case 9: e.textView.deleteToBeginningOfLine(nil)
                    case 10: e.textView.insertDivider(nil)
                    case 11: e.textView.moveWordLeft(nil)
                    case 12: e.textView.insertTab(nil)
                    case 13: e.textView.toggleStrikethrough(nil)
                    default: e.textView.insertText("x", replacementRange: e.textView.selectedRange())
                    }
                }
            }
            while e.undo.canUndo { e.undo.undo() }
            #expect(e.text == note)
        }
    }

    private func styles(of character: String, in e: ConcealedEditor) -> Set<String> {
        let i = e.index(of: character)
        var styles = Set<String>()
        if (e.storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true {
            styles.insert("bold")
        }
        if e.storage.attribute(.obliqueness, at: i, effectiveRange: nil) != nil { styles.insert("italic") }
        return styles
    }
}
