import AppKit

enum SnapshotReason: String, CaseIterable, Sendable {
    /// The text before an edit, taken at most every `Policy.interval` while editing.
    case edit
    /// The text before a large deletion or replacement (select-all + type, paste over, cut, Replace All,
    /// holding Delete, several small deletions adding up).
    case deletion
    /// The text when the sticky was closed (moved to the trash).
    case deleted
    /// The text just before an older version was restored over it.
    case restore
    /// The text just before Writing Tools rewrote it.
    case writingtools
    /// The file on disk after another app changed it, just before this app overwrote it.
    case external
    /// Checkpoint at app launch.
    case launch
    /// The text just before it was replaced with the note's content in Notion.
    case notionimport

    var label: String {
        switch self {
        case .edit: "編集前"
        case .deletion: "大きな削除の直前"
        case .deleted: "閉じたとき"
        case .restore: "復元の直前"
        case .writingtools: "作文ツールの直前"
        case .external: "ほかのアプリでの変更"
        case .launch: "起動時"
        case .notionimport: "Notionから取り込む直前"
        }
    }

    /// Routine snapshots may be thinned out. The others mark a moment right before text was
    /// removed or replaced, which is exactly what someone comes back for days later.
    var isRoutine: Bool { self == .edit || self == .launch }
}

struct Snapshot: Hashable, Sendable {
    let url: URL
    let date: Date
    let reason: SnapshotReason
}

/// Earlier versions of each note, as plain files: history/<uuid>/<UTC stamp>-<reason>.md.
///
/// Snapshots hold the text *before* it changes, so every entry is a state the note was really in and
/// the current text (notes/<uuid>.md) is always the newest version. See `willEdit` for the rules.
/// Identical consecutive snapshots are skipped. `thin()` keeps everything from the last 7 days;
/// after that, routine snapshots are reduced to the newest per hour (up to 30 days) and then per day,
/// while every other kind is kept forever.
@MainActor
final class HistoryStore {
    struct Policy {
        /// While editing, the text before an edit is saved if the last snapshot is this old.
        var interval: TimeInterval = 120
        /// Characters removed (in one edit, or added up since the last snapshot) that trigger a snapshot.
        var deletionThreshold = 20
        var keepEverything: TimeInterval = 7 * 86_400
        var keepHourly: TimeInterval = 30 * 86_400
    }

    let rootURL: URL
    var policy = Policy()
    /// Called after a snapshot file is written.
    var onChange: (() -> Void)?

    private let now: () -> Date
    /// Monotonic clock for intervals, so changing the system clock cannot stop snapshots.
    private let uptime: () -> TimeInterval
    private var newestText: [UUID: String] = [:]
    private var newestDate: [UUID: Date] = [:]
    private var lastSnapshotUptime: [UUID: TimeInterval] = [:]
    private var tracking: [UUID: DeletionTracking] = [:]

    /// Removals since the last snapshot. `baseline` is the text before the first of them.
    private struct DeletionTracking {
        var removed = 0
        var baseline: String?
        var insertedSinceBaseline = false
        /// A deletion snapshot was just taken for an ongoing run of pure deletions (holding Delete),
        /// so further deletions in the same run need no more snapshots.
        var inSavedRun = false
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return f
    }()

