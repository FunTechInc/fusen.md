import AppKit

enum NoteColor: String, Codable, CaseIterable, Sendable {
    case yellow, blue, green, pink, purple, gray

    var title: String {
        switch self {
        case .yellow: "イエロー"
        case .blue: "ブルー"
        case .green: "グリーン"
        case .pink: "ピンク"
        case .purple: "パープル"
        case .gray: "グレイ"
        }
    }

    var background: NSColor {
        switch self {
        case .yellow: NSColor(srgbRed: 1.00, green: 0.96, blue: 0.64, alpha: 1)
        case .blue:   NSColor(srgbRed: 0.72, green: 0.88, blue: 1.00, alpha: 1)
        case .green:  NSColor(srgbRed: 0.76, green: 0.96, blue: 0.70, alpha: 1)
        case .pink:   NSColor(srgbRed: 1.00, green: 0.80, blue: 0.87, alpha: 1)
        case .purple: NSColor(srgbRed: 0.87, green: 0.80, blue: 1.00, alpha: 1)
        case .gray:   NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)
        }
    }

    /// The paper in ダークモード: the same hue, dark (about as light as Notion's dark pages), so that a
    /// yellow note is still told from a blue one.
    var darkBackground: NSColor {
        switch self {
        case .yellow: NSColor(srgbRed: 0x3A / 255, green: 0x35 / 255, blue: 0x24 / 255, alpha: 1)
        case .blue:   NSColor(srgbRed: 0x22 / 255, green: 0x31 / 255, blue: 0x40 / 255, alpha: 1)
        case .green:  NSColor(srgbRed: 0x25 / 255, green: 0x36 / 255, blue: 0x29 / 255, alpha: 1)
        case .pink:   NSColor(srgbRed: 0x3E / 255, green: 0x2A / 255, blue: 0x33 / 255, alpha: 1)
        case .purple: NSColor(srgbRed: 0x31 / 255, green: 0x2B / 255, blue: 0x43 / 255, alpha: 1)
        case .gray:   NSColor(srgbRed: 0x2E / 255, green: 0x2E / 255, blue: 0x2E / 255, alpha: 1)
        }
    }
}

/// 強調表示: what a note emphasizes while one of its two buttons is on — only the to-dos in progress, or
/// only the waiting ones. Everything else is dimmed on darkened paper.
enum NoteFocus: String, Codable, CaseIterable, Sendable {
    case doing, waiting

    var state: TaskState {
        switch self {
        case .doing: .doing
        case .waiting: .waiting
        }
    }

    var title: String {
        switch self {
        case .doing: "進行中だけを強調"
        case .waiting: "待機だけを強調"
        }
    }
}

/// Everything about a note except its text (which lives in notes/<id>.md).
struct NoteMeta: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var frame: CGRect
    var color: NoteColor
    var isFloating: Bool
    var isTranslucent: Bool
    /// Visible on every desktop (Space), so the note stays put when switching desktops.
    var isOnAllSpaces: Bool
    var created: Date
    var modified: Date
    /// Set while the note is in the trash. Its text stays in notes/<id>.md so it can be restored.
    var deletedAt: Date?
    /// 強調表示, if it is on. Only how the note is shown: its text is not affected.
    var focus: NoteFocus?

    var isDeleted: Bool { deletedAt != nil }

    init(id: UUID = UUID(), frame: CGRect, color: NoteColor = .yellow, created: Date = Date()) {
        self.id = id
        self.frame = frame
        self.color = color
        isFloating = false
        isTranslucent = false
        isOnAllSpaces = true
        self.created = created
        modified = created
        deletedAt = nil
    }

    // Hand-written so index.json files saved before a key existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        frame = try c.decode(CGRect.self, forKey: .frame)
        color = (try? c.decodeIfPresent(NoteColor.self, forKey: .color)) ?? .yellow // an unknown color too
        isFloating = try c.decodeIfPresent(Bool.self, forKey: .isFloating) ?? false
        isTranslucent = try c.decodeIfPresent(Bool.self, forKey: .isTranslucent) ?? false
        isOnAllSpaces = try c.decodeIfPresent(Bool.self, forKey: .isOnAllSpaces) ?? true
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? created
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        focus = try? c.decodeIfPresent(NoteFocus.self, forKey: .focus) // an unknown value: off
    }
}

enum NoteTitle {
    private static let leadingMarker = #"^\s*(#{1,6}\s+|>\s*|[-*+]\s+(\["# + TaskState.characterClass + #"\]\s+)?|\d{1,9}[.)]\s+)"#

    /// First non-empty line without its Markdown block marker (Window menu, Mission Control, history list).
    /// A card's opening line counts with its title; the lines that are only card syntax do not count.
    static func derive(from text: String) -> String {
        var firstLine = ""
        for line in text.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            let ns = String(line) as NSString
            let whole = NSRange(location: 0, length: ns.length)
            if CardSyntax.isStructureOnly(ns as String, whole) { continue }
            if CardSyntax.isOpen(ns as String, whole) {
                let title = ns.substring(with: CardSyntax.parseOpen(ns, line: whole).title)
                if title.allSatisfy(\.isWhitespace) { continue }
                firstLine = title
            } else {
                firstLine = ns as String
            }
            break
        }
        let title = firstLine
            .replacingOccurrences(of: leadingMarker, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "無題のメモ" : String(title.prefix(60))
    }
}
