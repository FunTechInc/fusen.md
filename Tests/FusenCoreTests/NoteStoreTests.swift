import Foundation
import Testing
@testable import FusenCore

@MainActor
struct NoteStoreTests {
    let root = makeTempDirectory()

    @Test func roundTripsNotesAndTrash() {
        let store = NoteStore(rootURL: root)
        store.load()
        let a = NoteMeta(frame: CGRect(x: 10, y: 20, width: 280, height: 240))
        let b = NoteMeta(frame: CGRect(x: 30, y: 40, width: 280, height: 240), color: .pink)
        store.add(a, body: "# A")
        store.add(b, body: "B")
        store.markDeleted(b.id)
        store.flush()

        let reloaded = NoteStore(rootURL: root)
        reloaded.load()
        #expect(reloaded.openNotes.map(\.id) == [a.id])
        #expect(reloaded.deletedNotes.map(\.id) == [b.id])
        #expect(reloaded.body(of: b.id) == "B")
        #expect(reloaded.meta(b.id)?.color == .pink)

        reloaded.restore(b.id, body: "B restored")
        #expect(reloaded.openNotes.count == 2)
        #expect(reloaded.body(of: b.id) == "B restored")
    }

    @Test func updateMetaCannotResurrectADeletedNote() {
        let store = NoteStore(rootURL: root)
        var meta = NoteMeta(frame: .zero)
        store.add(meta, body: "x")
        store.markDeleted(meta.id)
        meta.frame = CGRect(x: 1, y: 1, width: 200, height: 200) // late windowDidMove from the closing window
        store.updateMeta(meta)
        #expect(store.meta(meta.id)?.isDeleted == true)
        #expect(store.meta(meta.id)?.frame == meta.frame)
    }

    @Test func loadsPrototypeIndexAndMigratesArchive() throws {
        let fm = FileManager.default
        let notes = root.appendingPathComponent("notes")
        let archive = root.appendingPathComponent("Archive")
        try fm.createDirectory(at: notes, withIntermediateDirectories: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        let openID = UUID()
        // Prototype index: version 1, no isOnAllSpaces / deletedAt.
        let index = """
        {"notes":[{"color":"green","created":"2026-09-25T14:33:15Z","frame":[[100,200],[280,240]],
        "id":"\(openID.uuidString)","isFloating":true,"isTranslucent":false,"modified":"2026-09-25T14:33:15Z"}],"version":1}
        """
        try Data(index.utf8).write(to: root.appendingPathComponent("index.json"))
        try Data("open note".utf8).write(to: notes.appendingPathComponent("\(openID.uuidString).md"))
        let archivedID = UUID()
        try Data("closed note".utf8).write(to: archive.appendingPathComponent("2026-09-25T14-34-29Z-\(archivedID.uuidString).md"))

        let store = NoteStore(rootURL: root)
        store.load()
        let open = try #require(store.meta(openID))
        #expect(open.isFloating && open.isOnAllSpaces && !open.isDeleted && open.color == .green)
        #expect(store.deletedNotes.map(\.id) == [archivedID])
        #expect(store.body(of: archivedID) == "closed note")
        #expect(!fm.fileExists(atPath: archive.path))
    }

    @Test func noteFilesMissingFromTheIndexAreAdopted() throws {
        let notes = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let orphan = UUID()
        try Data("# 残っていた本文".utf8).write(to: notes.appendingPathComponent("\(orphan.uuidString).md"))
        try Data("ignored".utf8).write(to: notes.appendingPathComponent("not-a-note.md"))
        let store = NoteStore(rootURL: root)
        store.load()
        #expect(store.openNotes.map(\.id) == [orphan])
        #expect(store.body(of: orphan) == "# 残っていた本文")
    }

    @Test func nonUTF8FileIsNeverShownEmpty() throws {
        let store = NoteStore(rootURL: root)
        let meta = NoteMeta(frame: .zero)
        store.add(meta, body: "x")
        store.flush()
        let shiftJIS = try #require("日本語のメモ".data(using: .shiftJIS))
        try shiftJIS.write(to: store.bodyURL(for: meta.id))
        let reloaded = NoteStore(rootURL: root)
        reloaded.load()
        #expect(!reloaded.body(of: meta.id).isEmpty)
        _ = reloaded.body(of: meta.id) // a second read must not make a second copy
        let copies = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("notes").path)
            .filter { $0.contains(".unreadable-") }
        #expect(copies.count == 1)
    }

