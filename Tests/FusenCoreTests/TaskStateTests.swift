import AppKit
import Testing
@testable import FusenCore

/// To-do states: "- [ ]" not started, "- [>]" waiting, "- [/]" in progress, "- [x]" done. The two in the
/// middle are the signals. (ConcealedEditor is in ConcealmentTests.)
@MainActor
struct TaskStateTests {
    private let all = "- [ ] 未着手\n- [>] 待機\n- [/] 進行中\n- [x] 完了"

    /// Where the state of the to-do on the line containing `text` is written.
    private func check(_ e: ConcealedEditor, _ text: String) -> Int {
        let line = ConcealedEditing.line(at: e.index(of: text), in: e.storage)
        return e.storage.attribute(.mdTaskToggle, at: line.range.location, effectiveRange: nil) as? Int ?? -1
    }

    private func item(_ state: TaskState) -> NSMenuItem {
        let item = NSMenuItem(title: state.title, action: nil, keyEquivalent: "")
        item.tag = TaskState.allCases.firstIndex(of: state)!
        return item
    }

    // MARK: Markdown

    @Test func everyStateIsAToDo() {
        let e = ConcealedEditor(all)
        for (text, state) in [("未着手", TaskState.todo), ("待機", .waiting), ("進行中", .doing), ("完了", .done)] {
            let line = ConcealedEditing.line(at: e.index(of: text), in: e.storage)
            #expect(line.kind == .task, "\(text)")
            #expect(TaskState(character: (e.text as NSString).character(at: check(e, text))) == state, "\(text)")
            #expect(e.property(at: line.range.location) == .controlCharacter, "\(text)") // the box of its icon
            // Only a done to-do is struck through.
            let struck = e.storage.attribute(.strikethroughStyle, at: e.index(of: text), effectiveRange: nil) != nil
            #expect(struck == (state == .done), "\(text)")
        }
        // Text after every kind of marker starts in the same column.
        #expect(abs(e.x(at: e.index(of: "待機")) - e.x(at: e.index(of: "未着手"))) < 0.5)
        #expect(abs(e.x(at: e.index(of: "進行中")) - e.x(at: e.index(of: "未着手"))) < 0.5)
    }

    @Test func otherCharactersInBracketsAreNotToDos() {
        let e = ConcealedEditor("- [?] 不明\n- [-] 中止")
        #expect(ConcealedEditing.line(at: 0, in: e.storage).kind == .bullet)
        #expect(ConcealedEditing.line(at: e.index(of: "中止"), in: e.storage).kind == .bullet)
    }

    @Test func transitions() {
        #expect(TaskState.allCases.map(\.advanced) == [.done, .doing, .done, .todo])
        #expect(TaskState.allCases.map(\.toggledWaiting) == [.waiting, .todo, .waiting, .waiting])
    }

    // MARK: Changing the state

    @Test func aClickMovesAToDoOneStepOn() {
        let e = ConcealedEditor(all)
        e.click(e.index(of: "完了") + 2)
        for text in ["未着手", "待機", "進行中", "完了"] {
            e.key { e.textView.clickTask(checkLocation: check(e, text), option: false) }
        }
        #expect(e.text == "- [x] 未着手\n- [/] 待機\n- [x] 進行中\n- [ ] 完了")
        #expect(e.caret == e.index(of: "完了") + 2) // a click on a checkbox leaves the caret where it was
    }

    @Test func anOptionClickMakesAToDoWait() {
        let e = ConcealedEditor(all)
        for text in ["未着手", "待機", "進行中", "完了"] {
            e.key { e.textView.clickTask(checkLocation: check(e, text), option: true) }
        }
        #expect(e.text == "- [>] 未着手\n- [ ] 待機\n- [>] 進行中\n- [>] 完了")
    }

    @Test func theFlowFromPlainToDoToDone() {
        let e = ConcealedEditor("- [ ] 資料を作る")
        e.key { e.textView.clickTask(checkLocation: check(e, "資料"), option: true) }
        #expect(e.text == "- [>] 資料を作る")
        e.key { e.textView.clickTask(checkLocation: check(e, "資料"), option: false) }
        #expect(e.text == "- [/] 資料を作る")
        e.key { e.textView.clickTask(checkLocation: check(e, "資料"), option: false) }
        #expect(e.text == "- [x] 資料を作る")
        e.undo.undo()
        #expect(e.text == "- [/] 資料を作る")
    }

