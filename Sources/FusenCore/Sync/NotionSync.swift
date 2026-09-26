import CryptoKit
import Foundation
import Observation

/// What the app knows about the Notion mirror, in <root>/notion-sync.json. If the file is lost, the
/// sync stops (the settings window says so) until the user connects to the same page again, which
/// finds the "fusen.md" database in that page and each note's page by its メモID, so
/// nothing is created twice.
struct NotionSyncState: Codable, Equatable, Sendable {
    struct Note: Codable, Equatable, Sendable {
        var pageID: String
        /// SHA-256 of the exported Markdown last sent (nil: the content was never sent).
        var lastPushedHash: String?
        var lastPushedAt: Date?
        /// Length in characters of that export; the destructive-change guard compares with it.
        var lastPushedLength: Int?
        /// 状態 last written (使用中 / 削除済み).
        var status: String?
        /// 色 last written.
        var color: String?
        /// The content was replaced, but 名前 and 更新日時 are not written yet (that request failed).
        var propertiesPending: Bool?

        init(pageID: String, lastPushedHash: String? = nil, lastPushedAt: Date? = nil,
             lastPushedLength: Int? = nil, status: String? = nil, color: String? = nil,
             propertiesPending: Bool? = nil) {
            self.pageID = pageID
            self.lastPushedHash = lastPushedHash
            self.lastPushedAt = lastPushedAt
            self.lastPushedLength = lastPushedLength
            self.status = status
            self.color = color
            self.propertiesPending = propertiesPending
        }
    }

    var version = 1
    var enabled = false
    var parentPageID: String?
    var parentPageURL: String?
    var databaseID: String?
    var dataSourceID: String?
    var databaseURL: String?
    var workspaceName: String?
    var lastSyncAt: Date?
    /// Keyed by the note's UUID string.
    var notes: [String: Note] = [:]

    init() {}

    // Hand-written so a file written by another version still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        parentPageID = try c.decodeIfPresent(String.self, forKey: .parentPageID)
        parentPageURL = try c.decodeIfPresent(String.self, forKey: .parentPageURL)
        databaseID = try c.decodeIfPresent(String.self, forKey: .databaseID)
        dataSourceID = try c.decodeIfPresent(String.self, forKey: .dataSourceID)
        databaseURL = try c.decodeIfPresent(String.self, forKey: .databaseURL)
        workspaceName = try c.decodeIfPresent(String.self, forKey: .workspaceName)
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        notes = try c.decodeIfPresent([String: Note].self, forKey: .notes) ?? [:]
    }
}

/// One-way mirror of the notes into a Notion database ("fusen.md") under a page the user
/// picks. The files on this Mac stay the source of truth, and the app's own history stays the way
/// to undo: Notion only ever receives the current text, and pages are never trashed.
///
/// - A change is sent 10 s after the last keystroke (at most 60 s while typing continues), only if
///   the exported Markdown changed (SHA-256). A note without a page is looked up by メモID before a
///   page is created, so a crash between "created" and "recorded" does not duplicate it.
/// - Destructive-change guard: if the export became empty, or shorter than 40 % of the last pushed
///   text when that was over 200 characters, the content is held for 15 minutes and sent only if
///   it is still the latest state then — an accidental ⌘A ⌫ is not mirrored right away.
/// - Closing a note sets 状態 to 削除済み; restoring it sets 使用中 again.
/// - Content Notion refuses (400) is not sent again until the note changes; 状態 and 色 still are.
/// - A page deleted in Notion or moved to its trash is looked up by メモID and otherwise created
///   again. If the database cannot be read either, nothing is forgotten: like 401/403, that stops the
///   sync until the user reconnects or presses 今すぐ同期.
/// - Offline or server errors keep the notes pending and retry with backoff.
/// - Notes are read from their files (plus text the store has not saved yet), never through
///   `NoteStore.body(of:)`, which would hide another app's edit from the store's history copy.
@MainActor
@Observable
final class NotionSync {
    enum Property {
        static let title = "名前"
        static let noteID = "メモID"
        static let color = "色"
        static let status = "状態"
        static let modified = "更新日時"
    }

    enum Status {
        static let active = "使用中"
        static let deleted = "削除済み"
    }

    static let databaseTitle = "fusen.md"

    static var schema: [String: NotionPropertySchema] {
        [Property.title: .title,
         Property.noteID: .richText,
         Property.color: .select(NoteColor.allCases.map { NotionSelectOption(name: $0.title, color: $0.notionColor) }),
         Property.status: .select([NotionSelectOption(name: Status.active, color: "green"),
                                   NotionSelectOption(name: Status.deleted, color: "gray")]),
         Property.modified: .date]
    }