    @Test func externalChangeIsReportedBeforeOverwriting() throws {
        let store = NoteStore(rootURL: root)
        var reported: [String] = []
        store.onExternalChange = { _, text in reported.append(text) }
        let meta = NoteMeta(frame: .zero)
        store.add(meta, body: "from app")
        store.flush()
        // Another editor changes the file (with a later modification date).
        let url = store.bodyURL(for: meta.id)
        try Data("from another editor".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        store.updateBody("from app, edited", for: meta.id)
        store.flush()
        #expect(reported == ["from another editor"])
        #expect(store.body(of: meta.id) == "from app, edited")
    }

    @Test func readingANoteDoesNotHideAnExternalChange() throws {
        let store = NoteStore(rootURL: root)
        var reported: [String] = []
        store.onExternalChange = { _, text in reported.append(text) }
        let meta = NoteMeta(frame: .zero)
        store.add(meta, body: "from app")
        store.flush()
        let url = store.bodyURL(for: meta.id)
        try Data("from another editor".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        _ = store.body(of: meta.id) // e.g. the history window reloading
        store.updateBody("from app, edited", for: meta.id)
        store.flush()
        #expect(reported == ["from another editor"])
    }

    @Test func externalNonUTF8VersionIsCopiedBeforeOverwriting() throws {
        let store = NoteStore(rootURL: root)
        let meta = NoteMeta(frame: .zero)
        store.add(meta, body: "x")
        store.flush()
        let url = store.bodyURL(for: meta.id)
        try #require("日本語のメモ".data(using: .shiftJIS)).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        store.updateBody("x edited", for: meta.id)
        store.flush()
        let copies = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("notes").path)
            .filter { $0.contains(".unreadable-") }
        #expect(copies.count == 1)
    }

    @Test func savingRecoversWhenTheFolderWasRemoved() throws {
        let store = NoteStore(rootURL: root)
        var recovered = 0
        store.onWriteRecovered = { recovered += 1 }
        let meta = NoteMeta(frame: .zero)
        store.add(meta, body: "a")
        store.flush()
        try FileManager.default.removeItem(at: root.appendingPathComponent("notes"))
        store.updateBody("a b", for: meta.id)
        store.flush()
        #expect(!store.hasUnsavedChanges)
        #expect(store.body(of: meta.id) == "a b")
        #expect(recovered == 0) // nothing had failed
    }

    @Test func failedSavesAreKeptAndReported() throws {
        let store = NoteStore(rootURL: root)
        var errors = 0, recovered = 0
        store.onWriteError = { _, _ in errors += 1 }
        store.onWriteRecovered = { recovered += 1 }
        let meta = NoteMeta(frame: .zero)
        store.add(meta, body: "a")
        store.flush()
        let notes = root.appendingPathComponent("notes")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: notes.path) // read-only
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notes.path) }
        store.updateBody("unsaved text", for: meta.id)
        store.flush()
        #expect(errors > 0)
        #expect(store.hasUnsavedChanges)
        #expect(store.body(of: meta.id) == "unsaved text") // still in memory
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notes.path)
        store.flush()
        #expect(!store.hasUnsavedChanges)
        #expect(recovered == 1)
    }

    @Test func duplicateIndexEntriesAreDropped() throws {
        let id = UUID()
        let entry = """
        {"color":"yellow","created":"2026-09-25T14:33:15Z","frame":[[1,2],[280,240]],"id":"\(id.uuidString)",
        "isFloating":false,"isTranslucent":false,"modified":"2026-09-25T14:33:15Z"}
        """
        try Data("{\"version\":2,\"notes\":[\(entry),\(entry)]}".utf8).write(to: root.appendingPathComponent("index.json"))
        let store = NoteStore(rootURL: root)
        store.load()
        #expect(store.metas.count == 1)
        let model = HistoryModel(store: store, history: HistoryStore(rootURL: store.historyURL))
        model.reload() // used to crash on duplicate ids
        #expect(model.openNotes.count == 1)
    }

    @Test func searchCannotActOnAHiddenVersion() throws {
        let store = NoteStore(rootURL: root)
        let history = HistoryStore(rootURL: store.historyURL)
        let a = NoteMeta(frame: .zero), b = NoteMeta(frame: .zero)
        store.add(a, body: "note A now")
        store.add(b, body: "note B betaword")
        store.flush()
        history.checkpoint(a.id, text: "note A alphaold", reason: .deletion)
        let model = HistoryModel(store: store, history: history)
        model.selectedNoteID = a.id
        model.reload()
        model.selectedVersionID = model.versions.first { !$0.isCurrent }?.id
        #expect(model.canRestore)
        model.searchText = "betaword"
        model.updateSearch()
        #expect(model.openNotes.map(\.id) == [b.id])
        #expect(model.selectedVersion == nil)
        #expect(!model.canRestore)
    }

    @Test func unreadableIndexIsKeptAside() throws {
        try Data("{not json".utf8).write(to: root.appendingPathComponent("index.json"))
        let store = NoteStore(rootURL: root)
        store.load()
        let copies = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("index-unreadable-") }
        #expect(copies.count == 1)
    }

    // MARK: Found in review (2026-11-20)

    @Test func movingAWindowDoesNotSetTheTimeOfTheTextBack() throws {
        let store = NoteStore(rootURL: root)
        store.load()
        var meta = NoteMeta(frame: .zero, created: Date(timeIntervalSince1970: 1_000))
        store.add(meta, body: "昨日のメモ")
        store.updateBody("今日書き足した", for: meta.id)
        let edited = try #require(store.meta(meta.id)?.modified)
        #expect(edited > meta.modified)
        meta.frame = CGRect(x: 50, y: 50, width: 280, height: 240) // the window's copy, from before the edit
        store.updateMeta(meta)
        #expect(store.meta(meta.id)?.frame == meta.frame)
        #expect(store.meta(meta.id)?.modified == edited)
    }

    @Test func anIndexEntryThatCannotBeReadLeavesTheOthersAsTheyWere() throws {
        let store = NoteStore(rootURL: root)
        store.load()
        let open = NoteMeta(frame: CGRect(x: 1, y: 2, width: 280, height: 240), color: .pink)
        let deleted = NoteMeta(frame: .zero)
        let odd = NoteMeta(frame: .zero)
        store.add(open, body: "開いている")
        store.add(deleted, body: "削除した")
        store.add(odd, body: "色が不明")
        store.markDeleted(deleted.id)
        store.flush()
        // A color this version does not know (a later version's), and an entry that is not a note at all.
        let url = root.appendingPathComponent("index.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var notes = try #require(json["notes"] as? [[String: Any]])
        let i = try #require(notes.firstIndex { $0["id"] as? String == odd.id.uuidString })
        notes[i]["color"] = "red"
        notes.append(["id": "not-a-uuid"])
        json["notes"] = notes
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let reloaded = NoteStore(rootURL: root)
        reloaded.load()
        #expect(reloaded.meta(deleted.id)?.isDeleted == true)                 // still in the trash
        #expect(reloaded.meta(open.id)?.color == .pink)
        #expect(reloaded.meta(odd.id)?.color == .yellow)                      // only the unknown value is reset
        #expect(reloaded.metas.count == 3)
        let copies = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("index-partly-unreadable-") }
        #expect(copies.count == 1)
    }

    @Test func whatIsInANotesFileIsToldApart() throws {
        let store = NoteStore(rootURL: root)
        store.load()
        let meta = NoteMeta(frame: .zero)
        store.add(meta, body: "")
        store.flush()
        let url = store.bodyURL(for: meta.id)
        #expect(store.fileText(of: meta.id) == .text(""))
        #expect(!store.fileHoldsText(meta.id))
        try Data("議事録".utf8).write(to: url)                                 // written by another app
        #expect(store.fileHoldsText(meta.id))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        #expect(store.fileText(of: meta.id) == .unreadable)
        #expect(store.fileHoldsText(meta.id))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try FileManager.default.removeItem(at: url)
        #expect(store.fileText(of: meta.id) == .missing)
        #expect(!store.fileHoldsText(meta.id))
    }
}

