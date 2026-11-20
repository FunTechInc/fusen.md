import AppKit

final class NotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class NoteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {
    private(set) var meta: NoteMeta
    let textView: MarkdownTextView
    /// TextKit 1 stack: the text storage owns the layout manager, which owns the container.
    private let textStorage = NSTextStorage()
    private let layoutManager: ConcealingLayoutManager
    private let store: NoteStore
    private let history: HistoryStore
    private let styler: MarkdownStyler
    var onClose: (@MainActor (NoteWindowController) -> Void)?
    var onShowHistory: (@MainActor (NoteWindowController) -> Void)?
    var onImportFromNotion: (@MainActor (NoteWindowController) -> Void)?
    /// Whether 「Notion の内容を取り込む」 is available for this note.
    var canImportFromNotion: (@MainActor (NoteWindowController) -> Bool)?
    /// 強調表示: the two buttons at the right of the title bar, one per `NoteFocus`.
    private var focusButtons: [NSButton] = []
    private let focusAccessory = NSTitlebarAccessoryViewController()

    init(meta: NoteMeta, body: String, store: NoteStore, history: HistoryStore, styler: MarkdownStyler,
         concealsMarkdown: Bool) {
        self.meta = meta
        self.store = store
        self.history = history
        self.styler = styler

        let panel = NotePanel(contentRect: NSRect(origin: .zero, size: meta.frame.size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
                              backing: .buffered, defer: false)
        layoutManager = ConcealingLayoutManager(theme: styler.theme)
        layoutManager.concealsMarkdown = concealsMarkdown
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: meta.frame.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        textView = MarkdownTextView(frame: .zero, textContainer: container)
        textView.concealsMarkdown = concealsMarkdown
        super.init(window: panel)

        configure(panel)
        configureTextView(in: panel)
        configureFocusButtons(in: panel)
        panel.setFrame(Self.onScreen(meta.frame), display: false)
        textView.focus = meta.focus
        applyWindowState()

        textView.typingAttributes = styler.baseAttributes
        textView.string = body
        restyle()
        updateFocusButtons()
        panel.title = NoteTitle.derive(from: body)
        panel.delegate = self
        textView.delegate = self
    }

    /// Shows all Markdown as typed (false), or none of it, also while editing (true, as in Notion).
    func setConcealsMarkdown(_ conceals: Bool) {
        layoutManager.concealsMarkdown = conceals
        textView.concealsMarkdown = conceals
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func configure(_ panel: NSPanel) {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.hidesOnDeactivate = false        // panels hide on deactivate by default; notes must not
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 160, height: 90)
        panel.appearance = NSAppearance(named: .aqua) // pastel paper in dark mode too, like Stickies
    }

    private func configureTextView(in panel: NSPanel) {
        let scrollView = NSScrollView(frame: panel.contentLayoutRect)
        Self.configureScroller(of: scrollView)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]

        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.drawsBackground = false
        textView.insertionPointColor = styler.theme.textColor

        // Markdown is plain text: plain paste, no smart substitutions that corrupt syntax.
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        scrollView.documentView = textView
        panel.contentView = scrollView
    }

    /// Stickies' scroll bar: the small size (its note nib sets the vertical scroller to .small), which
    /// is also thinner when 「スクロールバーを表示: 常に」 shows the classic one with a track.
    static func configureScroller(of scrollView: NSScrollView) {
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.controlSize = .small
    }