    struct Timing {
        /// Quiet time after the last change before it is sent.
        var debounce: TimeInterval = 10
        /// Longest wait while changes keep coming.
        var maxWait: TimeInterval = 60
        /// How long a destructive change is held.
        var hold: TimeInterval = 15 * 60
        var firstRetry: TimeInterval = 15
        var maxRetry: TimeInterval = 10 * 60
    }

    struct SyncError: Error, Equatable {
        let message: String
    }

    static let missingToken = "Keychain に Notion のトークンが見つかりません。設定で接続し直してください。"
    static let stateUnreadable = "Notion 連携の状態（notion-sync.json）を読み込めなかったため、同期を止めています。設定で同じページにもう一度接続すると、既存のデータベースとページを探して、そのまま同期を続けます。"

    // MARK: Status (observed by the settings window)

    /// A database was created (connected at least once).
    private(set) var isConfigured = false
    /// Sync is switched on (a database exists and the user has not stopped it).
    private(set) var isEnabled = false
    private(set) var isSyncing = false
    private(set) var lastSyncAt: Date?
    /// Notes waiting to be sent (not counting held ones).
    private(set) var pendingCount = 0
    /// Notes whose large deletion is being held.
    private(set) var heldCount = 0
    /// Japanese, for the status line; nil when the last attempt worked.
    private(set) var lastError: String?
    private(set) var workspaceName: String?
    private(set) var databaseURL: String?
    private(set) var parentPageURL: String?
    /// A token is in the Keychain (its value is never exposed).
    private(set) var hasToken = false

    let timing: Timing
    private let store: NoteStore
    private let styler: MarkdownStyler
    private let stateURL: URL
    private let tokenStore: NotionTokenStore
    private let makeClient: (String) -> any NotionAPI
    private let now: () -> Date
    /// Off in tests, which call `processDue()` themselves after moving their clock.
    private let autoWake: Bool

    private struct Pending {
        var firstChange: Date
        var lastChange: Date
        /// Deletion, restoration, launch and "sync now" do not wait for typing to stop.
        var immediate: Bool
        /// Held until then (destructive-change guard).
        var notBefore: Date?
    }

    private struct Hold {
        var since: Date
        var hash: String
    }

    private struct Snapshot {
        let markdown: String
        let hash: String
        let length: Int
        let title: String
        let color: String
        let status: String
    }

    private struct Database {
        let id: String
        let dataSourceID: String
        let url: String?
    }

    /// What a run sends with; the run stops as soon as it is no longer current.
    private struct Connection {
        let client: any NotionAPI
        let dataSourceID: String
        let session: Int
    }

    @ObservationIgnored private var state = NotionSyncState()
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var client: (any NotionAPI)?
    /// Changes with `client`; a run started with an earlier one stops without recording anything.
    @ObservationIgnored private var session = 0
    /// While `connect` switches the connection: nothing is sent.
    @ObservationIgnored private var suspended = false
    /// A database made by a `connect` that failed afterwards (e.g. the Keychain refused the token);
    /// the next attempt for the same page uses it instead of creating another one.
    @ObservationIgnored private var uncommitted: (parentID: String, database: Database)?
    /// Text from NoteStore's change callback, and when it came: newer than the note's file until the
    /// store's debounced save has written it (or while saving fails).
    @ObservationIgnored private var unsavedText: [UUID: (text: String, since: Date)] = [:]
    @ObservationIgnored private var pending: [UUID: Pending] = [:]
    @ObservationIgnored private var holds: [UUID: Hold] = [:]
    /// Content Notion refused (400); not retried until the note changes.
    @ObservationIgnored private var rejected: [UUID: String] = [:]
    /// 401/403/404: nothing is sent until the user reconnects or presses 今すぐ同期.
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var retryAt: Date?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var wakeAt: Date?
    /// Set when quitting ran out of time; the app is about to exit, so nothing is scheduled again.
    @ObservationIgnored private var flushTimedOut = false

    init(store: NoteStore, styler: MarkdownStyler,
         tokenStore: NotionTokenStore = KeychainTokenStore(),
         makeClient: @escaping (String) -> any NotionAPI = { NotionClient(token: $0) },
         now: @escaping () -> Date = Date.init,
         timing: Timing = Timing(),
         autoWake: Bool = true) {
        self.store = store
        self.styler = styler
        self.tokenStore = tokenStore
        self.makeClient = makeClient
        self.now = now
        self.timing = timing
        self.autoWake = autoWake
        stateURL = store.rootURL.appendingPathComponent("notion-sync.json")
    }