    @Test func theShortcutsActOnTheLineOfTheCaret() {
        let e = ConcealedEditor("メモ\n- [ ] 資料を作る\nおわり")
        e.click(e.index(of: "を作る"))
        e.key { e.textView.toggleTaskWaiting(nil) }
        #expect(e.text == "メモ\n- [>] 資料を作る\nおわり")
        e.key { e.textView.advanceTask(nil) }
        #expect(e.text == "メモ\n- [/] 資料を作る\nおわり")
        #expect(e.caret == e.index(of: "を作る"))
        // Not on a to-do: nothing changes.
        e.click(0)
        e.key { e.textView.advanceTask(nil) }
        #expect(e.text == "メモ\n- [/] 資料を作る\nおわり")
    }

    @Test func theShortcutsActOnEverySelectedToDo() {
        let e = ConcealedEditor("- [ ] a\n本文\n- [/] b\n\t- [x] c\n- [ ] d")
        let selection = NSRange(location: e.index(of: "a"), length: e.index(of: "c") - e.index(of: "a") + 1)
        e.textView.setSelectedRange(selection)
        e.key { e.textView.toggleTaskWaiting(nil) }
        #expect(e.text == "- [>] a\n本文\n- [>] b\n\t- [>] c\n- [ ] d")   // "d" is not selected
        #expect(e.textView.selectedRange() == selection)
        e.undo.undo()                                                    // one step for all of them
        #expect(e.text == "- [ ] a\n本文\n- [/] b\n\t- [x] c\n- [ ] d")
        e.textView.setSelectedRange(selection)
        e.key { e.textView.toggleTaskWaiting(nil) }
        e.key { e.textView.toggleTaskWaiting(nil) }                      // all waiting already: none waits
        #expect(e.text == "- [ ] a\n本文\n- [ ] b\n\t- [ ] c\n- [ ] d")
        e.key { e.textView.advanceTask(nil) }
        #expect(e.text == "- [x] a\n本文\n- [x] b\n\t- [x] c\n- [ ] d")
    }

    @Test func aSelectionEndingAtALineStartLeavesThatLineOut() {
        let e = ConcealedEditor("- [ ] a\n- [ ] b")
        e.textView.setSelectedRange(NSRange(location: 0, length: e.index(of: "- [ ] b")))
        e.key { e.textView.toggleTaskWaiting(nil) }
        #expect(e.text == "- [>] a\n- [ ] b")
    }

    @Test func theMenuSetsAStateAndTurnsLinesIntoToDos() {
        let e = ConcealedEditor("買い物\n- 項目\n1. 手順\n- [x] 済み\n# 見出し\n\n  字下げ")
        e.textView.selectAll(nil)
        e.key { e.textView.setTaskState(item(.doing)) }
        #expect(e.text == "- [/] 買い物\n- [/] 項目\n1. [/] 手順\n- [/] 済み\n# 見出し\n\n  - [/] 字下げ")
        e.undo.undo()
        #expect(e.text == "買い物\n- 項目\n1. 手順\n- [x] 済み\n# 見出し\n\n  字下げ")
        // On an empty line, at the caret: a new to-do, the caret after its marker.
        let empty = ConcealedEditor("a\n")
        empty.click(2)
        empty.key { empty.textView.setTaskState(item(.waiting)) }
        #expect(empty.text == "a\n- [>] ")
        #expect(empty.caret == (empty.text as NSString).length)
        // The caret keeps its place in the text of a line that becomes a to-do.
        let caret = ConcealedEditor("買い物")
        caret.click(1)
        caret.key { caret.textView.setTaskState(item(.todo)) }
        #expect(caret.text == "- [ ] 買い物")
        #expect(caret.caret == caret.index(of: "い"))
    }