    init(rootURL: URL,
         now: @escaping () -> Date = { Date() },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.rootURL = rootURL
        self.now = now
        self.uptime = uptime
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    // MARK: Recording

    /// Entry point for NSTextViewDelegate.textView(_:shouldChangeTextInRanges:replacementStrings:).
    /// nil replacements = attribute-only change. While Writing Tools is rewriting, the text was saved in
    /// `textViewWritingToolsWillBegin`.
    ///
    /// Edits of the IME's marked (uncommitted) text count as insertions only: converting "にほんご" to
    /// "日本語" replaces the reading but deletes nothing the user wrote, yet the composed text is new
    /// text that a later deletion must not lose. (AppKit reports marked text even for the very first
    /// keystroke of a composition, with a zero-length range at the caret.) Typing over a selection is
    /// different: that first edit replaces the selection, which is a real deletion.
    func textView(_ textView: NSTextView, willReplace ranges: [NSRange], with replacements: [String]?, note id: UUID) {
        guard let replacements else { return }
        if textView.isWritingToolsActive { return }
        let inserted = replacements.reduce(0) { $0 + ($1 as NSString).length }
        if textView.hasMarkedText() {
            let marked = textView.markedRange()
            if ranges.contains(where: { NSIntersectionRange($0, marked).length > 0 || $0 == marked }) {
                willEdit(id, removedLength: 0, insertedLength: inserted) { textView.string }
                return
            }
        }
        let removed = ranges.reduce(0) { $0 + $1.length }
        willEdit(id, removedLength: removed, insertedLength: inserted) { textView.string }
    }

    /// Call before the text of note `id` changes; `currentText` returns the text before the change.
    ///
    /// Saves the text before the edit when the last snapshot is `interval` old, and before any edit
    /// that removes `deletionThreshold` characters — at once, or added up since the last snapshot. In
    /// the latter case the text from before the first of those removals is saved too, so holding
    /// Delete or several small cuts lose nothing.
    func willEdit(_ id: UUID, removedLength removed: Int, insertedLength inserted: Int, currentText: () -> String) {
        var t = tracking[id] ?? DeletionTracking()
        let due = lastSnapshotUptime[id].map { uptime() - $0 >= policy.interval } ?? true

        if inserted > 0 { t.inSavedRun = false }
        if removed > 0 {
            if t.inSavedRun, !due {
                tracking[id] = t // the start of this run of deletions is already saved
                return
            }
            if t.removed == 0 {
                t.baseline = currentText()
                t.insertedSinceBaseline = false
            }
            t.removed += removed
        }
        // Includes replacements (paste or IME input over a selection): that new text is not in the baseline.
        if inserted > 0, t.baseline != nil { t.insertedSinceBaseline = true }

        let deleting = removed >= policy.deletionThreshold || t.removed >= policy.deletionThreshold
        guard due || deleting else {
            tracking[id] = t
            return
        }
        if let baseline = t.baseline {
            checkpoint(id, text: baseline, reason: .deletion)
        }
        if t.baseline == nil || t.insertedSinceBaseline {
            checkpoint(id, text: currentText(), reason: deleting ? .deletion : .edit)
        }
        tracking[id] = DeletionTracking(inSavedRun: deleting && inserted == 0)
    }

    /// Writes a snapshot unless the text is blank or equal to the newest snapshot. Never overwrites a
    /// file: names use millisecond stamps that always increase per note, even if the clock goes back.
    @discardableResult
    func checkpoint(_ id: UUID, text: String, reason: SnapshotReason) -> Bool {
        lastSnapshotUptime[id] = uptime()
        guard !text.allSatisfy(\.isWhitespace) else { return false }
        if newestSnapshotText(id) == text {
            // Already saved, but perhaps as a routine snapshot that thin() may remove later. A non-routine
            // reason (e.g. the text before a deletion right after launch) must keep it: promote the file.
            guard !reason.isRoutine, let newest = snapshots(for: id).first, newest.reason.isRoutine else { return false }
            let promoted = fileURL(in: directory(for: id), date: newest.date, reason: reason)
            guard (try? FileManager.default.moveItem(at: newest.url, to: promoted)) != nil else { return false }
            onChange?()
            return true
        }

        let dir = directory(for: id)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var date = now()
        if let newest = newestDate[id], date <= newest {
            date = newest.addingTimeInterval(0.001)
        }
        var url = fileURL(in: dir, date: date, reason: reason)
        while fm.fileExists(atPath: url.path) {
            date = date.addingTimeInterval(0.001)
            url = fileURL(in: dir, date: date, reason: reason)
        }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            NSLog("fusen.md: could not write snapshot %@: %@", url.path, String(describing: error))
            return false
        }
        newestText[id] = text
        newestDate[id] = date
        onChange?()
        return true
    }

    // MARK: Reading

    /// Newest first. Files whose names cannot be parsed are ignored (and never thinned).
    func snapshots(for id: UUID) -> [Snapshot] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(for: id), includingPropertiesForKeys: nil)) ?? []
        return files.compactMap(Self.parse).sorted { $0.date > $1.date }
    }

    func text(of snapshot: Snapshot) -> String {
        (try? String(contentsOf: snapshot.url, encoding: .utf8)) ?? ""
    }

    func hasSnapshots(_ id: UUID) -> Bool { !snapshots(for: id).isEmpty }

    // MARK: Thinning

    func thin() {
        let date = now()
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { return }
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            var seenBuckets = Set<Int>()
            // Newest first, so the newest routine snapshot of each bucket survives, and the newest
            // snapshot of the note always survives.
            for (index, snapshot) in snapshots(for: id).enumerated() where snapshot.reason.isRoutine && index > 0 {
                let age = date.timeIntervalSince(snapshot.date)
                guard age >= policy.keepEverything else { continue }
                let seconds = snapshot.date.timeIntervalSince1970
                let bucket = age < policy.keepHourly ? Int(seconds / 3_600) * 2 : Int(seconds / 86_400) * 2 + 1
                if !seenBuckets.insert(bucket).inserted {
                    try? fm.removeItem(at: snapshot.url)
                }
            }
        }
    }

    // MARK: Files

    private func directory(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func fileURL(in dir: URL, date: Date, reason: SnapshotReason) -> URL {
        dir.appendingPathComponent("\(Self.stampFormatter.string(from: date))-\(reason.rawValue).md")
    }

    private static func parse(_ url: URL) -> Snapshot? {
        guard url.pathExtension == "md" else { return nil }
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard parts.count >= 2, let date = stampFormatter.date(from: String(parts[0])),
              let reason = SnapshotReason(rawValue: String(parts[1])) else { return nil }
        return Snapshot(url: url, date: date, reason: reason)
    }

    private func newestSnapshotText(_ id: UUID) -> String? {
        if let cached = newestText[id] { return cached }
        guard let newest = snapshots(for: id).first else { return nil }
        let text = self.text(of: newest)
        newestText[id] = text
        newestDate[id] = newest.date
        return text
    }
}