    // MARK: Lifecycle

    /// At launch: loads the state and, if sync is on, sends whatever changed while the app was closed.
    /// Reading the token may bring up a Keychain prompt, so the app calls this once its notes are open.
    func start() {
        loadState()
        guard state.enabled, state.dataSourceID != nil else { return publish() }
        guard let token = tokenStore.readToken() else {
            lastError = Self.missingToken
            return publish()
        }
        hasToken = true
        use(makeClient(token))
        publish()
        reconcile()
    }

    /// Validates the token and the parent page, finds or creates the database, saves the token to
    /// the Keychain and starts the first full push. An empty `token` reuses the saved one. Nothing
    /// changes unless all of that works.
    func connect(token newToken: String, parentPageURL url: String) async throws(SyncError) {
        loadState()
        guard let parentID = NotionPageID.parse(url) else {
            throw SyncError(message: "ページの URL を読み取れませんでした。Notion でページを開き、「リンクをコピー」で取得した URL を貼り付けてください。")
        }
        let trimmed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = trimmed.isEmpty ? tokenStore.readToken() : trimmed else {
            throw SyncError(message: "トークンを入力してください。")
        }
        let client = makeClient(token)
        isSyncing = true
        defer { isSyncing = false }

        let user: NotionUser
        do {
            user = try await client.retrieveMe()
            _ = try await client.retrievePage(id: parentID)
        } catch NotionError.notFound {
            throw SyncError(message: "親ページが見つかりません。Notion でそのページを開き、右上の ••• > 接続 からこのコネクションを追加してください。")
        } catch {
            throw SyncError(message: Self.describe(error))
        }

        // Nothing is sent while the connection changes: a run in flight is cancelled and awaited, so
        // it cannot put pages of the old database into the new mapping.
        suspended = true
        defer {
            suspended = false
            scheduleWake()
        }
        wakeTask?.cancel()
        wakeTask = nil
        wakeAt = nil
        runTask?.cancel()
        while let running = runTask { await running.value }
        isSyncing = true

        let database: Database
        do {
            database = try await self.database(under: parentID, client: client)
        } catch {
            throw SyncError(message: Self.describe(error))
        }
        do {
            try tokenStore.saveToken(token)
        } catch {
            throw SyncError(message: "トークンを Keychain に保存できませんでした（\(error)）")
        }
        uncommitted = nil
        if state.dataSourceID != database.dataSourceID {
            state.databaseID = database.id
            state.dataSourceID = database.dataSourceID
            state.databaseURL = database.url
            state.notes = [:] // the pages of an earlier database stay where they are
        }
        state.parentPageID = parentID
        state.parentPageURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        state.workspaceName = user.bot?.workspaceName
        state.enabled = true
        saveState()
        use(client)
        hasToken = true
        resetErrors()
        publish()
        reconcile()
    }

    /// The database to mirror into, in this order: the one in use (if it is in this page and still
    /// there), one made by an earlier attempt that failed afterwards, a "fusen.md" database
    /// already in the page (notion-sync.json was lost), or a new one.
    private func database(under parentID: String, client: any NotionAPI) async throws -> Database {
        var known: [Database] = []
        if state.parentPageID == parentID, let id = state.databaseID, let dataSourceID = state.dataSourceID {
            known.append(Database(id: id, dataSourceID: dataSourceID, url: state.databaseURL))
        }
        if let uncommitted, uncommitted.parentID == parentID { known.append(uncommitted.database) }
        for database in known {
            if try await isMirror(database.dataSourceID, client: client) { return database }
        }
        for child in try await client.childDatabases(pageID: parentID) where child.title == Self.databaseTitle {
            let found = try await client.retrieveDatabase(id: child.id)
            if let dataSourceID = found.dataSources.first?.id, try await isMirror(dataSourceID, client: client) {
                return Database(id: found.id, dataSourceID: dataSourceID, url: found.url)
            }
        }
        let created: NotionDatabase
        do {
            created = try await client.createDatabase(parentPageID: parentID, title: Self.databaseTitle,
                                                      properties: Self.schema)
        } catch NotionError.server(_, let committed?) {
            // Saved although Notion answered 503 (reference/request-limits): read it, do not create another.
            created = try await client.retrieveDatabase(id: committed)
        }
        guard let dataSourceID = created.dataSources.first?.id else { throw NotionError.invalidResponse }
        let database = Database(id: created.id, dataSourceID: dataSourceID, url: created.url)
        uncommitted = (parentID, database)
        return database
    }

