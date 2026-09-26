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
        color = try c.decodeIfPresent(NoteColor.self, forKey: .color) ?? .yellow
        isFloating = try c.decodeIfPresent(Bool.self, forKey: .isFloating) ?? false
        isTranslucent = try c.decodeIfPresent(Bool.self, forKey: .isTranslucent) ?? false
        isOnAllSpaces = try c.decodeIfPresent(Bool.self, forKey: .isOnAllSpaces) ?? true
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? created
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
    }
}

enum NoteTitle {
    private static let leadingMarker = #"^\s*(#{1,6}\s+|>\s*|[-*+]\s+(\[[ xX]\]\s+)?|\d{1,9}[.)]\s+)"#

    /// First non-empty line without its Markdown block marker (Window menu, Mission Control, history list).
    static func derive(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .first { !$0.allSatisfy(\.isWhitespace) }
            .map(String.init) ?? ""
        let title = firstLine
            .replacingOccurrences(of: leadingMarker, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "無題のメモ" : String(title.prefix(60))
    }
}
