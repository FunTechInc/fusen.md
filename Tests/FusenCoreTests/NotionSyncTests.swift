import Foundation
import Testing
@testable import FusenCore

/// Records every call; never touches the network.
@MainActor
final class MockNotionAPI: NotionAPI {
    enum Call: Equatable {
        case me
        case page(String)
        case database(String)
        case children(String)
        case createDatabase(parent: String)
        case createPage(markdown: String, properties: [String: NotionPropertyValue])
        case replace(page: String, markdown: String)
        case update(page: String, properties: [String: NotionPropertyValue])
        case query(noteID: String)
        case markdown(page: String)
    }

    var calls: [Call] = []
    /// Thrown by the next calls, in order (nil: that call works).
    var failures: [NotionError?] = []
    /// The next call throws CancellationError although nothing was cancelled.
    var spuriousCancellation = false
    /// Pages already in Notion, by メモID.
    var existing: [String: String] = [:]
    /// Pages in Notion's trash.
    var trashed: Set<String> = []
    /// What GET /v1/pages/{id}/markdown returns, by page ID.
    var remoteMarkdown: [String: NotionPageMarkdown] = [:]
    /// Databases in each page, by page ID.
    var children: [String: [NotionChildDatabase]] = [:]
    var schema: [String: NotionPropertySchema]?
    /// The data source of each page created, in order.
    var createdIn: [String] = []
    /// The next call matching this waits for `release()`, or for its task to be cancelled (then it
    /// throws CancellationError, as URLSession does).
    var holdWhen: ((Call) -> Bool)?
    private(set) var isHolding = false
    private var held: CheckedContinuation<Void, Never>?
    private var heldWasCancelled = false
    private var databases: [String: NotionDatabase] = [:]
    private var created = 0

    var writes: [Call] {
        calls.filter {
            switch $0 {
            case .me, .page, .database, .children, .query, .markdown: false
            default: true
            }
        }
    }

    /// Lets the held call finish normally (Notion answered).
    func release() {
        held?.resume()
        held = nil
    }

    /// A database that exists in Notion (e.g. saved although the create answered 503).
    func add(_ database: NotionDatabase) {
        databases[database.id] = database
    }

    private func perform(_ call: Call) async throws {
        calls.append(call)
        if let holdWhen, holdWhen(call) {
            self.holdWhen = nil
            isHolding = true
            heldWasCancelled = false
            await withTaskCancellationHandler {
                await withCheckedContinuation { held = $0 }
            } onCancel: {
                Task { @MainActor in
                    guard self.held != nil else { return } // answered before the cancellation
                    self.heldWasCancelled = true
                    self.release()
                }
            }
            isHolding = false
            if heldWasCancelled { throw CancellationError() }
        }
        if spuriousCancellation {
            spuriousCancellation = false
            throw CancellationError()
        }
        if !failures.isEmpty, let failure = failures.removeFirst() { throw failure }
    }

    func retrieveMe() async throws -> NotionUser {
        try await perform(.me)
        return NotionUser(id: "bot", workspaceName: "FunTech")
    }

    func retrievePage(id: String) async throws -> NotionPage {
        try await perform(.page(id))
        return NotionPage(id: id, inTrash: trashed.contains(id))
    }

    func retrieveDatabase(id: String) async throws -> NotionDatabase {
        try await perform(.database(id))
        guard let database = databases[id] else { throw NotionError.notFound(message: "no database") }
        return database
    }

    func childDatabases(pageID: String) async throws -> [NotionChildDatabase] {
        try await perform(.children(pageID))
        return children[pageID] ?? []
    }

    func createDatabase(parentPageID: String, title: String,
                        properties: [String: NotionPropertySchema]) async throws -> NotionDatabase {
        try await perform(.createDatabase(parent: parentPageID))
        schema = properties
        let n = databases.count + 1
        let database = NotionDatabase(id: "db-\(n)", url: "https://www.notion.so/db\(n)",
                                      dataSources: [.init(id: "ds-\(n)", name: "fusen.md")])
        databases[database.id] = database
        return database
    }

    func createPage(dataSourceID: String, properties: [String: NotionPropertyValue],
                    markdown: String) async throws -> NotionPage {
        try await perform(.createPage(markdown: markdown, properties: properties))
        created += 1
        createdIn.append(dataSourceID)
        return NotionPage(id: "page-\(created)")
    }

    func retrieveMarkdown(pageID: String) async throws -> NotionPageMarkdown {
        try await perform(.markdown(page: pageID))
        guard let page = remoteMarkdown[pageID] else { throw NotionError.notFound(message: "no page") }
        return page
    }

