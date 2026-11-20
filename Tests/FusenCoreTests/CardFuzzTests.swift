import AppKit
import Testing
@testable import FusenCore

/// Many keys, pressed without a plan, in notes with cards, rows and signals: nothing may crash, the caret
/// may never end up on a line that shows nothing, and the cards must stay whole. (Kept short: every test
/// here runs on the main actor, and the tests that wait for a timer wait behind them. More seeds and
/// steps are worth a run after a change to the editing rules.)
@MainActor
struct CardFuzzTests {
    /// A small generator, so that a failure can be repeated from its seed.
    private struct Random {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(max(bound, 1)))
        }
    }

    nonisolated private static let notes = [
        "本文\n:::card orange A\n- [/] 一\n- [ ] 二\n:::\nおわり",
        "::::columns\n:::card orange A\n- [/] 一\n二\n:::\n:::card purple B\n短い\n:::\n::::",
        "前\n::::columns\n:::card blue \n\n:::\n:::card red 名前\n- [>] 待機\n\t- 子\n:::\n:::card C\n:::\n::::\n:::card green 単独\n> 引用\n---\n:::\n\n後\n",
    ]

    @Test(arguments: 0..<notes.count, [1]) func keysPressedWithoutAPlan(note: Int, seed: Int) {
        let e = ConcealedEditor(Self.notes[note], width: 340)
        let window = NSWindow(contentRect: e.textView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = e.textView
        window.makeFirstResponder(e.textView)
        defer { window.orderOut(nil) }
        NoteWindowController.restyle(e.textView, with: e.styler)
        var random = Random(state: UInt64(seed * 7919 + note))
        let cardCount = e.layoutManager.cardGeometries().count
        var structuralEdits = 0
        let commands: [Selector] = [
            #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveLeftAndModifySelection(_:)),
            #selector(NSResponder.moveRightAndModifySelection(_:)), #selector(NSResponder.moveUpAndModifySelection(_:)),
            #selector(NSResponder.moveDownAndModifySelection(_:)), #selector(NSResponder.deleteBackward(_:)),
            #selector(NSResponder.deleteForward(_:)), #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)),
            #selector(NSResponder.insertBacktab(_:)), #selector(NSResponder.deleteWordBackward(_:)),
            #selector(NSResponder.moveWordLeft(_:)), #selector(NSResponder.moveWordRight(_:)),
            #selector(NSResponder.deleteToBeginningOfLine(_:)), #selector(NSResponder.moveToEndOfParagraph(_:)),
        ]
        for step in 0..<250 {
            let length = (e.text as NSString).length
            // Typing over or deleting a selection that holds a card, Backspace at a title's start and undo
            // take cards away on purpose: from then on only the caret and the crashes are checked.
            let before = e.textView.selectedRange()
            let beforeLine = ConcealedEditing.line(at: before.location, in: e.storage)
            if before.length > 0 || (beforeLine.kind == .cardOpen && before.location == beforeLine.contentStart) { structuralEdits += 1 }
            switch random.next(12) {
            case 0:
                e.click(random.next(length + 1))
            case 1, 2:
                e.type(["あ", "a", " ", "x", "[]", "/"][random.next(6)])
                e.textView.closeSlashMenu()
            case 3:
                e.key { e.textView.advanceTask(nil) }
            case 4:
                e.key { e.textView.toggleTaskWaiting(nil) }
            case 5 where random.next(8) == 0:
                structuralEdits += 1
                e.undo.undo()
                NoteWindowController.restyle(e.textView, with: e.styler)
            default:
                e.key { e.textView.doCommand(by: commands[random.next(commands.count)]) }
            }
            e.layoutManager.ensureLayout(for: e.layoutManager.textContainers[0])
            let selection = e.textView.selectedRange()
            let line = ConcealedEditing.line(at: selection.location, in: e.storage)
            if selection.length == 0 {
                #expect(!line.kind.isHiddenLine, "note \(note) seed \(seed) step \(step): caret \(selection.location) in \(e.text.debugDescription)")
                #expect(selection.location >= line.contentStart || line.prefix == nil,
                        "note \(note) seed \(seed) step \(step): caret \(selection.location) in a marker of \(e.text.debugDescription)")
            }
            // What the styler reads as cards is drawn as cards.
            _ = e.layoutManager.cardGeometries()
            _ = CardArrangement(e.storage)
            if structuralEdits == 0 {
                #expect(e.layoutManager.cardGeometries().count >= cardCount,
                        "note \(note) seed \(seed) step \(step): a card was lost in \(e.text.debugDescription)")
            }
        }
        #expect(CardArrangement(e.storage).text == e.text)
    }
}