    /// The data source exists and has a メモID property (any query tells; this one finds nothing).
    private func isMirror(_ dataSourceID: String, client: any NotionAPI) async throws -> Bool {
        do {
            _ = try await client.queryPages(dataSourceID: dataSourceID, property: Property.noteID, equals: UUID().uuidString)
            return true
        } catch NotionError.notFound {
            return false // deleted or unshared in Notion
        } catch NotionError.validation {
            return false // not one of this app's databases
        }
    }

    /// 同期を停止: keeps the token and the pages; nothing is sent until `resume()`.
    func pause() {
        loadState()
        state.enabled = false
        saveState()
        stopWork()
        publish()
    }

    /// 同期を再開.
    func resume() {
        loadState()
        guard state.dataSourceID != nil else { return }
        guard let token = tokenStore.readToken() else {
            lastError = Self.missingToken
            return
        }
        state.enabled = true
        saveState()
        hasToken = true
        use(makeClient(token))
        resetErrors()
        publish()
        reconcile()
    }

    /// 接続を解除: deletes the token from the Keychain. The Notion pages and the mapping are kept, so
    /// connecting to the same page later updates the same pages again.
    func disconnect() {
        loadState()
        tokenStore.deleteToken()
        hasToken = false
        state.enabled = false
        saveState()
        stopWork()
        lastError = nil
        publish()
    }

    /// 今すぐ同期: retries after an error and sends every changed note without waiting.
    func syncNow() async {
        loadState()
        guard state.enabled, state.dataSourceID != nil else { return }
        if client == nil {
            guard let token = tokenStore.readToken() else {
                lastError = Self.missingToken
                return
            }
            hasToken = true
            use(makeClient(token))
        }
        resetErrors()
        reconcile()
        await processDue(force: true)
    }

    // MARK: Import (Notion → sticky, only when the user asks)

    /// A note's current content in Notion, converted to the app's Markdown.
    struct Import: Equatable {
        let text: String
        /// Notion-only elements (callouts, colors, images, …) that the sticky can only show as text.
        let notionOnly: [String]
    }

    /// The note has a page in Notion to import from (the sync may be paused; it must be connected).
    func canImport(_ id: UUID) -> Bool {
        loadState()
        guard state.dataSourceID != nil, state.notes[id.uuidString] != nil else { return false }
        return client != nil || hasToken || tokenStore.containsToken() // attributes only: no Keychain prompt
    }

    /// Reads the note's page from Notion. Changes nothing: the caller replaces the sticky's text (after
    /// saving it to the history), and the next push sends it back in the app's normalized form.
    func fetchImport(_ id: UUID) async throws(SyncError) -> Import {
        loadState()
        guard state.dataSourceID != nil, let pageID = state.notes[id.uuidString]?.pageID else {
            throw SyncError(message: "このメモはまだ Notion に送られていません。")
        }
        let api: any NotionAPI
        if let client {
            api = client
        } else {
            guard let token = tokenStore.readToken() else { throw SyncError(message: Self.missingToken) }
            hasToken = true
            api = makeClient(token)
        }
        let page: NotionPageMarkdown
        do {
            page = try await api.retrieveMarkdown(pageID: pageID)
        } catch NotionError.notFound {
            throw SyncError(message: "Notion にこのメモのページが見つかりません。削除されたか、共有が外れた可能性があります。")
        } catch {
            throw SyncError(message: Self.describe(error))
        }
        // A partial page must never replace the sticky: the next push would cut the page in Notion too.
        guard !page.truncated, page.unknownBlockIDs.isEmpty else {
            throw SyncError(message: "Notion のページの一部を読み込めなかったため（大きすぎるか、共有されていないブロックがあります）、取り込みを中止しました。")
        }
        return Import(text: NotionMarkdown.fromNotion(page.markdown),
                      notionOnly: NotionMarkdown.notionOnlyElements(in: page.markdown))
    }

    /// Checks the Keychain (for the settings window), without reading the token out.
    func refreshTokenPresence() {
        hasToken = tokenStore.containsToken()
    }