    private func applyWindowState() {
        guard let panel = window as? NSPanel else { return }
        panel.isFloatingPanel = meta.isFloating
        panel.level = meta.isFloating ? .floating : .normal
        panel.collectionBehavior = meta.isOnAllSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenAuxiliary]
        panel.alphaValue = meta.isTranslucent ? 0.72 : 1.0
        panel.backgroundColor = meta.focus == nil ? meta.color.background : styler.theme.focusPaper(meta.color.background)
    }

    // MARK: 強調表示

    private func configureFocusButtons(in panel: NSPanel) {
        focusButtons = NoteFocus.allCases.enumerated().map { index, focus in
            let image = TaskSignalIcon.image(focus.state, theme: styler.theme, size: Self.focusButtonSize)
            let button = NSButton(image: image, target: self, action: #selector(toggleFocus(_:)))
            button.tag = index
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.toolTip = focus.title
            button.setAccessibilityLabel(focus.title)
            return button
        }
        let stack = NSStackView(views: focusButtons)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 10)
        stack.frame.size = stack.fittingSize
        focusAccessory.view = stack
        focusAccessory.layoutAttribute = .trailing
        panel.addTitlebarAccessoryViewController(focusAccessory)
    }

    /// The buttons show which emphasis is on (the other one fades), and only on a note that has signals.
    private func updateFocusButtons() {
        let theme = styler.theme
        for (focus, button) in zip(NoteFocus.allCases, focusButtons) {
            let isOther = meta.focus != nil && meta.focus != focus
            button.image = TaskSignalIcon.image(focus.state, theme: theme, size: Self.focusButtonSize,
                                                alpha: isOther ? theme.focusButtonFade : 1)
        }
        let hasSignals = MarkdownStyler.taskStates(in: textStorage).contains(where: \.isSignal)
        focusAccessory.isHidden = !hasSignals && meta.focus == nil
    }

    static let focusButtonSize: CGFloat = 12

    /// A button or a menu item (tag: the index in `NoteFocus.allCases`): turns that emphasis on, or off
    /// if it is on.
    @objc func toggleFocus(_ sender: Any?) {
        let tag = (sender as? NSControl)?.tag ?? (sender as? NSMenuItem)?.tag ?? -1
        guard NoteFocus.allCases.indices.contains(tag) else { return }
        setFocus(meta.focus == NoteFocus.allCases[tag] ? nil : NoteFocus.allCases[tag])
    }

    func setFocus(_ focus: NoteFocus?) {
        guard focus != meta.focus else { return }
        meta.focus = focus
        textView.focus = focus
        applyWindowState()
        Self.restyle(textView, with: styler)
        updateFocusButtons()
        store.updateMeta(meta)
    }

    private static func onScreen(_ frame: CGRect) -> CGRect {
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { return frame }
        guard let visible = NSScreen.main?.visibleFrame else { return frame }
        return CGRect(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2,
                      width: frame.width, height: frame.height)
    }

    private func restyle() {
        guard let storage = textView.textStorage else { return }
        styler.restyle(storage, focus: meta.focus, width: textView.textContainer?.size.width)
    }

    /// Replaces the text with an older version; ⌘Z undoes it and the replaced text is kept in history.
    func restore(_ text: String) {
        replaceText(with: text, reason: .restore, actionName: "履歴から復元")
    }

    /// Replaces the whole text as one undoable step, after saving the current text to the history.
    func replaceText(with text: String, reason: SnapshotReason, actionName: String) {
        commitPendingInput()
        history.checkpoint(meta.id, text: textView.string, reason: reason)
        textView.replaceAllText(with: text, actionName: actionName)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    /// Accepts text the IME is still composing, as typed, and saves it. Used before close, quit and
    /// restore, which would otherwise drop it (textDidChange does not save while text is marked).
    func commitPendingInput() {
        guard textView.hasMarkedText() else { return }
        textView.unmarkText()
        textView.inputContext?.discardMarkedText()
        restyle()
        store.updateBody(textView.string, for: meta.id)
    }

    /// The current text, including uncommitted IME input.
    var currentText: String { textView.string }

    // MARK: NSTextViewDelegate

    // The multi-range variant: when it is implemented, AppKit calls it instead of the single-range one,
    // and it also sees Replace All and multi-selection edits.
    func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue],
                  replacementStrings: [String]?) -> Bool {
        history.textView(textView, willReplace: affectedRanges.map(\.rangeValue), with: replacementStrings, note: meta.id)
        return true
    }

    func textViewWritingToolsWillBegin(_ textView: NSTextView) {
        history.checkpoint(meta.id, text: textView.string, reason: .writingtools)
    }

    /// Keeps the caret out of concealed syntax (see ConcealedEditing). Not while the IME composes.
    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRanges oldSelectedCharRanges: [NSValue],
                  toCharacterRanges newSelectedCharRanges: [NSValue]) -> [NSValue] {
        guard layoutManager.concealsMarkdown, !textView.hasMarkedText(), let storage = textView.textStorage else {
            return newSelectedCharRanges
        }
        return Self.adjusted(newSelectedCharRanges, from: oldSelectedCharRanges, in: storage)
    }

    static func adjusted(_ new: [NSValue], from old: [NSValue], in storage: NSTextStorage) -> [NSValue] {
        let oldCaret = old.first?.rangeValue.location ?? 0
        return new.map { value in
            let range = value.rangeValue
            guard range.length == 0 else { return NSValue(range: ConcealedEditing.adjustSelection(range, in: storage)) }
            return NSValue(range: NSRange(location: ConcealedEditing.adjustCaret(range.location, from: oldCaret, in: storage),
                                          length: 0))
        }
    }

    /// Restyles after an edit and keeps the caret out of syntax the edit made: "-" typed before " 項目"
    /// turns the line into a list item whose hidden marker would hold the caret.
    static func restyle(_ textView: MarkdownTextView, with styler: MarkdownStyler) {
        guard let storage = textView.textStorage else { return }
        styler.restyle(storage, focus: textView.focus, width: textView.textContainer?.size.width)
        textView.updateInsertionPointColor()
        guard textView.concealsMarkdown else { return }
        let ranges = textView.selectedRanges
        let adjusted = adjusted(ranges, from: ranges, in: storage)
        if adjusted != ranges { textView.selectedRanges = adjusted }
    }

    /// New text starts from the plain body style (keeping the font, so composing inside a heading shows
    /// heading-sized text) and never inherits Markdown markers or links from the character before it.
    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
                  toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
        var attributes = styler.baseAttributes
        if let font = newTypingAttributes[.font] as? NSFont, !font.isFixedPitch { attributes[.font] = font }
        // On the darkened paper of 強調表示, what is being typed (and composed) shows in the caret's color.
        if meta.focus != nil { attributes[.foregroundColor] = textView.insertionPointColor }
        // In a card the text view lets composed text take over the line's place in the card (see
        // MarkdownTextView.prepareCompositionAttributes): that is kept.
        for (key, value) in (textView as? MarkdownTextView)?.cardTypingAttributes() ?? [:] { attributes[key] = value }
        return attributes
    }

    func textDidChange(_ notification: Notification) {
        // Styling runs here — after processEditing, not inside an NSTextStorage delegate —
        // so the attribute pass cannot widen the edited range and move the insertion point.
        // While the IME is composing (marked text) do nothing: restyling would change the
        // font/size of the composing run mid-conversion (e.g. once "# " turns the line into a
        // heading), which reflows the line and moves the candidate window, and the uncommitted
        // reading is not worth saving. Committing sends another textDidChange, which styles and saves.
        guard !textView.hasMarkedText() else { return }
        Self.restyle(textView, with: styler)
        updateFocusButtons()
        store.updateBody(textView.string, for: meta.id)
        window?.title = NoteTitle.derive(from: textView.string)
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) { persistFrame() }
    func windowDidResize(_ notification: Notification) {
        persistFrame()
        // Cards stand side by side only in a note wide enough for them (see MarkdownStyler.restyle).
        if !textView.hasMarkedText(), let storage = textView.textStorage, storage.length > 0 {
            var hasRows = false
            storage.enumerateAttribute(.mdCardRow, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
                if value != nil { hasRows = true; stop.pointee = true }
            }
            if hasRows { Self.restyle(textView, with: styler) }
        }
    }
    func windowWillClose(_ notification: Notification) { onClose?(self) }

    private func persistFrame() {
        guard let frame = window?.frame, frame != meta.frame else { return }
        meta.frame = frame
        store.updateMeta(meta)
    }

    // MARK: Actions (reached through the responder chain: key window -> its delegate)

    @objc func toggleFloating(_ sender: Any?) {
        meta.isFloating.toggle()
        applyWindowState()
        store.updateMeta(meta)
    }

    @objc func toggleTranslucent(_ sender: Any?) {
        meta.isTranslucent.toggle()
        applyWindowState()
        store.updateMeta(meta)
    }

    @objc func toggleOnAllSpaces(_ sender: Any?) {
        meta.isOnAllSpaces.toggle()
        applyWindowState()
        store.updateMeta(meta)
    }

    @objc func setNoteColor(_ sender: NSMenuItem) {
        guard NoteColor.allCases.indices.contains(sender.tag) else { return }
        meta.color = NoteColor.allCases[sender.tag]
        applyWindowState()
        store.updateMeta(meta)
    }

    @objc func showNoteHistory(_ sender: Any?) {
        onShowHistory?(self)
    }

    @objc func importFromNotion(_ sender: Any?) {
        onImportFromNotion?(self)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleFloating(_:)):
            item.state = meta.isFloating ? .on : .off
        case #selector(toggleTranslucent(_:)):
            item.state = meta.isTranslucent ? .on : .off
        case #selector(toggleOnAllSpaces(_:)):
            item.state = meta.isOnAllSpaces ? .on : .off
        case #selector(setNoteColor(_:)):
            item.state = NoteColor.allCases.firstIndex(of: meta.color) == item.tag ? .on : .off
        case #selector(toggleFocus(_:)):
            item.state = meta.focus.flatMap(NoteFocus.allCases.firstIndex(of:)) == item.tag ? .on : .off
        case #selector(importFromNotion(_:)):
            return canImportFromNotion?(self) ?? false
        default:
            break
        }
        return true
    }
}
