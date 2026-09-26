import AppKit
import ServiceManagement

public enum FusenApp {
    @MainActor
    public static func run() {
        let app = NSApplication.shared
        // Before anything creates the notes folder: take over the notes of the app's former name.
        if NoteStore.migrateLegacyRoot() == .oldAppRunning {
            app.setActivationPolicy(.regular)
            app.activate()
            let alert = NSAlert()
            alert.messageText = "古い「Markdown Stickies」が起動しています"
            alert.informativeText = "メモを fusen.md に引き継ぐため、Markdown Stickies を終了してから fusen.md を開き直してください。"
            alert.runModal()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        // `kill` / `killall` quit through the normal path, so pending text is saved.
        signal(SIGTERM, SIG_IGN)
        let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSource.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        terminationSource.resume()
        withExtendedLifetime((delegate, terminationSource)) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let store: NoteStore
    private let history: HistoryStore
    private let styler = MarkdownStyler()
    private var controllers: [UUID: NoteWindowController] = [:]
    private var historyWindow: HistoryWindowController?
    private var thinningTimer: Timer?
    private var isTerminating = false
    private var lockDescriptor: Int32 = -1
    private var didReportWriteError = false
    private var notionSync: NotionSync?
    private var settingsWindow: SettingsWindowController?

    init(rootURL: URL = NoteStore.defaultRootURL) {
        store = NoteStore(rootURL: rootURL)
        history = HistoryStore(rootURL: store.historyURL)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard acquireLock() else {
            // Another copy owns the notes folder; two writers would overwrite each other's saves.
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .filter { $0 != .current }
            if let other = others.first {
                other.activate()
            } else {
                let alert = NSAlert()
                alert.messageText = "fusen.md はすでに起動しています"
                alert.informativeText = "同じメモのフォルダを使う別のコピーが動いているため、このコピーは終了します。"
                alert.runModal()
            }
            isTerminating = true
            NSApp.terminate(nil)
            return
        }
        NSApp.mainMenu = MainMenu.build(appDelegate: self)
        store.onWriteError = { [weak self] url, error in self?.reportWriteError(url: url, error: error) }
        store.onWriteRecovered = { [weak self] in self?.didReportWriteError = false }
        store.onExternalChange = { [weak self] id, text in
            self?.history.checkpoint(id, text: text, reason: .external)
        }
        store.load()
        history.thin()
        let sync = makeNotionSync()
        let notes = store.openNotes
        if store.metas.isEmpty {
            createNote(body: Self.welcomeText)
        } else if notes.isEmpty {
            createNote(body: "")
        }
        for meta in notes {
            let body = store.body(of: meta.id)
            history.checkpoint(meta.id, text: body, reason: .launch)
            open(meta, body: body)
        }
        thinningTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.history.thin() }
        }
        NSApp.activate()
        // Once the stickies are drawn: after a rebuild, reading the token can bring up a Keychain
        // prompt, which blocks the main thread until it is answered.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            sync.start()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard lockDescriptor >= 0 else { return .terminateNow } // never loaded: nothing to save
        controllers.values.forEach { $0.commitPendingInput() }
        store.flush()
        // Never quit silently while some text exists only in memory.
        retry: while store.hasUnsavedChanges {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "一部のメモを保存できていません"
            alert.informativeText = "このまま終了すると、保存できていない内容は失われます。ディスクの空き容量などを確認してから、もう一度試してください。"
            alert.addButton(withTitle: "もう一度試す")
            alert.addButton(withTitle: "キャンセル")
            alert.addButton(withTitle: "保存せずに終了")
            switch alert.runModal() {
            case .alertFirstButtonReturn: store.flush()
            case .alertSecondButtonReturn: return .terminateCancel
            default: break retry
            }
        }
        isTerminating = true
        return terminateAfterNotionFlush()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if lockDescriptor >= 0 { store.flush() }
    }

