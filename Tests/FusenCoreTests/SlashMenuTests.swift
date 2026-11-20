import AppKit
import Testing
@testable import FusenCore

/// The "/" menu: Notion's slash commands for every kind of block a note can hold.
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
        #expect(SlashCommand.matching("task") == [.todo, .waiting, .doing])
        #expect(SlashCommand.matching("div") == [.divider])
        #expect(SlashCommand.matching("zzz").isEmpty)
        // As in Notion, every block is in the list, in Notion's order (the signals after the checkbox,
        // the card where the callout is).
        #expect(SlashCommand.allCases == [.text, .h1, .h2, .h3, .h4, .bullet, .ordered, .todo, .waiting, .doing,
                                          .card, .quote, .divider, .code])
        #expect(SlashCommand.matching("h") == [.h1, .h2, .h3, .h4, .divider])   // "hr"
        #expect(SlashCommand.matching("heading2") == [.h2])
        #expect(SlashCommand.matching("見出し") == [.h1, .h2, .h3, .h4])
        #expect(SlashCommand.matching("見出し3") == [.h3])
        #expect(SlashCommand.matching("みだし") == [.h1, .h2, .h3, .h4])
        #expect(SlashCommand.matching("list") == [.bullet, .ordered, .todo])
        #expect(SlashCommand.matching("りすと") == [.bullet, .ordered])
        #expect(SlashCommand.matching("quote") == [.quote])
        #expect(SlashCommand.matching("引") == [.quote])
        #expect(SlashCommand.matching("code") == [.code])
        #expect(SlashCommand.matching("te") == [.text])
        // The Markdown that makes the block finds it too.
        #expect(SlashCommand.matching("#") == [.h1, .h2, .h3, .h4])
        #expect(SlashCommand.matching("##") == [.h2, .h3, .h4])
        #expect(SlashCommand.matching("-") == [.bullet, .divider])
        #expect(SlashCommand.matching("1.") == [.ordered])
        #expect(SlashCommand.matching("[") == [.todo, .waiting, .doing])
        #expect(SlashCommand.matching("[/") == [.doing])
        #expect(SlashCommand.matching(">") == [.quote])
        #expect(SlashCommand.matching("```") == [.code])
    }

    @Test func slashAtTheStartOfALineOpensTheMenu() {
        let e = ConcealedEditor("")
        e.type("/")
        #expect(e.textView.slashMenu == SlashMenu(trigger: 0, commands: SlashCommand.allCases, selected: 0))
        e.type("c")
        #expect(e.textView.slashMenu?.commands == [.todo, .card, .code])     // "check", "card" and "code"
        #expect(e.textView.slashMenu?.selected == 0)
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

    @Test func theLineBecomesTheBlock() {
        func turned(_ text: String, at caret: Int? = nil, _ typed: String) -> ConcealedEditor {
            let e = ConcealedEditor(text)
            e.click(caret ?? (text as NSString).length)
            e.type(typed)
            returnKey(e)
            return e
        }
        // On an empty line: the block's marker, and the caret after it.
        for (typed, text) in [("/h1", "# "), ("/h2", "## "), ("/h3", "### "), ("/h4", "#### "), ("/bullet", "- "),
                              ("/number", "1. "), ("/quote", "> "), ("/todo", "- [ ] "), ("/text", "")] {
            let e = turned("", typed)
            #expect(e.text == text, "\(typed)")
            #expect(e.caret == (text as NSString).length, "\(typed)")
            #expect(e.textView.slashMenu == nil)
            if !text.isEmpty {
                e.undo.undo()                                                 // one step
                #expect(e.text == typed, "\(typed)")
            }
        }
        // After text and a space: the line becomes the block, and its text stays.
        #expect(turned("買い物", " /h2").text == "## 買い物 ")
        #expect(turned("買い物", " /かじょうがき").text == "- 買い物 ")
        #expect(turned("買い物", " /いんよう").text == "> 買い物 ")
        // Another block's marker is replaced.
        #expect(turned("- 項目", at: 2, "/h1").text == "# 項目")
        #expect(turned("## 見出し", at: 3, "/text").text == "見出し")
        #expect(turned("> 引用", at: 2, "/number").text == "1. 引用")
        #expect(turned("# 見出し", at: 2, "/doing").text == "- [/] 見出し")
        #expect(turned("- [x] 済み", at: 6, "/bullet").text == "- 済み")
        let caret = turned("- 項目", at: 2, "/h3")
        #expect(caret.text == "### 項目" && caret.caret == 4)
        let later = turned("- 項目", " /h3")
        #expect(later.text == "### 項目 " && later.caret == 7)
        // The indentation that nests an item stays for what can be nested, and goes for a heading.
        #expect(turned("- 親\n\t- 子", at: 7, "/number").text == "- 親\n\t1. 子")
        #expect(turned("- 親\n\t- 子", at: 7, "/text").text == "- 親\n\t子")
        #expect(turned("- 親\n\t- 子", at: 7, "/h2").text == "- 親\n## 子")
        // A numbered item goes on counting after the one above it — of the same list only.
        #expect(turned("1. 一\n2. 二\n", "/number").text == "1. 一\n2. 二\n3. ")
        #expect(turned("1. 一\n\t", "/number").text == "1. 一\n\t1. ")
        // A code block: its fences, and the caret between them; below a line that holds something.
        let code = turned("", "/code")
        #expect(code.text == "```\n\n```\n" && code.caret == 4)
        let below = turned("本文\n次", at: 2, " /code")
        #expect(below.text == "本文 \n```\n\n```\n次" && below.caret == 8)
        code.undo.undo()
        #expect(code.text == "/code")
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
        #expect(e.text == "# ")                                               // the second command: heading 1
        // Up from the first goes to the last.
        let wrap = ConcealedEditor("")
        wrap.type("/")
        wrap.key { wrap.textView.moveUp(nil) }
        #expect(wrap.textView.slashMenu?.selected == SlashCommand.allCases.count - 1)
        // The highlighted command stays highlighted while the list narrows around it.
        let keep = ConcealedEditor("")
        keep.type("/")
        for _ in 0..<8 { keep.key { keep.textView.moveDown(nil) } }           // waiting
        keep.type("task")
        #expect(keep.textView.slashMenu?.commands == [.todo, .waiting, .doing])
        #expect(keep.textView.slashMenu?.selected == 1)
    }

    @Test func itOpensOnlyWhereACommandCanStart() {
        for (text, typed) in [("11", "/20"), ("a", "/"), ("```\n", "/"), (":::card orange ", "/"), ("`x ", "/x`")] {
            let e = ConcealedEditor(text + (text.hasPrefix(":::card") ? "\n\n:::" : ""))
            e.click((text as NSString).length)
            e.type(typed)
            #expect(e.textView.slashMenu == nil, "\(text)\(typed)")
        }
        // What is typed after it can turn the slash into code: then it was not meant as a command.
        let code = ConcealedEditor("`a ")
        code.click(3)
        code.type("/")
        #expect(code.textView.slashMenu != nil)
        code.type("`")
        #expect(code.textView.slashMenu == nil && code.text == "`a /`")
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

    @Test func onTheHighlightedRowTheSignalsAreWhite() throws {
        // The color of the icon at a point of it (fractions of its size, from the top left).
        func color(_ command: SlashCommand, selected: Bool, _ fx: CGFloat, _ fy: CGFloat) throws -> NSColor {
            let image = try #require(command.icon(theme: MarkdownTheme(), isSelected: selected))
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 56, pixelsHigh: 56, bitsPerSample: 8, samplesPerPixel: 4,
                                                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: 56, height: 56))
            NSGraphicsContext.restoreGraphicsState()
            return try #require(rep.colorAt(x: Int(56 * fx), y: Int(56 * fy))?.usingColorSpace(.sRGB))
        }
        func isWhite(_ c: NSColor) -> Bool { c.alphaComponent > 0.9 && c.redComponent > 0.95 && c.greenComponent > 0.95 && c.blueComponent > 0.95 }
        // In progress: the arc, at 2 o'clock. Blue in the list, white on the highlight (which is blue itself).
        let arc = try color(.doing, selected: false, 0.87, 0.29)
        #expect(arc.blueComponent > 0.8 && arc.redComponent < 0.3)
        #expect(isWhite(try color(.doing, selected: true, 0.87, 0.29)))
        // Waiting: a bar of the pause sign, and its ring at 9 o'clock.
        let bar = try color(.waiting, selected: false, 0.35, 0.5)
        #expect(bar.redComponent > 0.75 && bar.blueComponent < 0.25)
        #expect(isWhite(try color(.waiting, selected: true, 0.35, 0.5)))
        #expect(isWhite(try color(.waiting, selected: true, 0.055, 0.5)))
    }

    private func render(_ panel: SlashMenuPanel, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["MARKDOWN_STICKIES_RENDER_DIR"], let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    @Test func theListIsAWindowUnderTheCaret() throws {
        let note = TestNote("本文\n")
        note.textView.setSelectedRange(NSRange(location: 3, length: 0))
        note.textView.insertText("/", replacementRange: note.textView.selectedRange())
        let panel = try #require(note.window.childWindows?.first as? SlashMenuPanel)
        #expect(panel.frame.height > 100 && !panel.canBecomeKey)
        // The list is longer than the window: it shows its first rows, and follows the highlight.
        #expect(panel.frame.height < CGFloat(SlashCommand.allCases.count) * SlashMenuPanel.rowHeight)
        #expect(panel.shownRows == 0...(SlashMenuPanel.visibleRows - 1))
        for _ in 0..<(SlashCommand.allCases.count - 1) { note.textView.moveDown(nil) }
        #expect(panel.shownRows.contains(SlashCommand.allCases.count - 1) && !panel.shownRows.contains(0))
        try render(panel, "slash-menu-end.png")
        for _ in 0..<4 { note.textView.moveUp(nil) }                          // in progress
        #expect(note.textView.slashMenu.map { $0.commands[$0.selected] } == .doing)
        try render(panel, "slash-menu-doing.png")
        for _ in 0..<4 { note.textView.moveDown(nil) }
        note.textView.moveDown(nil)                                           // around to the first
        #expect(note.textView.slashMenu?.selected == 0)
        #expect(panel.shownRows.contains(0))
        try render(panel, "slash-menu.png")
        note.textView.insertText("s", replacementRange: note.textView.selectedRange())      // "/s": nothing fits
        #expect(note.window.childWindows?.isEmpty != false)
        #expect(note.textView.slashMenu == nil)
    }
}