    /// Sends pending changes before quitting (held deletions stay held), giving up after `timeout`.
    func flush(timeout: TimeInterval) async {
        guard hasPendingWork || runTask != nil else { return }
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self else { return }
            self.flushTimedOut = true
            self.runTask?.cancel()
        }
        await processDue(force: true)
        timer.cancel()
    }

    /// Something can be sent right now (used to decide whether quitting should wait).
    var hasPendingWork: Bool {
        guard state.enabled, client != nil, !stopped else { return false }
        let t = now()
        return pending.values.contains { ($0.notBefore ?? .distantPast) <= t }
    }

    // MARK: Changes (called by NoteStore)

    /// `text`: the new text, when it changed (NoteStore saves it a moment later).
    func noteChanged(_ id: UUID, text: String? = nil) {
        // Wall-clock time, compared with the file's modification date (not the injectable `now`).
        if let text { unsavedText[id] = (text, Date()) }
        guard state.enabled, client != nil else { return }
        rejected[id] = nil
        let t = now()
        var item = pending[id] ?? Pending(firstChange: t, lastChange: t, immediate: false)
        item.lastChange = t
        item.notBefore = nil // re-evaluated by the guard
        pending[id] = item
        updateCounts()
        scheduleWake()
    }

    func noteDeleted(_ id: UUID) { markImmediate(id) }

    func noteRestored(_ id: UUID) {
        unsavedText[id] = nil // the store saved the restored text just before
        markImmediate(id)
    }

    private func markImmediate(_ id: UUID) {
        guard state.enabled, client != nil else { return }
        let t = now()
        var item = pending[id] ?? Pending(firstChange: t, lastChange: t, immediate: true)
        item.immediate = true
        item.lastChange = t
        item.notBefore = nil
        pending[id] = item
        updateCounts()
        scheduleWake()
    }

    /// Queues every note whose Notion page is out of date (content, color, 状態, 名前).
    private func reconcile() {
        guard state.enabled, client != nil else { return }
        for meta in store.metas where needsPush(meta) {
            markImmediate(meta.id)
        }
        // Notes forgotten locally (NoteStore.remove) whose page is not marked yet.
        for (key, entry) in state.notes where entry.status != Status.deleted {
            if let id = UUID(uuidString: key), store.meta(id) == nil { markImmediate(id) }
        }
    }

    private func needsPush(_ meta: NoteMeta) -> Bool {
        let snap = snapshot(of: meta)
        guard let entry = state.notes[meta.id.uuidString] else {
            return !meta.isDeleted && !snap.markdown.isEmpty
        }
        return entry.lastPushedHash != snap.hash || entry.status != snap.status || entry.color != snap.color
            || entry.propertiesPending == true
    }

    // MARK: Pushing

    private func due(_ item: Pending) -> Date {
        var date = item.immediate ? item.lastChange
            : min(item.lastChange.addingTimeInterval(timing.debounce), item.firstChange.addingTimeInterval(timing.maxWait))
        if let notBefore = item.notBefore { date = max(date, notBefore) }
        return date
    }

    /// Sends the notes that are due (all pending ones with `force`, except held deletions).
    func processDue(force: Bool = false) async {
        while let running = runTask { await running.value } // one run at a time
        let task = Task { @MainActor [weak self] in
            await self?.run(force: force)
            self?.runTask = nil
        }
        runTask = task
        await task.value
    }

    private func run(force: Bool) async {
        guard !suspended, state.enabled, let client, !stopped, let dataSourceID = state.dataSourceID else { return }
        let connection = Connection(client: client, dataSourceID: dataSourceID, session: session)
        defer {
            isSyncing = false
            updateCounts()
            scheduleWake()
        }
        if !force, let retryAt, retryAt > now() { return }
        isSyncing = true
        while !flushTimedOut, !Task.isCancelled {
            let t = now()
            let ready = pending.filter { force ? ($0.value.notBefore ?? .distantPast) <= t : due($0.value) <= t }
            guard let id = ready.min(by: { due($0.value) < due($1.value) })?.key,
                  let item = pending.removeValue(forKey: id) else { break }
            updateCounts()
            do {
                try await push(id, connection)
                guard isCurrent(connection) else { break }
                failures = 0
                retryAt = nil
                lastError = nil
            } catch {
                // Paused, disconnected or connected elsewhere meanwhile: not this run's to report.
                guard isCurrent(connection) else { break }
                handle(error, id: id, item: item)
                if stopped || retryAt != nil || error is CancellationError { break }
            }
        }
    }

    private func isCurrent(_ connection: Connection) -> Bool {
        connection.session == session && connection.dataSourceID == state.dataSourceID && state.enabled
    }

    /// Before each further request of a push: stops if the connection changed meanwhile.
    private func ensureCurrent(_ connection: Connection) throws {
        guard isCurrent(connection) else { throw CancellationError() }
    }

    private func handle(_ error: Error, id: UUID, item: Pending) {
        func requeue() {
            var merged = item
            if let newer = pending[id] { // changed again while the request was in flight
                merged.lastChange = max(item.lastChange, newer.lastChange)
                merged.immediate = item.immediate || newer.immediate
                merged.notBefore = newer.notBefore
            }
            pending[id] = merged
        }
        switch error {
        case is CancellationError where Task.isCancelled || flushTimedOut:
            requeue() // stopped on purpose (quitting, connecting elsewhere): sent next time
        case NotionError.validation(let message):
            if let meta = store.meta(id) {
                rejected[id] = snapshot(of: meta).hash
                let title = NoteTitle.derive(from: text(of: id))
                lastError = Self.refusesToDeleteChildContent(message)
                    ? "「\(title)」の本文を同期できませんでした。Notion でこのメモのページにサブページかデータベースが追加されていて、本文を置き換えると消えてしまうためです。それをページの外へ移動してから「今すぐ同期」を押してください。"
                    : "「\(title)」を同期できませんでした。\(message)"
            }
        case NotionError.unauthorized, NotionError.forbidden, NotionError.notFound:
            requeue()
            stopped = true
            lastError = Self.describe(error)
        default:
            // Also a cancellation nobody asked for (URLSession reports some failures that way).
            requeue()
            failures += 1
            let delay = min(timing.firstRetry * pow(2, Double(failures - 1)), timing.maxRetry)
            retryAt = now().addingTimeInterval(delay)
            lastError = Self.describe(error)
        }
    }

    /// replace_content refuses to delete child pages or databases (allow_deleting_content is not
    /// sent); its message names them, so this looks for that wording.
    static func refusesToDeleteChildContent(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("allow_deleting_content") || (m.contains("delet") && (m.contains("child") || m.contains("database")))
    }

    private func push(_ id: UUID, _ c: Connection, isRetry: Bool = false) async throws {
        let key = id.uuidString
        let meta = store.meta(id)
        guard let entry = state.notes[key] else {
            // Never mirrored: nothing to mark for a deleted note, nothing to back up in an empty one.
            guard let meta, !meta.isDeleted else { return }
            let snap = snapshot(of: meta)
            guard !snap.markdown.isEmpty, rejected[id] != snap.hash else { return }
            if let found = try await c.client.queryPages(dataSourceID: c.dataSourceID, property: Property.noteID, equals: key).first {
                try record(NotionSyncState.Note(pageID: found.id), for: key, c) // created before a crash, never recorded
                return try await push(id, c, isRetry: isRetry)
            }
            try ensureCurrent(c)
            let page: NotionPage
            do {
                page = try await c.client.createPage(dataSourceID: c.dataSourceID,
                                                     properties: allProperties(snap, meta), markdown: snap.markdown)
            } catch NotionError.server(_, let committed?) {
                page = NotionPage(id: committed) // saved although Notion answered 503: not created twice
            }
            try record(NotionSyncState.Note(pageID: page.id, lastPushedHash: snap.hash, lastPushedAt: now(),
                                            lastPushedLength: snap.length, status: snap.status, color: snap.color),
                       for: key, c)
            return
        }
        do {
            try await update(id, meta: meta, entry: entry, c)
        } catch let error as NotionError where !isRetry {
            guard try await isGone(entry.pageID, after: error, c) else { throw error }
            try await replaceLostPage(id, meta: meta, entry: entry, c)
        }
    }

    /// Brings an existing page up to date: the content (unless held or refused), 名前 and 更新日時
    /// after new content, and 状態 and 色 whenever they differ, also when the content was refused.
    private func update(_ id: UUID, meta: NoteMeta?, entry: NotionSyncState.Note, _ c: Connection) async throws {
        let key = id.uuidString
        var entry = entry
        guard let meta else {
            // Forgotten locally: keep the page, mark it deleted.
            guard entry.status != Status.deleted else { return }
            try await c.client.updateProperties(pageID: entry.pageID, properties: [Property.status: .select(Status.deleted)])
            entry.status = Status.deleted
            return try record(entry, for: key, c)
        }
        let snap = snapshot(of: meta)
        var sendContent = entry.lastPushedHash != snap.hash && rejected[id] != snap.hash
        if sendContent, isDestructive(snap.length, comparedTo: entry.lastPushedLength) {
            let t = now()
            if let hold = holds[id], hold.hash == snap.hash, t >= hold.since.addingTimeInterval(timing.hold) {
                holds[id] = nil // still the latest state after the hold: meant, not accidental
            } else {
                if holds[id]?.hash != snap.hash { holds[id] = Hold(since: t, hash: snap.hash) }
                sendContent = false
                var item = pending[id] ?? Pending(firstChange: t, lastChange: t, immediate: true)
                item.notBefore = holds[id]!.since.addingTimeInterval(timing.hold)
                pending[id] = item
            }
        } else {
            holds[id] = nil
        }

        var refused: NotionError?
        if sendContent {
            do {
                try await c.client.replaceContent(pageID: entry.pageID, markdown: snap.markdown)
                entry.lastPushedHash = snap.hash
                entry.lastPushedLength = snap.length
                entry.lastPushedAt = now()
                entry.propertiesPending = true // 名前 and 更新日時 follow the content
                try record(entry, for: key, c)
            } catch NotionError.validation(let message) {
                refused = .validation(message: message) // 状態 and 色 still go out below
            }
        }
        let withContent = entry.propertiesPending == true
        var properties: [String: NotionPropertyValue] = [:]
        if withContent {
            properties[Property.title] = .title(snap.title)
            properties[Property.modified] = .date(meta.modified)
        }
        if withContent || entry.status != snap.status { properties[Property.status] = .select(snap.status) }
        if withContent || entry.color != snap.color { properties[Property.color] = .select(snap.color) }
        if !properties.isEmpty {
            try ensureCurrent(c)
            try await c.client.updateProperties(pageID: entry.pageID, properties: properties)
            entry.status = snap.status
            entry.color = snap.color
            entry.propertiesPending = nil
            try record(entry, for: key, c)
        }
        if let refused { throw refused }
    }

    /// The page is gone for the sync: 404, or 400 because it is in Notion's trash (which refuses edits).
    private func isGone(_ pageID: String, after error: NotionError, _ c: Connection) async throws -> Bool {
        switch error {
        case .notFound:
            return true
        case .validation:
            try ensureCurrent(c)
            do {
                return try await c.client.retrievePage(id: pageID).inTrash == true
            } catch NotionError.notFound {
                return true
            }
        default:
            return false
        }
    }

    /// After the page was deleted in Notion, moved to its trash or unshared. Nothing is forgotten
    /// before the data source answers: if it cannot be read either, the connection is the problem,
    /// and that error stops the sync with the mapping (and the guard's baseline) intact.
    private func replaceLostPage(_ id: UUID, meta: NoteMeta?, entry: NotionSyncState.Note, _ c: Connection) async throws {
        let key = id.uuidString
        try ensureCurrent(c)
        let found = try await c.client.queryPages(dataSourceID: c.dataSourceID, property: Property.noteID, equals: key).first
        try ensureCurrent(c)
        if let found {
            // Another page with this メモID: it gets the content and properties again, and a large
            // deletion is still held (the baseline is kept).
            try record(NotionSyncState.Note(pageID: found.id, lastPushedLength: entry.lastPushedLength), for: key, c)
            return try await push(id, c, isRetry: true)
        }
        guard let meta, !meta.isDeleted else {
            // A closed or forgotten note: nothing left to mark.
            var done = entry
            done.status = Status.deleted
            return try record(done, for: key, c)
        }
        state.notes[key] = nil
        saveState()
        try await push(id, c, isRetry: true) // created again
    }

    /// Saves a page's entry, unless the run belongs to a database the sync has left meanwhile.
    private func record(_ entry: NotionSyncState.Note, for key: String, _ c: Connection) throws {
        guard state.dataSourceID == c.dataSourceID else { throw CancellationError() }
        state.notes[key] = entry
        state.lastSyncAt = now()
        lastSyncAt = state.lastSyncAt
        saveState()
    }

    /// Empty after having content, or under 40 % of a push that was over 200 characters.
    private func isDestructive(_ length: Int, comparedTo last: Int?) -> Bool {
        guard let last, last > 0 else { return false }
        return length == 0 || (last > 200 && Double(length) < Double(last) * 0.4)
    }

    private func snapshot(of meta: NoteMeta) -> Snapshot {
        let body = text(of: meta.id)
        let markdown = NotionMarkdown.export(body, styler: styler)
        let hash = SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
        return Snapshot(markdown: markdown, hash: hash, length: markdown.count, title: NoteTitle.derive(from: body),
                        color: meta.color.title, status: meta.isDeleted ? Status.deleted : Status.active)
    }

    /// The note's latest text: the text from the change callback while it is newer than the file,
    /// otherwise the file (lossily decoded if it is not UTF-8). Never `NoteStore.body(of:)`, which
    /// records the file's date as seen: another app's edit would then be overwritten without the
    /// store's history copy.
    private func text(of id: UUID) -> String {
        let url = store.bodyURL(for: id)
        if let unsaved = unsavedText[id] {
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            guard let modified, modified >= unsaved.since else { return unsaved.text }
            unsavedText[id] = nil // saved since (or changed by another app)
        }
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func allProperties(_ snap: Snapshot, _ meta: NoteMeta) -> [String: NotionPropertyValue] {
        [Property.title: .title(snap.title),
         Property.noteID: .richText(meta.id.uuidString),
         Property.color: .select(snap.color),
         Property.status: .select(snap.status),
         Property.modified: .date(meta.modified)]
    }

    // MARK: Scheduling

    private func scheduleWake() {
        guard autoWake, !suspended, !flushTimedOut, state.enabled, client != nil, !stopped,
              let next = pending.values.map(due).min() else {
            wakeTask?.cancel()
            wakeTask = nil
            wakeAt = nil
            return
        }
        let at = max(next, retryAt ?? next)
        if wakeTask != nil, let wakeAt, wakeAt <= at { return } // an earlier wake re-checks anyway
        wakeTask?.cancel()
        wakeAt = at
        let delay = max(0, at.timeIntervalSince(now()))
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.wakeTask = nil
            self.wakeAt = nil
            await self.processDue()
        }
    }

    private func use(_ client: (any NotionAPI)?) {
        self.client = client
        session += 1
    }

    private func stopWork() {
        use(nil)
        pending = [:]
        holds = [:]
        runTask?.cancel()
        wakeTask?.cancel()
        wakeTask = nil
        wakeAt = nil
        updateCounts()
    }

    private func resetErrors() {
        stopped = false
        failures = 0
        retryAt = nil
        rejected = [:]
        lastError = nil
    }

    private func updateCounts() {
        let held = holds.keys.filter { pending[$0] != nil }.count
        if heldCount != held { heldCount = held }
        if pendingCount != pending.count - held { pendingCount = pending.count - held }
    }

    private func publish() {
        isConfigured = state.dataSourceID != nil
        isEnabled = state.enabled && isConfigured
        lastSyncAt = state.lastSyncAt
        workspaceName = state.workspaceName
        databaseURL = state.databaseURL
        parentPageURL = state.parentPageURL
        updateCounts()
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? NotionError { return error.japaneseDescription }
        if error is CancellationError { return NotionError.network(message: "").japaneseDescription }
        return error.localizedDescription
    }

    // MARK: State file

    /// Reads notion-sync.json once. A missing file is normal before the first connection; an
    /// unreadable one, or none although a token is saved, means the state was lost.
    private func loadState() {
        guard !isLoaded else { return }
        isLoaded = true
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            if tokenStore.containsToken() { lastError = Self.stateUnreadable }
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            state = try decoder.decode(NotionSyncState.self, from: Data(contentsOf: stateURL))
        } catch {
            // Keep the file for inspection; connecting again finds the database and pages.
            let copy = store.rootURL.appendingPathComponent("notion-sync-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: stateURL, to: copy)
            NSLog("fusen.md: notion-sync.json unreadable (%@); copied to %@", String(describing: error), copy.path)
            lastError = Self.stateUnreadable
        }
    }

    private func saveState() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(state).write(to: stateURL, options: .atomic)
        } catch {
            NSLog("fusen.md: could not write %@: %@", stateURL.path, String(describing: error))
        }
    }
}

