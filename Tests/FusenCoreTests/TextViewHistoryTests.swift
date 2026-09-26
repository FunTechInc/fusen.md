import AppKit
import Testing
@testable import FusenCore

/// Drives a real (window-less) MarkdownTextView through the same delegate hook NoteWindowController
/// uses, to check which user actions produce history snapshots.
@MainActor
final class HookDelegate: NSObject, NSTextViewDelegate {
    let history: HistoryStore
    let id = UUID()
    let undo = UndoManager()

    init(history: HistoryStore) { self.history = history }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    // Same call as NoteWindowController.textView(_:shouldChangeTextInRanges:replacementStrings:).
    func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue],
                  replacementStrings: [String]?) -> Bool {
        history.textView(textView, willReplace: affectedRanges.map(\.rangeValue), with: replacementStrings, note: id)
        return true
    }
}

@MainActor
struct TextViewHistoryTests {
    let clock = TestClock()
    let history: HistoryStore
    let hook: HookDelegate

    init() {
        history = makeHistory(clock)
        hook = HookDelegate(history: history)
    }

    private func makeView(_ text: String) -> MarkdownTextView {
        let tv = MarkdownTextView(usingTextLayoutManager: true)
        tv.frame = NSRect(x: 0, y: 0, width: 280, height: 200)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.string = text // programmatic, bypasses the hook like loading a note does
        tv.delegate = hook
        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        // Establish "currently editing" so only deletion rules apply below.
        history.checkpoint(hook.id, text: text, reason: .launch)
        history.willEdit(hook.id, removedLength: 0, insertedLength: 0) { text }
        clock.advance(1)
        return tv
    }

    private func snapshotTexts() -> [String] { history.snapshots(for: hook.id).map(history.text(of:)) }

    @Test func imeCompositionIsNotADeletion() {
        let tv = makeView("メモ")
        // Compose a reading longer than the deletion threshold, convert it, then commit.
        // Each step replaces the whole marked range (> 20 characters) — without the marked-text
        // exclusion that would count as a large deletion and snapshot.
        let reading = "きょうはとてもいいてんきですねあしたもはれるといいですね"
        let converted = "今日はとてもいい天気ですね明日も晴れるといいですね"
        #expect((reading as NSString).length > history.policy.deletionThreshold)
        tv.setMarkedText(reading, selectedRange: NSRange(location: (reading as NSString).length, length: 0),
                         replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.setMarkedText(converted, selectedRange: NSRange(location: (converted as NSString).length, length: 0),
                         replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.insertText(converted, replacementRange: tv.markedRange())
        #expect(!tv.hasMarkedText())
        #expect(tv.string == "メモ" + converted)
        #expect(snapshotTexts() == ["メモ"]) // only the launch checkpoint
    }

    @Test func selectAllAndDeleteIsSaved() {
        let original = "# 大事なメモ\n- [ ] 牛乳\n- [ ] パン\n消えたら困る文章がここにあります。"
        let tv = makeView(original)
        tv.selectAll(nil)
        tv.deleteBackward(nil)
        #expect(tv.string.isEmpty)
        // The launch checkpoint already holds the same text, so nothing new is needed.
        #expect(snapshotTexts() == [original])

        // After further edits, a second large deletion saves the edited text.
        tv.insertText("新しい本文をここに書いて、また全部消してしまう。", replacementRange: tv.selectedRange())
        clock.advance(1)
        let edited = tv.string
        tv.selectAll(nil)
        tv.deleteBackward(nil)
        #expect(snapshotTexts() == [edited, original])
    }

    @Test func restoreIsUndoableAndKeepsReplacedText() {
        let tv = makeView("今の内容")
        tv.replaceAllText(with: "昔の内容", actionName: "履歴から復元")
        #expect(tv.string == "昔の内容")
        hook.undo.undo()
        #expect(tv.string == "今の内容")
    }
}

/// The same checks through the real TextKit 1 stack of the app (ConcealingLayoutManager).
@MainActor
struct TextKit1HistoryTests {
    let clock = TestClock()
    let history: HistoryStore
    let hook: HookDelegate

    init() {
        history = makeHistory(clock)
        hook = HookDelegate(history: history)
    }

    private func snapshotTexts() -> [String] { history.snapshots(for: hook.id).map(history.text(of:)) }

    @Test func japaneseTypedAtTheEndSurvivesALaterSelectAllDelete() {
        let e = ConcealedEditor("元のメモの内容。これも大事な文章です。")
        e.textView.delegate = hook
        history.checkpoint(hook.id, text: e.storage.string, reason: .launch)
        clock.advance(1)
        e.textView.selectAll(nil)
        e.textView.deleteBackward(nil) // ⌘A ⌫: the original is saved
        clock.advance(1)
        // Compose a sentence at the (now empty) end with the IME and commit it.
        let reading = "あしたのかいぎできまったことをぜんぶここにかいた"
        let converted = "明日の会議で決まったことを全部ここに書いた"
        e.textView.setMarkedText(reading, selectedRange: NSRange(location: (reading as NSString).length, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        e.textView.setMarkedText(converted, selectedRange: NSRange(location: (converted as NSString).length, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        e.textView.insertText(converted, replacementRange: e.textView.markedRange())
        #expect(e.storage.string == converted)
        clock.advance(30)
        e.textView.selectAll(nil)
        e.textView.deleteBackward(nil) // ⌘A ⌫ again: the composed sentence must be saved first
        #expect(snapshotTexts().contains(converted))
        #expect(snapshotTexts().contains("元のメモの内容。これも大事な文章です。"))
    }

    @Test func undoGoesThroughTheDelegate() {
        @MainActor final class Counter: NSObject, NSTextViewDelegate {
            let undo = UndoManager()
            var changes = 0, shouldChange = 0
            func undoManager(for view: NSTextView) -> UndoManager? { undo }
            func textDidChange(_ notification: Notification) { changes += 1 }
            func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue],
                          replacementStrings: [String]?) -> Bool { shouldChange += 1; return true }
        }
        let e = ConcealedEditor("abc")
        let counter = Counter()
        e.textView.delegate = counter
        e.textView.setSelectedRange(NSRange(location: 3, length: 0))
        e.textView.insertText("def", replacementRange: e.textView.selectedRange())
        let before = (counter.changes, counter.shouldChange)
        counter.undo.undo()
        #expect(e.storage.string == "abc")
        // Undo must be saved (textDidChange) and recorded (shouldChange) like any other edit.
        #expect(counter.changes > before.0)
        #expect(counter.shouldChange > before.1)
    }
}