    func replaceContent(pageID: String, markdown: String) async throws {
        try await perform(.replace(page: pageID, markdown: markdown))
    }

    func updateProperties(pageID: String, properties: [String: NotionPropertyValue]) async throws {
        try await perform(.update(page: pageID, properties: properties))
    }

    func queryPages(dataSourceID: String, property: String, equals value: String) async throws -> [NotionPage] {
        try await perform(.query(noteID: value))
        return existing[value].map { [NotionPage(id: $0)] } ?? []
    }
}

@MainActor
final class InMemoryTokenStore: NotionTokenStore {
    var token: String?
    /// Like the Keychain refusing the item (e.g. "拒否" in its prompt).
    var failsToSave = false
    func readToken() -> String? { token }
    func saveToken(_ token: String) throws {
        if failsToSave { throw NSError(domain: NSOSStatusErrorDomain, code: -128) }
        self.token = token
    }
    func deleteToken() { token = nil }
}

@MainActor
struct NotionSyncTests {
    let clock = TestClock()
    let root = makeTempDirectory()
    let store: NoteStore
    let api = MockNotionAPI()
    let tokens = InMemoryTokenStore()
    let sync: NotionSync
    static let parentURL = "https://www.notion.so/funtech/Stickies-0123456789abcdef0123456789abcdef?pvs=4"
    static let parentID = "01234567-89ab-cdef-0123-456789abcdef"
    static let otherParentURL = "https://www.notion.so/funtech/Other-fedcba9876543210fedcba9876543210"

    init() async throws {
        store = NoteStore(rootURL: root)
        store.load()
        sync = Self.makeSync(store: store, api: api, tokens: tokens, clock: clock)
        try await sync.connect(token: "test-token", parentPageURL: Self.parentURL)
        api.calls = []
    }

    static func makeSync(store: NoteStore, api: MockNotionAPI, tokens: InMemoryTokenStore, clock: TestClock,
                         now: (() -> Date)? = nil, timing: NotionSync.Timing = .init(), autoWake: Bool = false) -> NotionSync {
        let sync = NotionSync(store: store, styler: MarkdownStyler(), tokenStore: tokens,
                              makeClient: { _ in api }, now: now ?? { clock.now }, timing: timing, autoWake: autoWake)
        // Same wiring as AppDelegate.makeNotionSync().
        store.onNoteChanged = { [weak sync] in sync?.noteChanged($0, text: $1) }
        store.onNoteDeleted = { [weak sync] in sync?.noteDeleted($0) }
        store.onNoteRestored = { [weak sync] in sync?.noteRestored($0) }
        return sync
    }

    @discardableResult
    private func addNote(_ body: String) -> UUID {
        let meta = NoteMeta(frame: .zero)
        store.add(meta, body: body)
        return meta.id
    }

    /// Adds a note and lets its first push go out.
    private func pushedNote(_ body: String) async -> UUID {
        let id = addNote(body)
        clock.advance(10)
        await sync.processDue()
        api.calls = []
        return id
    }

    private func edit(_ id: UUID, _ body: String) async {
        store.updateBody(body, for: id)
        clock.advance(10)
        await sync.processDue()
    }

    private func isCreate(_ call: MockNotionAPI.Call) -> Bool {
        if case .createPage = call { true } else { false }
    }

    // MARK: Importing from Notion

    @Test func importReadsThePageAndConvertsItToTheAppsMarkdown() async throws {
        let id = await pushedNote("# 買い物\n- [ ] 牛乳")
        #expect(sync.canImport(id))
        api.remoteMarkdown["page-1"] = NotionPageMarkdown(
            markdown: "# 買い物\n- [x] 牛乳\n- [ ] パン\n<empty-block/>\n> 一行目<br>二行目\n価格は\\$5")
        let result = try await sync.fetchImport(id)
        #expect(result.text == "# 買い物\n- [x] 牛乳\n- [ ] パン\n\n> 一行目\n> 二行目\n価格は$5")
        #expect(result.notionOnly.isEmpty)
        #expect(api.calls == [.markdown(page: "page-1")])
        #expect(api.writes.isEmpty) // importing never writes to Notion
    }

    @Test func importReportsNotionOnlyElements() async throws {
        let id = await pushedNote("メモ")
        api.remoteMarkdown["page-1"] = NotionPageMarkdown(markdown: """
        <callout icon="💡" color="yellow_bg">
        \t大事
        </callout>
        <span color="red">赤い字</span>
        ```
        <callout> in code is not a callout
        ```
        """)
        let result = try await sync.fetchImport(id)
        #expect(result.notionOnly == ["コールアウト", "文字色・下線"])
    }