extension NoteColor {
    /// The matching Notion select color.
    var notionColor: String {
        switch self {
        case .yellow: "yellow"
        case .blue: "blue"
        case .green: "green"
        case .pink: "pink"
        case .purple: "purple"
        case .gray: "gray"
        }
    }
}

/// Page IDs in Notion links: notion.so/<workspace>/<Title>-<32 hex>, app.notion.com/p/<32 hex>,
/// ?p=<32 hex> (a page opened as a peek), or a bare ID, with or without dashes.
enum NotionPageID {
    private static let trailingID = makeRegex(
        #"([0-9a-fA-F]{8})-?([0-9a-fA-F]{4})-?([0-9a-fA-F]{4})-?([0-9a-fA-F]{4})-?([0-9a-fA-F]{12})$"#)

    /// The dashed, lowercase page ID, or nil.
    static func parse(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []
        if let url = URLComponents(string: text), url.host != nil {
            if let peek = url.queryItems?.first(where: { $0.name == "p" })?.value { candidates.append(peek) }
            if let last = url.path.split(separator: "/").last { candidates.append(String(last)) }
        } else {
            candidates.append(text)
        }
        for candidate in candidates {
            let ns = candidate as NSString
            guard let m = trailingID.firstMatch(in: candidate, range: NSRange(location: 0, length: ns.length)) else { continue }
            return (1...5).map { ns.substring(with: m.range(at: $0)) }.joined(separator: "-").lowercased()
        }
        return nil
    }
}