    @Test func theMenuItemsAreOnlyForToDos() {
        let e = ConcealedEditor("本文\n- [/] 進行中")
        let advance = NSMenuItem(title: "", action: #selector(MarkdownTextView.advanceTask(_:)), keyEquivalent: "")
        e.click(0)
        #expect(!e.textView.validateUserInterfaceItem(advance))
        e.click(e.index(of: "進行中"))
        #expect(e.textView.validateUserInterfaceItem(advance))
        let doing = item(.doing), done = item(.done)
        doing.action = #selector(MarkdownTextView.setTaskState(_:))
        done.action = #selector(MarkdownTextView.setTaskState(_:))
        #expect(e.textView.validateUserInterfaceItem(doing) && doing.state == .on)
        #expect(e.textView.validateUserInterfaceItem(done) && done.state == .off)
    }

    // MARK: Typing

    @Test func typingTheBracketsMakesASignal() {
        let doing = ConcealedEditor("")
        doing.type("[/]資料")
        #expect(doing.text == "- [/] 資料")
        let waiting = ConcealedEditor("- ")
        waiting.click(2)
        waiting.type("[>]次")
        #expect(waiting.text == "- [>] 次")
        let nested = ConcealedEditor("\t")
        nested.click(1)
        nested.type("[/]")
        #expect(nested.text == "\t- [/] ")
        // In the middle of a line the brackets stay as typed.
        let middle = ConcealedEditor("本文 ")
        middle.click(3)
        middle.type("[/]")
        #expect(middle.text == "本文 [/]")
        // The plain one still works.
        let plain = ConcealedEditor("")
        plain.type("[]牛乳")
        #expect(plain.text == "- [ ] 牛乳")
    }

    @Test func returnAfterASignalStartsAPlainToDo() {
        let e = ConcealedEditor("- [/] 進行中")
        e.click((e.text as NSString).length)
        e.key { e.textView.insertNewline(nil) }
        #expect(e.text == "- [/] 進行中\n- [ ] ")
        // At the start of its text: an empty to-do above, this one keeps its state.
        let start = ConcealedEditor("- [>] 待機")
        start.click(start.index(of: "待機"))
        start.key { start.textView.insertNewline(nil) }
        #expect(start.text == "- [ ] \n- [>] 待機")
        // Backspace at the start of its text makes it plain text, like any to-do.
        let plain = ConcealedEditor("- [/] 進行中")
        plain.click(plain.index(of: "進行中"))
        plain.key { plain.textView.deleteBackward(nil) }
        #expect(plain.text == "進行中")
    }

    // MARK: Elsewhere

    @Test func theTitleLeavesTheMarkerOut() {
        #expect(NoteTitle.derive(from: "- [/] 資料を作る\n本文") == "資料を作る")
        #expect(NoteTitle.derive(from: "- [>] 次にやる") == "次にやる")
    }

    @Test func notionGetsSignalsAsUncheckedToDosInTheirColors() {
        // In Notion's Markdown a color is an attribute of the to-do's tag; the other to-dos stay "- [ ]".
        let styler = MarkdownStyler()
        #expect(NotionMarkdown.export("- [/] 進行中\n- [>] 待機\n- [x] 完了\n- [ ] 未着手", styler: styler) == """
        <todo checked="false" color="blue">
        進行中
        </todo>

        <todo checked="false" color="orange">
        待機
        </todo>

        - [x] 完了
        - [ ] 未着手
        """)
    }

    // MARK: Drawing

    @Test func signalsAreDrawnInTheirColors() throws {
        let e = ConcealedEditor("- [/] 進行中\n- [>] 待機\n- [ ] 未着手")
        let data = try #require(e.png())
        let rep = try #require(NSBitmapImageRep(data: data))
        let scale = CGFloat(rep.pixelsWide) / e.textView.bounds.width
        let origin = e.textView.textContainerOrigin
        func color(_ rect: NSRect, _ fx: CGFloat, _ fy: CGFloat) -> NSColor? {
            let x = (origin.x + rect.minX + rect.width * fx) * scale, y = (origin.y + rect.minY + rect.height * fy) * scale
            return rep.colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB)
        }
        func isBlue(_ c: NSColor?) -> Bool { c.map { $0.blueComponent > 0.8 && $0.redComponent < 0.3 && $0.greenComponent < 0.65 } ?? false }
        func isOrange(_ c: NSColor?) -> Bool { c.map { $0.redComponent > 0.75 && $0.greenComponent > 0.3 && $0.greenComponent < 0.6 && $0.blueComponent < 0.25 } ?? false }
        // The ring under the arc: the text color, faint (a pale gray on the view's white).
        func isRing(_ c: NSColor?) -> Bool { c.map { $0.saturationComponent < 0.08 && $0.brightnessComponent > 0.75 && $0.brightnessComponent < 0.93 } ?? false }
        // Nothing drawn: the view's (white) background.
        func isEmpty(_ c: NSColor?) -> Bool { c.map { $0.alphaComponent < 0.1 || $0.brightnessComponent > 0.95 && $0.saturationComponent < 0.05 } ?? true }

        // In progress: the ring with a bold arc on it, from 12 o'clock a third of the way round.
        let ring = try #require(e.layoutManager.taskIconRect(forCharacterAt: 0))
        #expect(ring.width == e.styler.theme.fontSize)
        #expect(isBlue(color(ring, 0.87, 0.29)))        // at 2 o'clock: on the arc
        #expect(isBlue(color(ring, 0.5, 0.07)))         // at 12 o'clock: where the arc starts
        #expect(isRing(color(ring, 0.07, 0.5)))         // at 9 o'clock: the ring
        #expect(isRing(color(ring, 0.5, 0.93)))         // at 6 o'clock
        #expect(isEmpty(color(ring, 0.5, 0.5)))

        // Waiting: a pause sign, all in orange — a ring, and two bars with a gap between them in its middle.
        let pause = try #require(e.layoutManager.taskIconRect(forCharacterAt: e.index(of: "- [>]")))
        #expect(isOrange(color(pause, 0.055, 0.5)) && isOrange(color(pause, 0.5, 0.945)) && isOrange(color(pause, 0.5, 0.055)))
        #expect(isOrange(color(pause, 0.35, 0.5)) && isOrange(color(pause, 0.65, 0.5)))    // the bars
        #expect(isEmpty(color(pause, 0.5, 0.5)))                                            // between them
        #expect(isEmpty(color(pause, 0.5, 0.25)) && isEmpty(color(pause, 0.2, 0.5)))        // between the bars and the ring

        if let dir = ProcessInfo.processInfo.environment["MARKDOWN_STICKIES_RENDER_DIR"] {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("signals.png"))
        }
    }

    @Test func inANoteTheRingsOfToDosInProgressAreLayers() throws {
        let e = ConcealedEditor("- [/] 一つ目\n- [>] 待機\n本文\n\t- [/] 二つ目")
        #expect(e.textView.spinnerOverlay == nil)            // not in a window: the layout manager draws the arcs too
        #expect(!e.layoutManager.doingTasksAreAnimated)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView?.addSubview(e.textView)
        let overlay = try #require(e.textView.spinnerOverlay)
        #expect(e.layoutManager.doingTasksAreAnimated)
        e.textView.updateTaskSpinners()
        let origin = e.textView.textContainerOrigin
        let expected = [0, e.index(of: "- [/] 二つ目")].compactMap { e.layoutManager.taskIconRect(forCharacterAt: $0) }
            .map { $0.offsetBy(dx: origin.x, dy: origin.y) }
        #expect(overlay.rings.map(\.frame) == expected)
        #expect(expected.count == 2)
        #expect(!overlay.isTurning)                          // the window is not on screen
        overlay.isAnimating = true
        #expect(overlay.isTurning)
        // With the Markdown shown as typed there are no icons at all.
        e.setConceals(false)
        e.textView.updateTaskSpinners()
        #expect(overlay.rings.isEmpty)
        e.setConceals(true)
        // A to-do that is finished loses its ring.
        e.key { e.textView.clickTask(checkLocation: check(e, "一つ目"), option: false) }
        e.textView.updateTaskSpinners()
        #expect(overlay.rings.count == 1)
    }

    @Test func textComposedAboveAToDoInProgressDoesNotChangeItsSignal() throws {
        // While the IME composes, the note is not restyled, so a to-do further down is no longer where its
        // attributes said it was. Its state is read from its own prefix, which moved with it.
        let note = TestNote("本文\n- [/] 作業")
        let storage = try #require(note.textView.textStorage)
        note.textView.setSelectedRange(NSRange(location: 2, length: 0))
        note.textView.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let prefix = (storage.string as NSString).range(of: "- [/]").location
        #expect(MarkdownStyler.taskCheck(at: prefix, in: storage) == prefix + 3)
        #expect(MarkdownStyler.taskState(at: prefix, in: storage) == .doing)
        note.textView.updateTaskSpinners()
        #expect(note.textView.spinnerOverlay?.rings.count == 1)  // the arc stays
        note.textView.unmarkText()
    }
}