    @Test func importRefusesPartialPagesAndUnsentNotes() async throws {
        let id = await pushedNote("メモ")
        api.remoteMarkdown["page-1"] = NotionPageMarkdown(markdown: "途中まで", truncated: true)
        await #expect(throws: NotionSync.SyncError.self) { try await sync.fetchImport(id) }
        api.remoteMarkdown["page-1"] = NotionPageMarkdown(markdown: "<unknown url=\"x\"/>", unknownBlockIDs: ["b1"])
        await #expect(throws: NotionSync.SyncError.self) { try await sync.fetchImport(id) }

        let unsent = addNote("まだ送っていない")
        #expect(!sync.canImport(unsent))
        await #expect(throws: NotionSync.SyncError.self) { try await sync.fetchImport(unsent) }

        api.remoteMarkdown["page-1"] = nil // deleted in Notion
        do {
            _ = try await sync.fetchImport(id)
            Issue.record("expected an error")
        } catch {
            #expect(error.message.contains("見つかりません"))
        }
    }

    // MARK: Connecting

    @Test func connectValidatesCreatesTheDatabaseAndKeepsTheTokenOutOfFiles() async throws {
        let root = makeTempDirectory()
        let store = NoteStore(rootURL: root)
        let api = MockNotionAPI()
        let tokens = InMemoryTokenStore()
        let sync = Self.makeSync(store: store, api: api, tokens: tokens, clock: clock)
        try await sync.connect(token: "  test-token\n", parentPageURL: Self.parentURL)

        let parent = "01234567-89ab-cdef-0123-456789abcdef"
        #expect(api.calls == [.me, .page(parent), .children(parent), .createDatabase(parent: parent)])
        #expect(api.schema == NotionSync.schema)
        #expect(tokens.token == "test-token")
        #expect(sync.isEnabled && sync.hasToken && sync.workspaceName == "FunTech")
        let file = try String(contentsOf: root.appendingPathComponent("notion-sync.json"), encoding: .utf8)
        #expect(file.contains("ds-1") && !file.contains("test-token"))

        // Reconnecting to the same page reuses the database.
        api.calls = []
        try await sync.connect(token: "", parentPageURL: Self.parentURL)
        #expect(!api.calls.contains(.createDatabase(parent: parent)))
    }