@MainActor
struct LegacyFolderTests {
    let parent = makeTempDirectory()
    var legacy: URL { parent.appendingPathComponent("MarkdownStickies") }
    var root: URL { parent.appendingPathComponent("fusen.md") }

    private func makeLegacyNote() throws -> UUID {
        let store = NoteStore(rootURL: legacy)
        let meta = NoteMeta(frame: .zero)
        store.add(meta, body: "引き継ぐメモ")
        store.flush()
        return meta.id
    }

    @Test func notesOfTheFormerNameAreMovedOnce() throws {
        let id = try makeLegacyNote()
        #expect(NoteStore.migrate(from: legacy, to: root) == .moved)
        let store = NoteStore(rootURL: root)
        store.load()
        #expect(store.body(of: id) == "引き継ぐメモ")
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(NoteStore.migrate(from: legacy, to: root) == .none)
    }

    @Test func anExistingFolderIsNeverReplaced() throws {
        _ = try makeLegacyNote()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(NoteStore.migrate(from: legacy, to: root) == .none)
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func notMovedWhileTheOldAppHoldsItsLock() throws {
        _ = try makeLegacyNote()
        let fd = open(legacy.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o644)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0) // the old app running
        #expect(NoteStore.migrate(from: legacy, to: root) == .oldAppRunning)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
