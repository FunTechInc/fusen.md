import Foundation

/// Notes on disk (default root: ~/Library/Application Support/fusen.md):
///
///     notes/<uuid>.md             current text of every note, open or deleted (plain Markdown)
///     index.json                  NoteMeta of every note; deleted ones carry `deletedAt`
///     history/<uuid>/<stamp>.md   earlier versions (see HistoryStore)
///
/// notes/*.md is the source of truth: a note file missing from index.json is adopted at launch,
/// and an unreadable index is copied aside instead of being overwritten. Closing a sticky only
/// marks it deleted, so it can be restored from the history window.
@MainActor
final class NoteStore {
    private struct Index: Codable {
        var version = 2
        var notes: [NoteMeta]
    }

    /// index.json as it is read: an entry that cannot be read is left out, and the others still load.
    private struct LoadedIndex: Decodable {
        struct Entry: Decodable {
            let meta: NoteMeta?
            init(from decoder: Decoder) throws { meta = try? NoteMeta(from: decoder) }
        }
        var notes: [Entry]
    }

    static var defaultRootURL: URL {
        #if DEBUG
        let folder = "fusen.md-Debug" // `swift run` must never touch the real notes
        #else
        let folder = "fusen.md"
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folder, isDirectory: true)
    }

    enum LegacyMigration: Equatable {
        case none, moved
        /// The app under its former name is still running (it holds the old folder's lock).
        case oldAppRunning
    }

    /// The app used to be called "Markdown Stickies" and kept its notes in Application Support/
    /// MarkdownStickies. Moves that folder to `root` once, before anything creates `root`.
    static func migrateLegacyRoot(to root: URL = defaultRootURL) -> LegacyMigration {
        #if DEBUG
        return .none // the development build has its own folder
        #else
        return migrate(from: root.deletingLastPathComponent().appendingPathComponent("MarkdownStickies", isDirectory: true),
                       to: root)
        #endif
    }

    static func migrate(from legacy: URL, to root: URL) -> LegacyMigration {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: root.path) else { return .none }
        let lock = open(legacy.appendingPathComponent(".lock").path, O_RDWR)
        if lock >= 0 {
            defer { close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return .oldAppRunning }
            flock(lock, LOCK_UN)
        }
        do {
            try fm.moveItem(at: legacy, to: root)
            return .moved
        } catch {
            NSLog("fusen.md: could not move %@ to %@: %@", legacy.path, root.path, String(describing: error))
            return .none
        }
    }

    let rootURL: URL
    let notesURL: URL
    let historyURL: URL
    private let indexURL: URL
    /// The prototype moved closed notes to Archive/<stamp>-<uuid>.md; `load()` migrates them.
    private let legacyArchiveURL: URL

    /// Called once per failed write (disk full, permissions, …).
    var onWriteError: ((URL, Error) -> Void)?
    /// Called when a save succeeds after an earlier one failed.
    var onWriteRecovered: (() -> Void)?
    /// Called with the on-disk text when a note file was changed by another app since this app last
    /// read or wrote it, just before this app overwrites it.
    var onExternalChange: ((UUID, String) -> Void)?
    /// Called after a note was added or its text or color changed (used by the Notion sync), with
    /// the new text when the text changed: the sync must not read unsaved text through `body(of:)`,
    /// which would hide another app's edit from `onExternalChange`.
    var onNoteChanged: ((UUID, String?) -> Void)?
    /// Called after a note was moved to the trash or forgotten.
    var onNoteDeleted: ((UUID) -> Void)?
    /// Called after a note was taken out of the trash.
    var onNoteRestored: ((UUID) -> Void)?

    private(set) var metas: [NoteMeta] = []
    private var dirtyBodies: [UUID: String] = [:]
    /// Modification date of each note file as last read or written by this app.
    private var knownModificationDates: [UUID: Date] = [:]
    private var copiedUnreadable: Set<UUID> = []
    private var indexDirty = false
    private var lastSaveFailed = false
    private var saveTask: Task<Void, Never>?

    /// Text or metadata that could not be written yet (a save failed).
    var hasUnsavedChanges: Bool { !dirtyBodies.isEmpty || indexDirty }

    init(rootURL: URL = NoteStore.defaultRootURL) {
        self.rootURL = rootURL
        notesURL = rootURL.appendingPathComponent("notes", isDirectory: true)
        historyURL = rootURL.appendingPathComponent("history", isDirectory: true)
        indexURL = rootURL.appendingPathComponent("index.json")
        legacyArchiveURL = rootURL.appendingPathComponent("Archive", isDirectory: true)
        for dir in [notesURL, historyURL] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: Queries

    var openNotes: [NoteMeta] { metas.filter { !$0.isDeleted } }

    /// Most recently deleted first.
    var deletedNotes: [NoteMeta] {
        metas.filter(\.isDeleted).sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    func meta(_ id: UUID) -> NoteMeta? { metas.first { $0.id == id } }

    /// Latest text, including edits that are not written to disk yet. A file that is not valid
    /// UTF-8 is copied aside once and shown with replacement characters — never as an empty note.
    func body(of id: UUID) -> String {
        if let dirty = dirtyBodies[id] { return dirty }
        let url = bodyURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return "" }
        // Only the first read sets the baseline for external-change detection: a later read (e.g. by the
        // history window) must not hide another app's edit that has not been snapshotted yet.
        if knownModificationDates[id] == nil { knownModificationDates[id] = modificationDate(of: url) }
        return decode(data, of: id, at: url)
    }

    /// What is in a note's file now (not the text being edited, and without taking the file's date as
    /// seen, as `body(of:)` does).
    enum FileText: Equatable {
        case missing
        /// It is there but cannot be read (no permission, an I/O error).
        case unreadable
        case text(String)
    }

    func fileText(of id: UUID) -> FileText {
        let url = bodyURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return .text(String(decoding: data, as: UTF8.self))
    }

    /// Whether a note's file holds text, or may (it cannot be read): then the note is not one that never
    /// had any content, whatever its window shows.
    func fileHoldsText(_ id: UUID) -> Bool {
        switch fileText(of: id) {
        case .missing: false
        case .unreadable: true
        case .text(let text): !text.allSatisfy(\.isWhitespace)
        }
    }

    /// UTF-8 text; otherwise the original bytes are copied aside once and the text is decoded lossily.
    private func decode(_ data: Data, of id: UUID, at url: URL) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if copiedUnreadable.insert(id).inserted {
            let copy = notesURL.appendingPathComponent("\(id.uuidString).unreadable-\(Int(Date().timeIntervalSince1970)).bak")
            if (try? FileManager.default.copyItem(at: url, to: copy)) != nil {
                NSLog("fusen.md: %@ is not UTF-8; original copied to %@", url.path, copy.path)
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Loading

    func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: indexURL) {
            do {
                // A hand-edited index may list a note twice; keep the first entry.
                var seen = Set<UUID>()
                let entries = try decoder.decode(LoadedIndex.self, from: data).notes
                let notes = entries.compactMap(\.meta)
                metas = notes.filter { seen.insert($0.id).inserted }
                if metas.count != notes.count { indexDirty = true }
                if notes.count != entries.count {
                    // Some entries could not be read (their notes come back as open notes, if their files
                    // are there): the index is kept as it was before it is written again.
                    let copy = rootURL.appendingPathComponent("index-partly-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                    try? FileManager.default.copyItem(at: indexURL, to: copy)
                    NSLog("fusen.md: %d entries of index.json unreadable; copied to %@", entries.count - notes.count, copy.path)
                    indexDirty = true
                }
            } catch {
                // Never overwrite an index we could not read: keep a copy before starting over.
                let copy = rootURL.appendingPathComponent("index-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: indexURL, to: copy)
                NSLog("fusen.md: index.json unreadable (%@); copied to %@", String(describing: error), copy.path)
            }
        }
        migrateLegacyArchive()
        adoptOrphanedNotes()
        flush()
    }

    private func migrateLegacyArchive() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: legacyArchiveURL, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for file in files where file.pathExtension == "md" {
            let name = file.deletingPathExtension().lastPathComponent
            var id = UUID(uuidString: String(name.suffix(36))) ?? UUID()
            if meta(id) != nil || fm.fileExists(atPath: bodyURL(for: id).path) { id = UUID() }
            let date = modificationDate(of: file) ?? Date()
            do {
                try fm.moveItem(at: file, to: bodyURL(for: id))
            } catch {
                NSLog("fusen.md: could not migrate %@: %@", file.path, String(describing: error))
                continue
            }
            var meta = NoteMeta(id: id, frame: CGRect(x: 200, y: 400, width: 280, height: 240), created: date)
            meta.deletedAt = date
            metas.append(meta)
            indexDirty = true
        }
        if (try? fm.contentsOfDirectory(atPath: legacyArchiveURL.path))?.isEmpty == true {
            try? fm.removeItem(at: legacyArchiveURL)
        }
    }

    /// notes/<uuid>.md files without an index entry (lost index, crash between writes) become open notes.
    private func adoptOrphanedNotes() {
        let files = (try? FileManager.default.contentsOfDirectory(at: notesURL, includingPropertiesForKeys: nil)) ?? []
        var offset: CGFloat = 0
        for file in files where file.pathExtension == "md" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), meta(id) == nil else { continue }
            let date = modificationDate(of: file) ?? Date()
            metas.append(NoteMeta(id: id, frame: CGRect(x: 160 + offset, y: 420 - offset, width: 280, height: 240), created: date))
            offset += 24
            indexDirty = true
        }
    }

    // MARK: Changes

    func add(_ meta: NoteMeta, body: String) {
        metas.append(meta)
        dirtyBodies[meta.id] = body
        indexDirty = true
        scheduleSave()
        onNoteChanged?(meta.id, body)
    }

    /// Window state changes. `deletedAt` and `modified` are owned by the store and never taken from the
    /// caller: a late window callback cannot resurrect a deleted note, and a window that was moved after
    /// its text changed (its copy of the metadata is from when it opened) does not set the time back.
    func updateMeta(_ meta: NoteMeta) {
        guard let i = metas.firstIndex(where: { $0.id == meta.id }) else { return }
        var updated = meta
        updated.deletedAt = metas[i].deletedAt
        updated.modified = metas[i].modified
        guard updated != metas[i] else { return }
        let colorChanged = updated.color != metas[i].color
        metas[i] = updated
        indexDirty = true
        scheduleSave()
        if colorChanged { onNoteChanged?(meta.id, nil) }
    }

    func updateBody(_ body: String, for id: UUID) {
        guard let i = metas.firstIndex(where: { $0.id == id }) else {
            assertionFailure("updateBody for unknown note \(id)")
            NSLog("fusen.md: updateBody for unknown note %@", id.uuidString)
            return
        }
        metas[i].modified = Date()
        dirtyBodies[id] = body
        indexDirty = true
        scheduleSave()
        onNoteChanged?(id, body)
    }

    /// Moves a note to the trash. Its text stays on disk.
    func markDeleted(_ id: UUID) {
        guard let i = metas.firstIndex(where: { $0.id == id }) else { return }
        metas[i].deletedAt = Date()
        indexDirty = true
        flush()
        onNoteDeleted?(id)
    }

    /// Takes a note out of the trash, optionally replacing its text.
    func restore(_ id: UUID, body: String? = nil) {
        guard let i = metas.firstIndex(where: { $0.id == id }) else { return }
        metas[i].deletedAt = nil
        if let body {
            metas[i].modified = Date()
            dirtyBodies[id] = body
        }
        indexDirty = true
        flush()
        onNoteRestored?(id)
    }

    /// Forgets a note entirely. Only used for notes that never had any content.
    func remove(_ id: UUID) {
        metas.removeAll { $0.id == id }
        dirtyBodies[id] = nil
        indexDirty = true
        try? FileManager.default.removeItem(at: bodyURL(for: id))
        flush()
        onNoteDeleted?(id)
    }

    // MARK: Saving

    /// Debounced: typing produces at most one disk write per 0.5 s.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        var unsaved: [UUID: String] = [:]
        for (id, body) in dirtyBodies {
            let url = bodyURL(for: id)
            if let known = knownModificationDates[id], let onDisk = modificationDate(of: url), onDisk != known,
               let data = try? Data(contentsOf: url) {
                copiedUnreadable.remove(id) // a new external version gets its own copy if it is not UTF-8
                let external = decode(data, of: id, at: url) // copies non-UTF-8 bytes aside before overwriting
                onExternalChange?(id, external)
            }
            if write(Data(body.utf8), to: url) {
                knownModificationDates[id] = modificationDate(of: url)
            } else {
                unsaved[id] = body // retried on the next save
            }
        }
        dirtyBodies = unsaved
        if indexDirty {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(Index(notes: metas)), write(data, to: indexURL) {
                indexDirty = false
            }
        }
        let failed = hasUnsavedChanges
        if lastSaveFailed, !failed { onWriteRecovered?() }
        lastSaveFailed = failed
    }

    func bodyURL(for id: UUID) -> URL {
        notesURL.appendingPathComponent("\(id.uuidString).md")
    }

    @discardableResult
    private func write(_ data: Data, to url: URL) -> Bool {
        do {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                // The folder may have been moved or deleted while the app was running.
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            return true
        } catch {
            NSLog("fusen.md: could not write %@: %@", url.path, String(describing: error))
            onWriteError?(url, error)
            return false
        }
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
