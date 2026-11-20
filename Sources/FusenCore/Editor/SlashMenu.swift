import AppKit

/// The commands of the "/" menu (Notion's slash commands): typed at the start of a line's text or after
/// a space, "/" lists them, and what is typed after it narrows the list.
enum SlashCommand: String, CaseIterable, Sendable {
    case card, doing, waiting, todo, divider

    var title: String {
        switch self {
        case .card: "カード"
        case .doing: "進行中のタスク"
        case .waiting: "待機のタスク"
        case .todo: "チェックボックス"
        case .divider: "区切り線"
        }
    }

    /// What can be typed after "/" to mean the command, besides its title: in English as in Notion
    /// ("/ca" is the Figma's own example), and as its reading.
    private var keywords: [String] {
        switch self {
        case .card: ["card", "callout", "かーど"]
        case .doing: ["doing", "progress", "now", "task", "しんこう", "進行", "たすく", "タスク"]
        case .waiting: ["waiting", "next", "pause", "task", "たいき", "待機", "つぎ", "次", "たすく", "タスク"]
        case .todo: ["todo", "to-do", "check", "task", "ちぇっく", "チェック", "やること", "たすく", "タスク"]
        case .divider: ["divider", "line", "hr", "くぎり", "区切", "せん", "線"]
        }
    }

    /// The to-do state the command makes, if it makes a to-do.
    var taskState: TaskState? {
        switch self {
        case .doing: .doing
        case .waiting: .waiting
        case .todo: .todo
        case .card, .divider: nil
        }
    }

    /// The commands that `query` (what is typed after "/") can mean: all of them for nothing typed yet.
    static func matching(_ query: String) -> [SlashCommand] {
        let query = query.lowercased()
        guard !query.isEmpty else { return allCases }
        return allCases.filter { command in
            command.title.lowercased().hasPrefix(query) || command.keywords.contains { $0.hasPrefix(query) }
        }
    }

    /// "/", and "；" for a Japanese keyboard, where "/" types "・" (Notion takes it too).
    static func isTrigger(_ character: unichar) -> Bool { character == 0x2F || character == 0xFF1B }

    @MainActor
    func icon(theme: MarkdownTheme) -> NSImage? {
        if let taskState { return TaskSignalIcon.image(taskState, theme: theme) }
        let name = self == .card ? "rectangle.inset.topleft.filled" : "minus"
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: self == .card ? "rectangle" : "minus", accessibilityDescription: nil)
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
/// and moves the highlight itself.
final class SlashMenuPanel: NSPanel {
    private static let rowHeight: CGFloat = 26
    private static let width: CGFloat = 200
    private static let inset: CGFloat = 5

    /// Called with the index of a command that was clicked.
    var onChoose: ((Int) -> Void)?
    private var rows: [SlashMenuRow] = []
    private let background = NSVisualEffectView()

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
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows `menu` under `caret` (a rectangle on the screen), or above it if there is no room below.
    func show(_ menu: SlashMenu, at caret: NSRect, in parent: NSWindow, theme: MarkdownTheme) {
        rows.forEach { $0.removeFromSuperview() }
        let height = CGFloat(menu.commands.count) * Self.rowHeight + 2 * Self.inset
        rows = menu.commands.enumerated().map { index, command in
            let row = SlashMenuRow(title: command.title, icon: command.icon(theme: theme), isSelected: index == menu.selected)
            row.frame = NSRect(x: Self.inset, y: height - Self.inset - CGFloat(index + 1) * Self.rowHeight,
                               width: Self.width - 2 * Self.inset, height: Self.rowHeight)
            row.onClick = { [weak self] in self?.onChoose?(index) }
            background.addSubview(row)
            return row
        }
        var origin = NSPoint(x: caret.minX - 8, y: caret.minY - height - 4)
        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
            if origin.y < visible.minY { origin.y = caret.maxY + 4 }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - Self.width - 4)
        }
        setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
        if parent.childWindows?.contains(self) != true { parent.addChildWindow(self, ordered: .above) }
        orderFront(nil)
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

private final class SlashMenuRow: NSView {
    var onClick: (() -> Void)?
    private let isSelected: Bool

    init(title: String, icon: NSImage?, isSelected: Bool) {
        self.isSelected = isSelected
        super.init(frame: .zero)
        let image = NSImageView(frame: NSRect(x: 8, y: 6, width: 14, height: 14))
        image.image = icon
        image.imageScaling = .scaleProportionallyUpOrDown
        image.contentTintColor = isSelected ? .white : .labelColor
        addSubview(image)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = isSelected ? .white : .labelColor
        label.frame = NSRect(x: 30, y: 4, width: 160, height: 18)
        addSubview(label)
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
