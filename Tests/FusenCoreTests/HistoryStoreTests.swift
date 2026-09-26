import AppKit
import Foundation
import Testing
@testable import FusenCore

@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    /// Stands in for the monotonic clock; unaffected when a test sets `now` backwards on purpose.
    var uptime: TimeInterval = 1_000
    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        uptime += seconds
    }
}

@MainActor
func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FusenTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
func makeHistory(_ clock: TestClock) -> HistoryStore {
    HistoryStore(rootURL: makeTempDirectory(), now: { clock.now }, uptime: { clock.uptime })
}

@MainActor
struct HistoryStoreTests {
    let clock = TestClock()
    let id = UUID()
    let history: HistoryStore

    init() { history = makeHistory(clock) }

    private func texts() -> [String] { history.snapshots(for: id).map(history.text(of:)) }
    private func reasons() -> [SnapshotReason] { history.snapshots(for: id).map(\.reason) }

    /// An edit of `old` that replaces `removed` characters with `inserted` ones.
    private func edit(_ old: String, removed: Int, inserted: Int) {
        history.willEdit(id, removedLength: removed, insertedLength: inserted) { old }
    }

    @Test func checkpointSkipsBlankAndDuplicates() {
        #expect(!history.checkpoint(id, text: "  \n", reason: .launch))
        #expect(history.checkpoint(id, text: "a", reason: .launch))
        clock.advance(1)
        #expect(!history.checkpoint(id, text: "a", reason: .launch))
        #expect(history.checkpoint(id, text: "b", reason: .launch))
        #expect(texts() == ["b", "a"])
    }

    @Test func snapshotsInTheSameMillisecondNeverOverwrite() {
        // ⌘A ⌫ ⌘W within one instant: the pre-deletion text must survive the close snapshot.
        #expect(history.checkpoint(id, text: "full text", reason: .deletion))
        #expect(history.checkpoint(id, text: "after", reason: .deleted))
        #expect(texts() == ["after", "full text"])
    }

    @Test func clockGoingBackwardsKeepsNewestFirst() {
        history.checkpoint(id, text: "older", reason: .edit)
        clock.now = clock.now.addingTimeInterval(-3_600) // system clock set back an hour
        history.checkpoint(id, text: "newer", reason: .edit)
        #expect(texts() == ["newer", "older"])
    }

    @Test func firstEditSavesTheTextBeforeIt() {
        edit("original", removed: 0, inserted: 1)
        #expect(texts() == ["original"])
        #expect(reasons() == [.edit])
        // Continuous typing within the interval adds nothing.
        clock.advance(5)
        edit("original!", removed: 0, inserted: 1)
        #expect(texts().count == 1)
    }

    @Test func editingAfterTheIntervalSavesAgain() {
        edit("v1", removed: 0, inserted: 1)
        clock.advance(history.policy.interval + 1)
        edit("v1 and more", removed: 0, inserted: 1)
        #expect(texts() == ["v1 and more", "v1"])
    }

    @Test func longContinuousEditingIsSavedRegularly() {
        var text = "start"
        for _ in 0..<70 { // 70 × 10 s of non-stop typing
            edit(text, removed: 0, inserted: 1)
            text += "x"
            clock.advance(10)
        }
        #expect(texts().count >= 5)
    }

    @Test func holdingDeleteSavesTheTextBeforeTheRunOnce() {
        let full = String(repeating: "あ", count: 60)
        edit("", removed: 0, inserted: 1) // editing in progress; blank text is not saved
        clock.advance(1)
        var text = full
        for _ in 0..<50 { // 50 single-character deletions
            edit(text, removed: 1, inserted: 0)
            text.removeLast()
            clock.advance(0.1)
        }
        #expect(texts() == [full])
        #expect(reasons() == [.deletion])
    }