    /// Exclusive lock on <root>/.lock for the life of the process.
    private func acquireLock() -> Bool {
        let path = store.rootURL.appendingPathComponent(".lock").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true } // cannot even create the lock file: do not block the user
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            return false
        }
        lockDescriptor = fd
        return true
    }

    private func reportWriteError(url: URL, error: Error) {
        guard !didReportWriteError else { return }
        didReportWriteError = true
        // Not from inside the save itself: a modal alert there would re-enter saving.
        Task { @MainActor in
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "メモを保存できませんでした"
            alert.informativeText = """
            \(url.path)
            \(error.localizedDescription)

            ディスクの空き容量などを確認してください。入力した内容はアプリを開いている間は保持され、次の保存で再試行します。
            """
            alert.runModal()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if controllers.isEmpty { newNote(nil) }
        return true
    }

    // MARK: Notes

    @objc func newNote(_ sender: Any?) { createNote(body: "") }

    private func createNote(body: String) {
        let size = CGSize(width: 280, height: 240)
        var origin = CGPoint(x: 120, y: 400)
        if let key = NSApp.keyWindow, key.windowController is NoteWindowController {
            origin = CGPoint(x: key.frame.minX + 24, y: key.frame.maxY - 24 - size.height)
        } else if let visible = NSScreen.main?.visibleFrame {
            origin = CGPoint(x: visible.maxX - size.width - 40, y: visible.maxY - size.height - 40)
        }
        let meta = NoteMeta(frame: CGRect(origin: origin, size: size))
        store.add(meta, body: body)
        let controller = open(meta, body: body)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.textView)
        reloadHistoryIfVisible()
    }

    // MARK: Markdown display

    private static let showsAllMarkdownKey = "showsAllMarkdown"

    /// Off (default): Markdown syntax is hidden except on the line being edited, like Notion.
    private var showsAllMarkdown: Bool {
        get { UserDefaults.standard.bool(forKey: Self.showsAllMarkdownKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.showsAllMarkdownKey) }
    }

    @objc func toggleShowsAllMarkdown(_ sender: Any?) {
        showsAllMarkdown.toggle()
        controllers.values.forEach { $0.setConcealsMarkdown(!showsAllMarkdown) }
    }

    @discardableResult
    private func open(_ meta: NoteMeta, body: String) -> NoteWindowController {
        let controller = NoteWindowController(meta: meta, body: body, store: store, history: history, styler: styler,
                                              concealsMarkdown: !showsAllMarkdown)
        controller.onClose = { [weak self] closed in self?.noteDidClose(closed) }
        controller.onShowHistory = { [weak self] note in self?.showHistory(selecting: note.meta.id) }
        controller.onImportFromNotion = { [weak self] note in self?.importFromNotion(note) }
        controller.canImportFromNotion = { [weak self] note in self?.notionSync?.canImport(note.meta.id) ?? false }
        controllers[meta.id] = controller
        controller.showWindow(nil)
        return controller
    }

    private func noteDidClose(_ controller: NoteWindowController) {
        guard !isTerminating else { return }
        controller.commitPendingInput()
        let id = controller.meta.id
        let text = controller.currentText // what is on screen, not a re-read of the file
        controllers[id] = nil
        if text.allSatisfy(\.isWhitespace), !history.hasSnapshots(id) {
            store.remove(id) // never had any content: nothing to keep
        } else {
            history.checkpoint(id, text: text, reason: .deleted)
            store.markDeleted(id)
        }
        reloadHistoryIfVisible()
    }

    @objc func reopenLastClosedNote(_ sender: Any?) {
        guard let last = store.deletedNotes.first else { return }
        restoreFromHistory(last.id, text: nil)
        reloadHistoryIfVisible()
    }

    // MARK: History

    /// The history window reloads itself when it becomes key; only refresh it while it is on screen.
    private func reloadHistoryIfVisible() {
        if historyWindow?.window?.isVisible == true { historyWindow?.model.reload() }
    }

    @objc func showHistory(_ sender: Any?) {
        showHistory(selecting: nil)
    }

    private func showHistory(selecting noteID: UUID?) {
        if historyWindow == nil {
            let model = HistoryModel(store: store, history: history)
            model.onRestore = { [weak self] id, text in self?.restoreFromHistory(id, text: text) }
            historyWindow = HistoryWindowController(model: model, styler: styler)
        }
        historyWindow?.show(selecting: noteID)
    }

    /// Restores `text` into note `id` (nil = keep its current text). An open note gets an undoable
    /// replacement in its existing window; a deleted note is reopened with the same id, so its
    /// history stays in one place and there is never a second window for one note.
    private func restoreFromHistory(_ id: UUID, text: String?) {
        if let controller = controllers[id] {
            if let text {
                controller.restore(text)
            } else {
                controller.window?.makeKeyAndOrderFront(nil)
            }
            return
        }
        guard let meta = store.meta(id), meta.isDeleted else { return }
        if text != nil {
            history.checkpoint(id, text: store.body(of: id), reason: .restore)
        }
        store.restore(id, body: text)
        guard let restored = store.meta(id) else { return }
        let controller = open(restored, body: store.body(of: id))
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.textView)
    }

    @objc func revealNotesFolder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([store.rootURL])
    }

    // MARK: Notion sync (one-way mirror; see NotionSync)

    /// After the lock is acquired and the notes are loaded. Changes are noted from now on; nothing is
    /// read from the Keychain or sent until `start()`, which also sends what changed while the app
    /// was closed.
    private func makeNotionSync() -> NotionSync {
        let sync = NotionSync(store: store, styler: styler)
        store.onNoteChanged = { [weak sync] id, text in sync?.noteChanged(id, text: text) }
        store.onNoteDeleted = { [weak sync] id in sync?.noteDeleted(id) }
        store.onNoteRestored = { [weak sync] id in sync?.noteRestored(id) }
        notionSync = sync
        return sync
    }

    @objc func showSettings(_ sender: Any?) {
        guard let notionSync else { return }
        if settingsWindow == nil { settingsWindow = SettingsWindowController(sync: notionSync) }
        settingsWindow?.show()
    }

    @objc func syncNotionNow(_ sender: Any?) {
        guard let notionSync else { return }
        Task { await notionSync.syncNow() }
    }

    /// 「Notion の内容を取り込む」: replaces the sticky with its page in Notion, after asking. The current
    /// text goes to the history first, and ⌘Z undoes the replacement.
    private func importFromNotion(_ controller: NoteWindowController) {
        guard let notionSync else { return }
        let id = controller.meta.id
        Task { @MainActor in
            let result: NotionSync.Import
            do throws(NotionSync.SyncError) {
                result = try await notionSync.fetchImport(id)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Notion の内容を取り込めませんでした"
                alert.informativeText = error.message
                alert.runModal()
                return
            }
            // The note may have been closed while Notion was being read.
            guard controllers[id] === controller else { return }
            controller.commitPendingInput()
            guard result.text != controller.currentText else {
                let alert = NSAlert()
                alert.messageText = "Notion の内容はこの付箋と同じです"
                alert.runModal()
                return
            }
            let alert = NSAlert()
            alert.messageText = "Notion の内容でこの付箋を置き換えますか？"
            var info = "今の内容は「メモの履歴」に保存されます。置き換えたあとに ⌘Z を押しても元に戻せます。"
            if !result.notionOnly.isEmpty {
                info += "\n\nNotion にしかない要素（\(result.notionOnly.joined(separator: "、"))）は、付箋ではタグや記号の文字のまま表示されます。次に Notion へ送るときも文字として送られるため、Notion 側ではその要素が普通の文字になります。"
            }
            alert.informativeText = info
            alert.addButton(withTitle: "取り込む")
            alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn, controllers[id] === controller else { return }
            controller.replaceText(with: result.text, reason: .notionimport, actionName: "Notionから取り込む")
        }
    }

    /// Quitting waits (at most 5 s) for changes that are ready to be sent to Notion.
    private func terminateAfterNotionFlush() -> NSApplication.TerminateReply {
        guard let notionSync, notionSync.hasPendingWork else { return .terminateNow }
        Task {
            await notionSync.flush(timeout: 5)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Launch at login

    @objc func toggleLaunchAtLogin(_ sender: Any?) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleLaunchAtLogin(_:)):
            item.state = SMAppService.mainApp.status == .enabled ? .on : .off
            // Only an .app bundle can register itself (not `swift run`).
            return Bundle.main.bundleURL.pathExtension == "app"
        case #selector(reopenLastClosedNote(_:)):
            return !store.deletedNotes.isEmpty
        case #selector(syncNotionNow(_:)):
            return notionSync?.isEnabled == true
        case #selector(toggleShowsAllMarkdown(_:)):
            item.state = showsAllMarkdown ? .on : .off
            return true
        default:
            return true
        }
    }

    static let welcomeText = """
    # fusen.md
    **太字**、*斜体*、~~取り消し線~~、`inline code` がその場で装飾されます。

    ## やること
    - [ ] チェックボックスはクリックで切り替え
    - [x] 完了したタスクは取り消し線
    - 箇条書きは Return で自動継続（空の項目で Return すると終了）

    > 消してしまった文章や閉じたメモは「ファイル > メモの履歴…」から戻せます。
    [Apple](https://www.apple.com) は ⌘クリックで開きます。
    """
}
