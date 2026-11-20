import AppKit
import SwiftUI

/// State of the "メモの履歴" window: notes (open and deleted) → versions → preview.
@MainActor
@Observable
final class HistoryModel {
    struct NoteItem: Identifiable, Hashable {
        let id: UUID
        let title: String
        let subtitle: String
        let color: NoteColor
        let isDeleted: Bool
    }

    struct VersionItem: Identifiable, Hashable {
        let id: String
        let title: String
        let subtitle: String
        let text: String
        let isCurrent: Bool
    }

    private var allOpenNotes: [NoteItem] = []
    private var allDeletedNotes: [NoteItem] = []
    private var allVersions: [VersionItem] = []
    /// Snapshot files never change once written, so their text is read once.
    @ObservationIgnored private var snapshotTexts: [URL: String] = [:]
    var selectedNoteID: UUID?
    var selectedVersionID: String?
    /// Filters notes and versions to those containing this phrase (call `updateSearch()` after changing it).
    var searchText = ""
    /// Notes with a version containing `searchText`; nil when not searching. Computed once per search,
    /// not on every view update.
    private(set) var matchingNoteIDs: Set<UUID>?
    /// Shown under the preview after a restore.
    var statusMessage: String?

    var openNotes: [NoteItem] { allOpenNotes.filter { matchingNoteIDs?.contains($0.id) ?? true } }
    var deletedNotes: [NoteItem] { allDeletedNotes.filter { matchingNoteIDs?.contains($0.id) ?? true } }
    var versions: [VersionItem] {
        guard let query else { return allVersions }
        return allVersions.filter { $0.isCurrent || $0.text.localizedStandardContains(query) }
    }

    private var query: String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Restores `text` (nil = keep the current text) into note `id`.
    @ObservationIgnored var onRestore: ((UUID, String?) -> Void)?
    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    init(store: NoteStore, history: HistoryStore) {
        self.store = store
        self.history = history
    }

    /// Only what is visible can be previewed, copied or restored: a search that hides the selected note
    /// or version also takes it out of reach of the buttons.
    var selectedNote: NoteItem? {
        (openNotes + deletedNotes).first { $0.id == selectedNoteID }
    }

    var selectedVersion: VersionItem? {
        guard selectedNote != nil else { return nil }
        return versions.first { $0.id == selectedVersionID }
    }

    var canRestore: Bool {
        guard let note = selectedNote, let version = selectedVersion else { return false }
        return note.isDeleted || !version.isCurrent
    }

    var restoreTitle: String {
        selectedNote?.isDeleted == true ? "このメモを復元" : "この版に戻す"
    }

    func reload() {
        allOpenNotes = store.openNotes
            .sorted { $0.modified > $1.modified }
            .map { item(for: $0, subtitle: "更新 " + dateFormatter.string(from: $0.modified)) }
        allDeletedNotes = store.deletedNotes.map {
            item(for: $0, subtitle: "削除 " + dateFormatter.string(from: $0.deletedAt ?? $0.modified))
        }
        if query != nil { updateSearch() }
        if (allOpenNotes + allDeletedNotes).first(where: { $0.id == selectedNoteID }) == nil {
            selectedNoteID = allOpenNotes.first?.id ?? allDeletedNotes.first?.id
        }
        loadVersions()
    }

    func updateSearch() {
        guard let query else {
            matchingNoteIDs = nil
            return
        }
        matchingNoteIDs = Set((allOpenNotes + allDeletedNotes).map(\.id).filter { id in
            store.body(of: id).localizedStandardContains(query)
                || history.snapshots(for: id).contains { text(of: $0).localizedStandardContains(query) }
        })
    }

    func loadVersions() {
        guard let id = selectedNoteID, let note = (allOpenNotes + allDeletedNotes).first(where: { $0.id == id }) else {
            allVersions = []
            selectedVersionID = nil
            return
        }
        let current = store.body(of: note.id)
        let snapshots = history.snapshots(for: note.id)
        let texts = snapshots.map(text(of:))
        var currentSubtitle = "\(current.count)文字"
        if let newest = texts.first {
            currentSubtitle += " · " + TextDelta.between(newest, current).summary
        }
        var items = [VersionItem(id: "current", title: note.isDeleted ? "閉じたときの内容" : "現在の内容",
                                 subtitle: currentSubtitle, text: current, isCurrent: true)]
        for (i, snapshot) in snapshots.enumerated() {
            var subtitle = "\(snapshot.reason.label) · \(texts[i].count)文字"
            if i + 1 < texts.count { // change since the next older version
                subtitle += " · " + TextDelta.between(texts[i + 1], texts[i]).summary
            }
            items.append(VersionItem(id: snapshot.url.lastPathComponent,
                                     title: dateFormatter.string(from: snapshot.date),
                                     subtitle: subtitle, text: texts[i], isCurrent: false))
        }
        allVersions = items
        if !items.contains(where: { $0.id == selectedVersionID }) {
            selectedVersionID = "current"
        }
    }

