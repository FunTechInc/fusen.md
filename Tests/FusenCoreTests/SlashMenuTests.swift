import AppKit
import Testing
@testable import FusenCore

/// The "/" menu: Notion's slash commands for a card, the signals, a checkbox and a divider.
/// (ConcealedEditor is in ConcealmentTests, TestNote in NoteFocusTests.)
@MainActor
struct SlashMenuTests {
    private func returnKey(_ e: ConcealedEditor) { e.key { e.textView.insertNewline(nil) } }

    @Test func whatIsTypedAfterTheSlashNarrowsTheList() {
        #expect(SlashCommand.matching("") == SlashCommand.allCases)
        #expect(SlashCommand.matching("ca") == [.card])                       // the Figma's "/ca"
        #expect(SlashCommand.matching("CARD") == [.card])
        #expect(SlashCommand.matching("カ") == [.card])
        #expect(SlashCommand.matching("しん") == [.doing])
        #expect(SlashCommand.matching("待機") == [.waiting])
        #expect(SlashCommand.matching("task") == [.doing, .waiting, .todo])
        #expect(SlashCommand.matching("div") == [.divider])
        #expect(SlashCommand.matching("zzz").isEmpty)
    }

    @Test func slashAtTheStartOfALineOpensTheMenu() {
        let e = ConcealedEditor("")
        e.type("/")
        #expect(e.textView.slashMenu == SlashMenu(trigger: 0, commands: SlashCommand.allCases, selected: 0))
        e.type("c")
        #expect(e.textView.slashMenu?.commands == [.card, .todo])            // "card" and "check"
        e.type("a")
        #expect(e.textView.slashMenu?.commands == [.card])
        returnKey(e)
        #expect(e.textView.slashMenu == nil)
        #expect(e.text == ":::card default \n\n:::\n")
        #expect(e.caret == e.index(of: "\n\n:::"))                            // in the title
        e.undo.undo()                                                         // one step: back to what was typed
        #expect(e.text == "/ca")
    }

    @Test func theSignalsAndTheOtherCommands() {
        let doing = ConcealedEditor("")
        doing.type("/しんこう")
        returnKey(doing)
        #expect(doing.text == "- [/] ")
        #expect(doing.caret == 6)
        // After text and a space: the line becomes the to-do.
        let waiting = ConcealedEditor("牛乳を買う")
        waiting.click(5)
        waiting.type(" /たいき")
        returnKey(waiting)
        #expect(waiting.text == "- [>] 牛乳を買う ")
        let todo = ConcealedEditor("- 項目")
        todo.click(2)
        todo.type("/todo")
        #expect(todo.textView.slashMenu?.commands == [.todo])
        returnKey(todo)
        #expect(todo.text == "- [ ] 項目")
        let divider = ConcealedEditor("本文\n")
        divider.click(3)
        divider.type("/div")
        returnKey(divider)
        #expect(divider.text == "本文\n---\n")
        // In a card's text the card command makes a card after that card.
        let inCard = ConcealedEditor(":::card orange A\n\n:::")
        inCard.click(inCard.index(of: "\n\n:::") + 1)
        inCard.type("/ca")
        returnKey(inCard)
        #expect(inCard.text == ":::card orange A\n\n:::\n:::card default \n\n:::\n")
    }

    @Test func theArrowKeysChooseAndTabAcceptsToo() {
        let e = ConcealedEditor("")
        e.type("/")
        e.key { e.textView.moveDown(nil) }
        e.key { e.textView.moveDown(nil) }
        #expect(e.textView.slashMenu?.selected == 2)
        e.key { e.textView.moveUp(nil) }
        #expect(e.textView.slashMenu?.selected == 1)
        #expect(e.caret == 1)                                                 // the caret stays where it is
        e.key { e.textView.insertTab(nil) }
        #expect(e.text == "- [/] ")                                           // the second command: in progress
        // Up from the first goes to the last.
        let wrap = ConcealedEditor("")
        wrap.type("/")
        wrap.key { wrap.textView.moveUp(nil) }
        #expect(wrap.textView.slashMenu?.selected == SlashCommand.allCases.count - 1)
        // The highlighted command stays highlighted while the list narrows around it.
        let keep = ConcealedEditor("")
        keep.type("/")
        keep.key { keep.textView.moveDown(nil) }
        keep.key { keep.textView.moveDown(nil) }                              // waiting
        keep.type("task")
        #expect(keep.textView.slashMenu?.commands == [.doing, .waiting, .todo])
        #expect(keep.textView.slashMenu?.selected == 1)
    }

    @Test func itOpensOnlyWhereACommandCanStart() {
        for (text, typed) in [("11", "/20"), ("a", "/"), ("```\n", "/"), (":::card orange ", "/"), ("`x ", "/`")] {
            let e = ConcealedEditor(text + (text.hasPrefix(":::card") ? "\n\n:::" : ""))
            e.click((text as NSString).length)
            e.type(typed)
            #expect(e.textView.slashMenu == nil, "\(text)\(typed)")
        }
        // The Japanese keyboard's "；" opens it too.
        let e = ConcealedEditor("- [ ] ")
        e.click(6)
        e.type("；")
        #expect(e.textView.slashMenu?.trigger == 6)
        // Not with the Markdown shown as typed.
        let raw = ConcealedEditor("")
        raw.setConceals(false)
        raw.type("/")
        #expect(raw.textView.slashMenu == nil)
    }

    @Test func itClosesWhenItIsNotMeant() {
        // A space, text that fits nothing, deleting the slash, Esc, the caret going elsewhere.
        let space = ConcealedEditor("")
        space.type("/ ")
        #expect(space.textView.slashMenu == nil && space.text == "/ ")
        let nothing = ConcealedEditor("")
        nothing.type("/zz")
        #expect(nothing.textView.slashMenu == nil && nothing.text == "/zz")
        let deleted = ConcealedEditor("")
        deleted.type("/c")
        deleted.key { deleted.textView.deleteBackward(nil) }
        #expect(deleted.textView.slashMenu?.commands == SlashCommand.allCases)
        deleted.key { deleted.textView.deleteBackward(nil) }
        #expect(deleted.textView.slashMenu == nil && deleted.text == "")
        let escape = ConcealedEditor("")
        escape.type("/c")
        escape.textView.cancelOperation(nil)
        #expect(escape.textView.slashMenu == nil && escape.text == "/c")
        escape.key { escape.textView.insertNewline(nil) }                     // Return is Return again
        #expect(escape.text == "/c\n")
        let moved = ConcealedEditor("本文\n")
        moved.click(3)
        moved.type("/")
        moved.click(0)
        #expect(moved.textView.slashMenu == nil)
    }

    @Test func theListIsAWindowUnderTheCaret() throws {
        let note = TestNote("本文\n")
        note.textView.setSelectedRange(NSRange(location: 3, length: 0))
        note.textView.insertText("/", replacementRange: note.textView.selectedRange())
        let panel = try #require(note.window.childWindows?.first as? SlashMenuPanel)
        #expect(panel.frame.height > 100 && !panel.canBecomeKey)
        if let dir = ProcessInfo.processInfo.environment["MARKDOWN_STICKIES_RENDER_DIR"], let view = panel.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("slash-menu.png"))
        }
        note.textView.insertText("s", replacementRange: note.textView.selectedRange())      // "/s": nothing fits
        #expect(note.window.childWindows?.isEmpty != false)
        #expect(note.textView.slashMenu == nil)
    }
}
