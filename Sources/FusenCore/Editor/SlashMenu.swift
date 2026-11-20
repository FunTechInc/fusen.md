import AppKit

/// The commands of the "/" menu (Notion's slash commands): typed at the start of a line's text or after
/// a space, "/" lists them, and what is typed after it narrows the list. As in Notion, every kind of
/// block a note can hold is here, in Notion's order, with the app's own blocks (the signals next to the
/// checkbox whose states they are, the card where Notion has its callout).
enum SlashCommand: String, CaseIterable, Sendable {
    case text, h1, h2, h3, h4, bullet, ordered, todo, waiting, doing, card, quote, divider, code

    var title: String {
        switch self {
        case .text: "テキスト"
        case .h1: "見出し 1"
        case .h2: "見出し 2"
        case .h3: "見出し 3"
        case .h4: "見出し 4"
        case .bullet: "箇条書き"
        case .ordered: "番号付きリスト"
        case .todo: "チェックボックス"
        case .waiting: "待機のタスク"
        case .doing: "進行中のタスク"
        case .card: "カード"
        case .quote: "引用"
        case .divider: "区切り線"
        case .code: "コードブロック"
        }
    }

    /// What typing makes the same block without the menu, shown at the end of the row (as Notion shows
    /// its shortcuts): the menu is also where the Markdown can be looked up.
    var shortcut: String? {
        switch self {
        case .text, .card: nil
        case .h1: "#"
        case .h2: "##"
        case .h3: "###"
        case .h4: "####"
        case .bullet: "-"
        case .ordered: "1."
        case .todo: "[]"
        case .waiting: "[>]"
        case .doing: "[/]"
        case .quote: ">"
        case .divider: "---"
        case .code: "```"
        }
    }

    /// What can be typed after "/" to mean the command, besides its title and its shortcut: in English
    /// as in Notion ("/ca" is the Figma's own example), and as its reading. Without spaces, as a space
    /// closes the menu.
    private var keywords: [String] {
        switch self {
        case .text: ["text", "plain", "paragraph", "てきすと", "ほんぶん", "本文"]
        case .h1: ["h1", "heading1", "見出し1", "みだし1", "みだし", "だいみだし", "大見出し"]
        case .h2: ["h2", "heading2", "見出し2", "みだし2", "みだし", "ちゅうみだし", "中見出し"]
        case .h3: ["h3", "heading3", "見出し3", "みだし3", "みだし", "こみだし", "小見出し"]
        case .h4: ["h4", "heading4", "見出し4", "みだし4", "みだし"]
        case .bullet: ["bullet", "bulleted", "list", "ul", "かじょうがき", "りすと", "リスト"]
        case .ordered: ["number", "numbered", "ordered", "list", "ol", "ばんごう", "番号", "りすと", "リスト"]
        case .todo: ["todo", "to-do", "check", "task", "list", "ちぇっく", "チェック", "やること", "たすく", "タスク"]
        case .waiting: ["waiting", "next", "star", "priority", "task", "たいき", "待機", "つぎ", "次", "ほし", "星", "ゆうせん", "優先", "たすく", "タスク"]
        case .doing: ["doing", "progress", "now", "task", "しんこう", "進行", "たすく", "タスク"]
        case .card: ["card", "callout", "かーど"]
        case .quote: ["quote", "blockquote", "いんよう"]
        case .divider: ["divider", "line", "hr", "くぎり", "区切", "せん", "線"]
        case .code: ["code", "codeblock", "こーど", "コード"]
        }
    }

    /// The to-do state the command makes, if it makes a to-do.
    var taskState: TaskState? {
        switch self {
        case .todo: .todo
        case .waiting: .waiting
        case .doing: .doing
        default: nil
        }
    }

    var headingLevel: Int? {
        switch self {
        case .h1: 1
        case .h2: 2
        case .h3: 3
        case .h4: 4
        default: nil
        }
    }

    /// The commands that `query` (what is typed after "/") can mean: all of them for nothing typed yet.
    static func matching(_ query: String) -> [SlashCommand] {
        let query = query.lowercased()
        guard !query.isEmpty else { return allCases }
        return allCases.filter { command in
            command.title.lowercased().hasPrefix(query) || command.shortcut?.hasPrefix(query) == true
                || command.keywords.contains { $0.hasPrefix(query) }
        }
    }

    /// "/", and "；" for a Japanese keyboard, where "/" types "・" (Notion takes it too).
    static func isTrigger(_ character: unichar) -> Bool { character == 0x2F || character == 0xFF1B }

    /// The row's icon. On the highlighted row everything is white, as its text is — the signals too: the
    /// blue arc of a to-do in progress would be lost on the highlight (the system's accent color, blue
    /// by default).
    @MainActor
    func icon(theme: MarkdownTheme, isSelected: Bool) -> NSImage? {
        if let taskState {
            var theme = theme
            if isSelected {
                theme.doingColor = .white
                theme.waitingColor = .white
            }
            return TaskSignalIcon.image(taskState, theme: theme, ink: isSelected ? .white : .labelColor)
        }
        switch self {
        case .text: return Self.lettering("Aa")
        case .h1, .h2, .h3, .h4: return Self.lettering("H\(headingLevel ?? 1)")
        case .bullet: return Self.symbol("list.bullet")
        case .ordered: return Self.symbol("list.number")
        case .card: return Self.symbol("rectangle.inset.topleft.filled", or: "rectangle")
        case .quote: return Self.symbol("text.quote", or: "quote.opening")
        case .divider: return Self.symbol("minus")
        case .code: return Self.symbol("chevron.left.forwardslash.chevron.right", or: "curlybraces")
        case .todo, .waiting, .doing: return nil
        }
    }