    func restoreSelected() {
        guard canRestore, let note = selectedNote, let version = selectedVersion else { return }
        onRestore?(note.id, version.isCurrent ? nil : version.text)
        statusMessage = note.isDeleted
            ? "メモを復元しました。"
            : "この版に戻しました。メモの画面で ⌘Z を押すと取り消せます。"
        selectedVersionID = "current"
        reload()
    }

    func copySelected() {
        guard let version = selectedVersion else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(version.text, forType: .string)
    }

    private func text(of snapshot: Snapshot) -> String {
        if let cached = snapshotTexts[snapshot.url] { return cached }
        let text = history.text(of: snapshot)
        snapshotTexts[snapshot.url] = text
        return text
    }

    private func item(for meta: NoteMeta, subtitle: String) -> NoteItem {
        NoteItem(id: meta.id, title: NoteTitle.derive(from: store.body(of: meta.id)), subtitle: subtitle,
                 color: meta.color, isDeleted: meta.isDeleted)
    }
}

struct HistoryView: View {
    @Bindable var model: HistoryModel
    let styler: MarkdownStyler
    let darkStyler: MarkdownStyler
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedNoteID) {
                Section("メモ") {
                    ForEach(model.openNotes) { NoteRow(item: $0) }
                }
                if !model.deletedNotes.isEmpty {
                    Section("削除したメモ") {
                        ForEach(model.deletedNotes) { NoteRow(item: $0) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            List(model.versions, selection: $model.selectedVersionID) { version in
                VStack(alignment: .leading, spacing: 2) {
                    Text(version.title).fontWeight(version.isCurrent ? .semibold : .regular)
                    Text(version.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        } detail: {
            VStack(spacing: 0) {
                // On the note's paper, light or dark as the window is.
                let shown = colorScheme == .dark ? darkStyler : styler
                MarkdownPreview(text: model.selectedVersion?.text ?? "",
                                background: model.selectedNote.map { shown.theme.paper($0.color) } ?? .textBackgroundColor,
                                styler: shown)
                Divider()
                HStack {
                    Button("テキストをコピー") { model.copySelected() }
                        .disabled(model.selectedVersion == nil)
                    if let message = model.statusMessage {
                        Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button(model.restoreTitle) { model.restoreSelected() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canRestore)
                }
                .padding(10)
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "過去の版から探す")
        .onChange(of: model.searchText) { model.updateSearch() }
        .onChange(of: model.selectedNoteID) {
            model.selectedVersionID = "current"
            model.statusMessage = nil
            model.loadVersions()
        }
    }
}

private struct NoteRow: View {
    let item: HistoryModel.NoteItem
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: colorScheme == .dark ? item.color.darkBackground : item.color.background))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.15)))
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Read-only text on the note's paper color, shown like a note that is not being edited (Markdown
/// concealed). Selecting and copying still copies the Markdown.
private struct MarkdownPreview: NSViewRepresentable {
    let text: String
    let background: NSColor
    let styler: MarkdownStyler

    final class Coordinator {
        var storage: NSTextStorage? // the text storage owns the TextKit 1 stack
        var isDark = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = ConcealingLayoutManager(theme: styler.theme)
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        context.coordinator.storage = storage

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)

        let scrollView = NSScrollView()
        NoteWindowController.configureScroller(of: scrollView)
        scrollView.drawsBackground = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        scrollView.backgroundColor = background
        guard let textView = scrollView.documentView as? NSTextView, let storage = textView.textStorage else { return }
        if styler.theme.isDark != context.coordinator.isDark, let layout = textView.layoutManager as? ConcealingLayoutManager {
            // Light or dark changed: the same text in the other theme.
            context.coordinator.isDark = styler.theme.isDark
            layout.theme = styler.theme
            styler.restyle(storage)
        }
        guard textView.string != text else { return }
        textView.string = text
        styler.restyle(storage)
        textView.scrollToBeginningOfDocument(nil)
    }
}

@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    let model: HistoryModel

    init(model: HistoryModel, styler: MarkdownStyler, darkStyler: MarkdownStyler) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 540),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "メモの履歴"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: HistoryView(model: model, styler: styler, darkStyler: darkStyler))
        window.setContentSize(NSSize(width: 900, height: 540))
        window.center()
        window.setFrameAutosaveName("HistoryWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(selecting noteID: UUID?) {
        if let noteID {
            model.selectedNoteID = noteID
            model.searchText = "" // an old search must not hide the note that was asked for
            model.updateSearch()
        }
        model.selectedVersionID = "current"
        model.statusMessage = nil
        // Becoming key reloads (windowDidBecomeKey); reload here only if the window already is key.
        if window?.isKeyWindow == true { model.reload() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.reload()
    }
}