    @Test func connectReportsProblemsInJapaneseAndSavesNoBadToken() async {
        let store = NoteStore(rootURL: makeTempDirectory())
        let api = MockNotionAPI()
        let tokens = InMemoryTokenStore()
        let sync = Self.makeSync(store: store, api: api, tokens: tokens, clock: clock)

        api.failures = [.unauthorized]
        await #expect(throws: NotionSync.SyncError(message: NotionError.unauthorized.japaneseDescription)) {
            try await sync.connect(token: "bad", parentPageURL: Self.parentURL)
        }
        api.failures = [.notFound(message: "")]
        await #expect {
            try await sync.connect(token: "ok", parentPageURL: Self.parentURL)
        } throws: { ($0 as? NotionSync.SyncError)?.message.contains("••• > 接続") == true }
        await #expect(throws: NotionSync.SyncError.self) {
            try await sync.connect(token: "ok", parentPageURL: "https://www.notion.so/no-id-here")
        }
        #expect(tokens.token == nil)
        #expect(!sync.isEnabled)
    }

    @Test func keychainFailureChangesNothingAndTheRetryReusesTheDatabase() async throws {
        let id = await pushedNote("one")
        tokens.failsToSave = true
        await #expect(throws: NotionSync.SyncError.self) {
            try await sync.connect(token: "new", parentPageURL: Self.otherParentURL)
        }
        #expect(sync.parentPageURL == Self.parentURL && tokens.token == "test-token")
        await edit(id, "one, edited") // still mirrored where it was
        #expect(api.calls.last == .update(page: "page-1", properties: [
            "名前": .title("one, edited"), "更新日時": .date(store.meta(id)!.modified),
            "状態": .select("使用中"), "色": .select("イエロー")]))

        tokens.failsToSave = false
        api.calls = []
        try await sync.connect(token: "new", parentPageURL: Self.otherParentURL)
        #expect(!api.calls.contains { if case .createDatabase = $0 { true } else { false } }) // made by the failed attempt
        await sync.processDue()
        #expect(api.createdIn == ["ds-1", "ds-2"])
    }

    @Test func databaseSavedDespiteA503IsUsedNotCreatedAgain() async throws {
        let store = NoteStore(rootURL: makeTempDirectory())
        let api = MockNotionAPI()
        let sync = Self.makeSync(store: store, api: api, tokens: InMemoryTokenStore(), clock: clock)
        api.add(NotionDatabase(id: "db-saved", dataSources: [.init(id: "ds-saved", name: nil)]))
        api.failures = [nil, nil, nil, .server(status: 503, committedResourceID: "db-saved")] // me, page, children, create
        try await sync.connect(token: "t", parentPageURL: Self.parentURL)
        #expect(api.calls.last == .database("db-saved"))
        store.add(NoteMeta(frame: .zero), body: "メモ")
        clock.advance(10)
        await sync.processDue()
        #expect(api.createdIn == ["ds-saved"])
    }

    @Test func lostStateFileIsReportedAndReconnectingFindsTheDatabaseAndPages() async throws {
        let id = await pushedNote("消えないメモ")
        store.flush()
        try FileManager.default.removeItem(at: root.appendingPathComponent("notion-sync.json"))
        let relaunched = Self.makeSync(store: store, api: api, tokens: tokens, clock: clock)
        relaunched.start()
        #expect(!relaunched.isEnabled)
        #expect(relaunched.lastError?.contains("notion-sync.json") == true)

        api.children[Self.parentID] = [NotionChildDatabase(id: "db-1", title: "fusen.md")]
        api.existing[id.uuidString] = "page-1"
        api.calls = []
        try await relaunched.connect(token: "", parentPageURL: Self.parentURL)
        await relaunched.processDue()
        #expect(!api.calls.contains { if case .createDatabase = $0 { true } else { false } })
        #expect(!api.calls.contains(where: isCreate))
        #expect(api.calls.contains(.replace(page: "page-1", markdown: "消えないメモ")))
        #expect(relaunched.lastError == nil)
    }

    @Test func connectingElsewhereWhileARequestIsInFlightSendsEverythingToTheNewDatabase() async throws {
        addNote("one")
        addNote("two")
        clock.advance(10)
        api.holdWhen = { if case .createPage = $0 { true } else { false } }
        let run = Task { await sync.processDue() }
        while !api.isHolding { await Task.yield() }
        // connect cancels the request in flight (as URLSession would) and waits for the run to end.
        try await sync.connect(token: "", parentPageURL: Self.otherParentURL)
        await run.value
        await sync.processDue(force: true)
        #expect(api.createdIn == ["ds-2", "ds-2"])
        #expect(sync.lastError == nil)
    }

    @Test func debugBuildsKeepTheirOwnToken() {
        #expect(KeychainTokenStore.service(bundleIdentifier: "com.github.funtechinc.fusen-md", debug: false) == "com.github.funtechinc.fusen-md.notion")
        #expect(KeychainTokenStore.service(bundleIdentifier: nil, debug: true) == "com.github.funtechinc.fusen-md.debug.notion")
    }

    @Test func pageIDsAreReadFromNotionLinks() {
        let id = "01234567-89ab-cdef-0123-456789abcdef"
        #expect(NotionPageID.parse("https://www.notion.so/ws/Title-0123456789abcdef0123456789abcdef") == id)
        #expect(NotionPageID.parse("https://www.notion.so/0123456789ABCDEF0123456789ABCDEF?pvs=4") == id)
        #expect(NotionPageID.parse("https://app.notion.com/p/メモ置き場-0123456789abcdef0123456789abcdef") == id)
        #expect(NotionPageID.parse("https://www.notion.so/ws/\(id)#section") == id)
        #expect(NotionPageID.parse("https://www.notion.so/ws/db-ffffffffffffffffffffffffffffffff?v=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee&p=0123456789abcdef0123456789abcdef") == id)
        #expect(NotionPageID.parse(" 0123456789abcdef0123456789abcdef ") == id)
        #expect(NotionPageID.parse("https://www.notion.so/ws/Title") == nil)
    }

    // MARK: When changes go out

    @Test func changesWaitForTypingToPause() async {
        let id = addNote("最初のメモ")
        clock.advance(9)
        await sync.processDue()
        #expect(api.calls.isEmpty)
        clock.advance(1)
        await sync.processDue()
        #expect(api.calls == [
            .query(noteID: id.uuidString),
            .createPage(markdown: "最初のメモ", properties: [
                "名前": .title("最初のメモ"), "メモID": .richText(id.uuidString), "色": .select("イエロー"),
                "状態": .select("使用中"), "更新日時": .date(store.meta(id)!.modified),
            ]),
        ])
    }

    @Test func continuousTypingIsSentAtLeastEveryMinute() async {
        let id = addNote("a")
        var text = "a"
        for second in stride(from: 5, through: 55, by: 5) {
            clock.advance(5)
            text += "\(second)"
            store.updateBody(text, for: id)
            await sync.processDue()
        }
        #expect(api.calls.isEmpty) // 55 s of typing, never a 10 s pause
        clock.advance(5)
        store.updateBody(text + "!", for: id)
        await sync.processDue()
        #expect(api.writes.count == 1)
    }

    @Test func unchangedExportIsNotSentAgain() async {
        let id = await pushedNote("# 見出し\n本文")
        await edit(id, "# 見出し\n本文\n\n\n") // trailing blank lines export the same
        #expect(api.calls.isEmpty)
    }

    @Test func unsavedTextIsWhatGoesOut() async {
        let id = await pushedNote("v1")
        store.flush()
        store.updateBody("v2", for: id) // the store saves it a moment later
        clock.advance(10)
        await sync.processDue()
        #expect(api.calls.first == .replace(page: "page-1", markdown: "v2"))
    }

    @Test func readingNotesForTheSyncDoesNotHideAnotherAppsEdit() async throws {
        var reported: [String] = []
        store.onExternalChange = { _, text in reported.append(text) }
        let id = await pushedNote("アプリの文")
        store.flush()
        let url = store.bodyURL(for: id)
        try Data("別のアプリの文".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        await sync.syncNow() // reads every note's file
        #expect(api.calls.contains(.replace(page: "page-1", markdown: "別のアプリの文")))
        store.updateBody("アプリの文、続き", for: id) // the window still showed the old text
        store.flush()
        #expect(reported == ["別のアプリの文"]) // kept in the history before being overwritten
    }

    @Test func existingPageIsUpdatedNotRecreated() async {
        let id = await pushedNote("v1")
        await edit(id, "# v2 の見出し\n- [ ] $5 の買い物")
        #expect(api.calls == [
            .replace(page: "page-1", markdown: "# v2 の見出し\n- [ ] \\$5 の買い物"),
            .update(page: "page-1", properties: ["名前": .title("v2 の見出し"), "更新日時": .date(store.meta(id)!.modified),
                                                 "状態": .select("使用中"), "色": .select("イエロー")]),
        ])
    }

    @Test func colorChangeUpdatesOnlyTheProperty() async {
        let id = await pushedNote("色のテスト")
        var meta = store.meta(id)!
        meta.color = .pink
        store.updateMeta(meta)
        clock.advance(10)
        await sync.processDue()
        #expect(api.calls == [.update(page: "page-1", properties: ["色": .select("ピンク")])])
        meta.frame = CGRect(x: 1, y: 2, width: 3, height: 4) // moving the window is not a change
        store.updateMeta(meta)
        clock.advance(10)
        await sync.processDue()
        #expect(api.calls.count == 1)
    }

    @Test func pageLeftByACrashIsFoundInsteadOfDuplicated() async {
        let id = UUID()
        api.existing[id.uuidString] = "page-from-before"
        store.add(NoteMeta(id: id, frame: .zero), body: "クラッシュ前に作られたページ")
        clock.advance(10)
        await sync.processDue()
        #expect(api.calls.first == .query(noteID: id.uuidString))
        #expect(!api.calls.contains { if case .createPage = $0 { true } else { false } })
        #expect(api.calls.contains(.replace(page: "page-from-before", markdown: "クラッシュ前に作られたページ")))
    }

    @Test func emptyNewNotesAreNotCreated() async {
        addNote("")
        addNote("  \n\n")
        clock.advance(10)
        await sync.processDue()
        #expect(api.calls.isEmpty)
    }

    // MARK: Destructive-change guard

    @Test func largeDeletionIsHeldForFifteenMinutes() async {
        let long = String(repeating: "大事なメモの本文。", count: 40) // 360 characters
        let id = await pushedNote(long)
        await edit(id, "消えた")
        #expect(api.calls.isEmpty)
        #expect(sync.heldCount == 1)
        clock.advance(14 * 60)
        await sync.processDue()
        #expect(api.calls.isEmpty)
        clock.advance(60)
        await sync.processDue()
        #expect(api.calls.first == .replace(page: "page-1", markdown: "消えた"))
        #expect(sync.heldCount == 0)
    }

    @Test func heldDeletionIsDroppedWhenTheTextComesBack() async {
        let long = String(repeating: "あ", count: 300)
        let id = await pushedNote(long)
        await edit(id, "")
        #expect(sync.heldCount == 1)
        await edit(id, long) // ⌘Z
        clock.advance(20 * 60)
        await sync.processDue()
        #expect(api.calls.isEmpty)
        #expect(sync.heldCount == 0)
    }

    @Test func heldDeletionIsSentOnlyIfStillTheLatestState() async {
        let long = String(repeating: "い", count: 300)
        let id = await pushedNote(long)
        await edit(id, "短い")
        clock.advance(5 * 60)
        await edit(id, "短い、別の文") // a new state: its own 15 minutes
        clock.advance(10 * 60)
        await sync.processDue()
        #expect(api.calls.isEmpty)
        clock.advance(5 * 60)
        await sync.processDue()
        #expect(api.calls.first == .replace(page: "page-1", markdown: "短い、別の文"))
    }

    @Test func smallNotesAreOnlyHeldWhenEmptied() async {
        let id = await pushedNote("買い物リスト")
        await edit(id, "買")
        #expect(api.calls.first == .replace(page: "page-1", markdown: "買")) // under 200 characters: sent
        api.calls = []
        await edit(id, "")
        #expect(api.calls.isEmpty)
        #expect(sync.heldCount == 1)
    }

    @Test func largeDeletionIsStillHeldAfterTheDatabaseWasUnshared() async {
        let long = String(repeating: "大事なメモの本文。", count: 40)
        let id = await pushedNote(long)
        api.failures = [.notFound(message: "page"), .notFound(message: "database")] // the replace, then the lookup
        await edit(id, long + "追記")
        #expect(sync.lastError != nil)
        store.updateBody("消えた", for: id) // an accident while the sync is stopped
        await sync.syncNow() // shared again
        #expect(!api.calls.contains(.replace(page: "page-1", markdown: "消えた")))
        #expect(sync.heldCount == 1)
    }

    @Test func quittingSendsPendingChangesButNotHeldDeletions() async {
        let id = await pushedNote(String(repeating: "う", count: 300))
        store.updateBody("", for: id)
        clock.advance(10)
        await sync.processDue() // the deletion is held
        #expect(!sync.hasPendingWork)
        addNote("閉じる直前に書いたメモ") // quit within the 10 s debounce
        #expect(sync.hasPendingWork)
        await sync.flush(timeout: 5)
        #expect(api.calls.contains { if case .createPage(let md, _) = $0 { md == "閉じる直前に書いたメモ" } else { false } })
        #expect(!api.calls.contains { if case .replace(page: "page-1", _) = $0 { true } else { false } })
        #expect(!sync.hasPendingWork)
    }

    @Test func quittingGivesUpAfterTheTimeoutAndSchedulesNothingMore() async {
        var clockReads = 0
        let quitting = Self.makeSync(store: store, api: api, tokens: tokens, clock: clock,
                                     now: { clockReads += 1; return clock.now }, autoWake: true)
        quitting.start()
        api.holdWhen = { if case .createPage = $0 { true } else { false } } // Notion never answers
        addNote("終了の直前に書いたメモ")
        #expect(quitting.hasPendingWork)
        let started = ContinuousClock.now
        await quitting.flush(timeout: 0.2)
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(quitting.pendingCount == 1) // kept for the next launch
        let reads = clockReads
        try? await Task.sleep(for: .milliseconds(200))
        #expect(clockReads == reads) // no wake-up loop after giving up
    }

    // MARK: Deleting and restoring

    @Test func deletedNotesAreMarkedNeverTrashed() async {
        let id = await pushedNote("閉じるメモ")
        store.markDeleted(id)
        await sync.processDue()
        #expect(api.calls == [.update(page: "page-1", properties: ["状態": .select("削除済み")])])
        api.calls = []
        store.restore(id)
        await sync.processDue()
        #expect(api.calls == [.update(page: "page-1", properties: ["状態": .select("使用中")])])
    }

    @Test func textTypedJustBeforeClosingGoesOutWithTheDeletion() async {
        let id = await pushedNote("下書き")
        store.updateBody("下書き、完成", for: id)
        store.markDeleted(id) // closed within the 10 s debounce
        await sync.processDue()
        #expect(api.calls.first == .replace(page: "page-1", markdown: "下書き、完成"))
        #expect(api.calls.contains { if case .update(_, let p) = $0 { p["状態"] == .select("削除済み") } else { false } })
    }

    @Test func closedNoteWhosePageIsGoneIsLeftAlone() async {
        let id = await pushedNote("閉じたメモ")
        api.failures = [.notFound(message: "")] // deleted in Notion
        store.markDeleted(id)
        await sync.processDue()
        #expect(!api.calls.contains(where: isCreate))
        #expect(sync.lastError == nil)
        api.calls = []
        await sync.syncNow()
        #expect(api.calls.isEmpty) // nothing left to mark
    }

    @Test func notesNeverMirroredAreNotCreatedWhenDeleted() async {
        let id = addNote("すぐ閉じた")
        store.markDeleted(id)
        clock.advance(10)
        await sync.processDue()
        #expect(api.calls.isEmpty)
    }

    @Test func launchReconcilesWhatChangedWhileSyncWasOff() async {
        let a = await pushedNote("A の本文")
        let b = await pushedNote("B の本文")
        sync.pause()
        store.updateBody("A を編集", for: a)
        store.markDeleted(b)
        store.flush()
        api.calls = []

        let relaunched = Self.makeSync(store: store, api: api, tokens: tokens, clock: clock)
        relaunched.start()
        #expect(!relaunched.isEnabled)
        relaunched.resume()
        await relaunched.processDue()
        #expect(api.calls.contains(.replace(page: "page-1", markdown: "A を編集")))
        #expect(api.calls.contains(.update(page: "page-2", properties: ["状態": .select("削除済み")])))
        #expect(!api.calls.contains { if case .createPage = $0 { true } else { false } })
    }

    @Test func startAtLaunchUsesTheSavedStateAndToken() async {
        let a = await pushedNote("起動前")
        store.updateBody("起動後に変わった", for: a)
        store.flush()
        api.calls = []
        let relaunched = Self.makeSync(store: store, api: api, tokens: tokens, clock: clock)
        relaunched.start()
        #expect(relaunched.isEnabled)
        await relaunched.processDue()
        #expect(api.calls.first == .replace(page: "page-1", markdown: "起動後に変わった"))
    }

    // MARK: Errors

    @Test func unauthorizedStopsSyncingUntilTheUserActs() async {
        let id = addNote("メモ")
        api.failures = [.unauthorized]
        clock.advance(10)
        await sync.processDue()
        #expect(sync.lastError?.contains("トークンが無効です") == true)
        api.calls = []
        store.updateBody("メモ2", for: id)
        clock.advance(60)
        await sync.processDue()
        #expect(api.calls.isEmpty)
        #expect(sync.pendingCount == 1)

        await sync.syncNow()
        #expect(api.writes.count == 1)
        #expect(sync.lastError == nil)
    }

    @Test func offlineKeepsTheNoteAndRetriesWithBackoff() async {
        addNote("オフライン")
        api.failures = [.network(message: "offline")]
        clock.advance(10)
        await sync.processDue()
        #expect(sync.lastError != nil)
        #expect(sync.pendingCount == 1)
        api.calls = []
        clock.advance(5)
        await sync.processDue()
        #expect(api.calls.isEmpty) // backing off
        clock.advance(10)
        await sync.processDue()
        #expect(api.writes.count == 1)
        #expect(sync.pendingCount == 0 && sync.lastError == nil)
    }

    @Test func rejectedContentIsNotRetriedUntilTheNoteChanges() async {
        let id = await pushedNote("v1")
        api.failures = [.validation(message: "body failed validation")]
        await edit(id, "v2")
        #expect(sync.lastError?.contains("v2") == true)
        api.calls = []
        await sync.syncNow()
        #expect(api.calls.contains(.replace(page: "page-1", markdown: "v2"))) // 今すぐ同期 retries
        api.calls = []
        api.failures = [.validation(message: "again")]
        await edit(id, "v3")
        api.calls = []
        clock.advance(60)
        await sync.processDue()
        #expect(api.calls.isEmpty)
        await edit(id, "v4")
        #expect(api.calls.contains(.replace(page: "page-1", markdown: "v4")))
    }

    @Test func pageDeletedInNotionIsCreatedAgain() async {
        let id = await pushedNote("v1")
        api.failures = [.notFound(message: "Could not find page")]
        await edit(id, "v2")
        #expect(api.calls.contains { if case .createPage(let md, _) = $0 { md == "v2" } else { false } })
        #expect(sync.lastError == nil)
    }

    @Test func pageMovedToTheTrashInNotionIsCreatedAgain() async {
        let id = await pushedNote("v1")
        api.trashed = ["page-1"]
        api.failures = [.validation(message: "Can't edit block that is archived.")]
        await edit(id, "v2")
        #expect(api.calls.contains(.page("page-1")))
        #expect(api.calls.contains { if case .createPage(let md, _) = $0 { md == "v2" } else { false } })
        #expect(sync.lastError == nil)
        api.calls = []
        await edit(id, "v3")
        #expect(api.calls.first == .replace(page: "page-2", markdown: "v3"))
    }

    @Test func unsharedDatabaseStopsTheSyncButForgetsNothing() async {
        let id = await pushedNote("閉じるメモ")
        api.failures = [.notFound(message: "page"), .notFound(message: "database")] // the update, then the lookup
        store.markDeleted(id)
        await sync.processDue()
        #expect(sync.lastError?.contains("見つかりません") == true)
        api.calls = []
        await sync.syncNow() // shared again
        #expect(api.calls == [.update(page: "page-1", properties: ["状態": .select("削除済み")])])
    }

    @Test func titleIsSentAgainWhenOnlyThePropertyUpdateFailed() async {
        let id = await pushedNote("v1")
        api.failures = [nil, .network(message: "offline")] // the replace works, the property update does not
        await edit(id, "# 新しい題\n本文")
        clock.advance(30)
        await sync.processDue()
        #expect(api.calls.filter { if case .replace = $0 { true } else { false } }.count == 1)
        #expect(api.calls.last == .update(page: "page-1", properties: [
            "名前": .title("新しい題"), "更新日時": .date(store.meta(id)!.modified),
            "状態": .select("使用中"), "色": .select("イエロー")]))
    }

    @Test func refusedContentDoesNotHoldBackClosingTheNote() async {
        let id = await pushedNote("v1")
        api.failures = [.validation(message: "Cannot delete child pages or databases: 議事録")]
        await edit(id, "v2")
        #expect(sync.lastError?.contains("サブページ") == true)
        api.calls = []
        store.markDeleted(id)
        await sync.processDue()
        #expect(api.calls == [.update(page: "page-1", properties: ["状態": .select("削除済み")])])
    }

    @Test func pageSavedDespiteA503IsNotCreatedTwice() async {
        let id = addNote("保存されたメモ")
        api.failures = [nil, .server(status: 503, committedResourceID: "page-saved")] // the lookup, then the create
        clock.advance(10)
        await sync.processDue()
        #expect(sync.lastError == nil)
        api.calls = []
        await edit(id, "保存されたメモ、続き")
        #expect(api.calls.first == .replace(page: "page-saved", markdown: "保存されたメモ、続き"))
    }

    @Test func aCancellationNobodyAskedForBacksOff() async {
        addNote("メモ")
        api.spuriousCancellation = true
        clock.advance(10)
        await sync.processDue()
        #expect(sync.pendingCount == 1 && sync.lastError != nil)
        api.calls = []
        await sync.processDue()
        #expect(api.calls.isEmpty) // waiting, not retrying at once
        clock.advance(15)
        await sync.processDue()
        #expect(api.writes.count == 1)
    }

    // MARK: Requests in flight and the timer

    @Test func pausingWhileARequestIsInFlightSendsNothingMore() async {
        addNote("one")
        addNote("two")
        clock.advance(10)
        api.holdWhen = { if case .createPage = $0 { true } else { false } }
        let run = Task { await sync.processDue() }
        while !api.isHolding { await Task.yield() }
        api.release() // Notion has answered…
        sync.pause()  // …but the run has not seen it yet
        await run.value
        #expect(api.createdIn == ["ds-1"]) // recorded; the other note waits for 同期を再開
        #expect(sync.pendingCount == 0)
        sync.resume()
        await sync.processDue()
        #expect(api.createdIn == ["ds-1", "ds-1"]) // the first page is not created twice
    }

    @Test func theTimerSendsChangesWithoutBeingAsked() async throws {
        let live = Self.makeSync(store: store, api: api, tokens: tokens, clock: clock, now: Date.init,
                                 timing: NotionSync.Timing(debounce: 0.05, maxWait: 0.2), autoWake: true)
        live.start()
        addNote("自動で送られるメモ")
        let deadline = ContinuousClock.now + .seconds(5)
        while !api.calls.contains(where: isCreate), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(api.calls.contains(where: isCreate))
    }

    @Test func disconnectDeletesTheTokenAndStops() async {
        let id = await pushedNote("v1")
        sync.disconnect()
        #expect(tokens.token == nil && !sync.isEnabled && !sync.hasToken)
        await edit(id, "v2")
        #expect(api.calls.isEmpty)
    }
}