    @Test func smallDeletionsAddUpAcrossTyping() {
        edit("", removed: 0, inserted: 1)
        clock.advance(1)
        for i in 0..<10 { // 3 characters removed, then typing, ten times
            edit("text \(i)", removed: 3, inserted: 0)
            edit("text \(i)", removed: 0, inserted: 1)
            clock.advance(1)
        }
        // After 7 × 3 ≥ 20 removed characters: the text before the first removal, and the text just
        // before the removal that crossed the threshold (typing happened in between).
        #expect(texts() == ["text 6", "text 0"])
        #expect(reasons() == [.deletion, .deletion])
    }

    @Test func selectAllAndTypeSavesThePreviousText() {
        edit("", removed: 0, inserted: 1)
        clock.advance(1)
        let long = "とても大事なメモの本文。消したくない内容がここにある。"
        edit(long, removed: (long as NSString).length, inserted: 1)
        #expect(texts() == [long])
        #expect(reasons() == [.deletion])
    }

    @Test func textPastedOverASelectionSurvivesALaterDeletion() {
        edit("", removed: 0, inserted: 1)
        clock.advance(1)
        let before = "予定: 明日の午後に会議室Aで打ち合わせ"
        let after = "予定: あさっての午後に会議室Aで打ち合わせ"
        edit(before, removed: 2, inserted: 5) // "明日" replaced by pasted / IME-typed "あさっての"
        clock.advance(1)
        edit(after, removed: (after as NSString).length, inserted: 0) // then everything is deleted
        #expect(texts().contains(after))
        #expect(texts().contains(before))
    }

    @Test func aDeletionRightAfterLaunchIsNeverThinned() {
        let text = "起動したときの内容。これを全部消してしまった。"
        history.checkpoint(id, text: text, reason: .launch)
        edit(text, removed: 0, inserted: 0) // editing starts
        clock.advance(1)
        edit(text, removed: (text as NSString).length, inserted: 0) // ⌘A ⌫ as the first real edit
        #expect(reasons() == [.deletion]) // the launch snapshot now counts as "before a deletion"
        clock.advance(40 * 86_400)
        history.checkpoint(id, text: "later 1", reason: .edit)
        clock.advance(60)
        history.checkpoint(id, text: "later 2", reason: .edit)
        history.thin()
        #expect(texts().contains(text))
    }

    @Test func thinningKeepsAWeekThenHourlyThenDaily() {
        // Routine snapshots every 20 minutes for 40 days, with one deletion snapshot 20 days ago.
        let start = clock.now
        let total = 40 * 72
        for i in 0..<total {
            clock.now = start.addingTimeInterval(Double(i) * 1_200)
            history.checkpoint(id, text: "v\(i)", reason: i == 20 * 72 + 5 ? .deletion : .edit)
        }
        history.thin()
        let snapshots = history.snapshots(for: id)
        let now = clock.now
        func count(_ range: Range<Double>) -> Int {
            snapshots.filter { range.contains(now.timeIntervalSince($0.date)) && $0.reason == .edit }.count
        }
        #expect(count(0..<7 * 86_400) == 7 * 72)
        #expect(abs(count(7 * 86_400..<30 * 86_400) - 23 * 24) <= 2)
        #expect(abs(count(30 * 86_400..<100 * 86_400) - 10) <= 1)
        #expect(snapshots.contains { $0.reason == .deletion })
        #expect(snapshots.first.map(history.text(of:)) == "v\(total - 1)")
    }

    @Test func textDelta() {
        #expect(TextDelta.between("abc", "abc") == TextDelta(removed: 0, added: 0))
        #expect(TextDelta.between("今日は晴れ", "今日は雨") == TextDelta(removed: 2, added: 1))
        #expect(TextDelta.between("abcdef", "abXYef") == TextDelta(removed: 2, added: 2)) // same length
        #expect(TextDelta.between("aaaa", "aa") == TextDelta(removed: 2, added: 0))
        #expect(TextDelta.between("", "new") == TextDelta(removed: 0, added: 3))
    }
}