    @MainActor
    private static func symbol(_ name: String, or fallback: String? = nil) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? fallback.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }

    /// Notion's icons for text and headings are letters ("Aa", "H1"): a template image, tinted as the
    /// symbols are.
    @MainActor
    private static func lettering(_ letters: String) -> NSImage {
        let size = NSSize(width: 18, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let string = NSAttributedString(string: letters, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.black, .kern: -0.3,
            ])
            let bounds = string.size()
            string.draw(at: NSPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2))
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The "/" menu as the text view keeps it while it is open.
struct SlashMenu: Equatable {
    /// Where the "/" is.
    var trigger: Int
    var commands: [SlashCommand]
    /// The index of the highlighted command.
    var selected = 0
}

/// The list under the caret. It never takes the keyboard: the text view goes on getting what is typed,
/// and moves the highlight itself. A list longer than `visibleRows` scrolls, and follows the highlight.
final class SlashMenuPanel: NSPanel {
    static let rowHeight: CGFloat = 26
    static let visibleRows = 9
    private static let width: CGFloat = 220
    private static let inset: CGFloat = 5

    /// Called with the index of a command that was clicked.
    var onChoose: ((Int) -> Void)?
    private var rows: [SlashMenuRow] = []
    private var commands: [SlashCommand] = []
    private let background = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let list = SlashMenuList()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        contentView = background
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = list
        scrollView.autoresizingMask = [.width, .height]
        background.addSubview(scrollView)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The part of the list that is shown (for tests): which rows, counted from the first.
    var shownRows: ClosedRange<Int> {
        let visible = scrollView.contentView.bounds
        let first = Int(((visible.minY - Self.inset) / Self.rowHeight).rounded(.up))
        let last = Int(((visible.maxY - Self.inset) / Self.rowHeight).rounded(.down)) - 1
        return max(first, 0)...max(min(last, rows.count - 1), max(first, 0))
    }

    /// Shows `menu` under `caret` (a rectangle on the screen), or above it if there is no room below.
    func show(_ menu: SlashMenu, at caret: NSRect, in parent: NSWindow, theme: MarkdownTheme) {
        rows.forEach { $0.removeFromSuperview() }
        let listHeight = CGFloat(menu.commands.count) * Self.rowHeight + 2 * Self.inset
        let height = min(listHeight, CGFloat(Self.visibleRows) * Self.rowHeight + 2 * Self.inset)
        rows = menu.commands.enumerated().map { index, command in
            let isSelected = index == menu.selected
            let row = SlashMenuRow(title: command.title, shortcut: command.shortcut,
                                   icon: command.icon(theme: theme, isSelected: isSelected), isSelected: isSelected)
            row.frame = NSRect(x: Self.inset, y: Self.inset + CGFloat(index) * Self.rowHeight,
                               width: Self.width - 2 * Self.inset, height: Self.rowHeight)
            row.onClick = { [weak self] in self?.onChoose?(index) }
            list.addSubview(row)
            return row
        }
        var origin = NSPoint(x: caret.minX - 8, y: caret.minY - height - 4)
        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
            if origin.y < visible.minY { origin.y = caret.maxY + 4 }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - Self.width - 4)
        }
        setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: false)
        scrollView.frame = background.bounds
        list.frame = NSRect(x: 0, y: 0, width: Self.width, height: listHeight)
        // A list that changed starts at its top; then the highlighted row is brought into view, with the
        // list's own margin when it is the first or the last.
        if commands != menu.commands {
            commands = menu.commands
            list.scroll(.zero)
        }
        if rows.indices.contains(menu.selected) {
            list.scrollToVisible(rows[menu.selected].frame.insetBy(dx: 0, dy: -Self.inset))
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
        display()
        if parent.childWindows?.contains(self) != true { parent.addChildWindow(self, ordered: .above) }
        orderFront(nil)
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

/// The rows, from the top down.
private final class SlashMenuList: NSView {
    override var isFlipped: Bool { true }
}

private final class SlashMenuRow: NSView {
    var onClick: (() -> Void)?
    private let isSelected: Bool

    init(title: String, shortcut: String?, icon: NSImage?, isSelected: Bool) {
        self.isSelected = isSelected
        super.init(frame: .zero)
        let image = NSImageView(frame: NSRect(x: 6, y: 6, width: 18, height: 14))
        image.image = icon
        image.imageScaling = .scaleProportionallyDown
        image.contentTintColor = isSelected ? .white : .labelColor
        addSubview(image)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = isSelected ? .white : .labelColor
        label.frame = NSRect(x: 32, y: 4, width: 124, height: 18)
        addSubview(label)
        if let shortcut {
            let hint = NSTextField(labelWithString: shortcut)
            hint.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            hint.textColor = isSelected ? NSColor.white.withAlphaComponent(0.75) : .tertiaryLabelColor
            hint.alignment = .right
            hint.frame = NSRect(x: 156, y: 5, width: 46, height: 15)
            addSubview(hint)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
