import AppKit

/// The colors of a card: Notion's ten, written as the word after ":::card".
///
/// The Figma draws two cards, orange and purple; their values are used as they are. The others follow
/// the rule those two fit: the title's tag is midway between the fill and the border of Notion's swatch
/// for the color, the card is the tag color at 20 % over white, and the title is the tag's hue, dark.
enum CardColor: String, CaseIterable, Sendable {
    case `default`, gray, brown, orange, yellow, green, blue, purple, pink, red

    var title: String {
        switch self {
        case .default: "デフォルト"
        case .gray: "グレー"
        case .brown: "ブラウン"
        case .orange: "オレンジ"
        case .yellow: "イエロー"
        case .green: "グリーン"
        case .blue: "ブルー"
        case .purple: "パープル"
        case .pink: "ピンク"
        case .red: "レッド"
        }
    }

    private var values: (frame: UInt32, tag: UInt32, text: UInt32) {
        switch self {
        case .default: (0xFBFAFA, 0xEAE8E6, 0x666460)
        case .gray: (0xF9F9F8, 0xE2E0DE, 0x666360)
        case .brown: (0xFAF8F6, 0xE7DAD2, 0x664F42)
        case .orange: (0xFCF7F5, 0xF0D7C9, 0x684327) // the Figma's
        case .yellow: (0xFCF9F2, 0xF0E0BC, 0x664A0E)
        case .green: (0xF6F9F7, 0xD4E2D8, 0x4D6655)
        case .blue: (0xF5F9FD, 0xCBE0F5, 0x204366)
        case .purple: (0xFAF7FC, 0xE4D6EF, 0x543C67) // the Figma's
        case .pink: (0xFCF7F9, 0xF2D7E0, 0x663847)
        case .red: (0xFDF7F6, 0xF6D6D2, 0x66322C)
        }
    }

    /// The card itself: the rectangle its title and its text stand on.
    var frame: NSColor { Self.color(values.frame) }
    /// The tag behind the title.
    var tag: NSColor { Self.color(values.tag) }
    /// The title.
    var tagText: NSColor { Self.color(values.text) }

    /// ダークモード: the tag has the color of Notion's dark tags (select options) of the color, the card is
    /// that color at 30 % over a dark gray (a little lighter than the dark papers, so that the card stands
    /// on them), and the title is light, of the tag's hue.
    private var darkValues: (tag: UInt32, title: UInt32) {
        switch self {
        case .default: (0x464646, 0xEDEDED)
        case .gray: (0x5A5A5A, 0xEDEDED)
        case .brown: (0x603B2C, 0xF2DDD3)
        case .orange: (0x854C1D, 0xF8DCC6)
        case .yellow: (0x7D5A26, 0xF6E4C3) // a little darker than Notion's, for the title
        case .green: (0x2B593F, 0xD3EEDD)
        case .blue: (0x28456C, 0xD3E3F7)
        case .purple: (0x492F64, 0xE6D8F5)
        case .pink: (0x69314C, 0xF5D5E4)
        case .red: (0x6E3630, 0xF7D6D2)
        }
    }

    func frame(isDark: Bool) -> NSColor {
        guard isDark else { return frame }
        let tag = Self.color(darkValues.tag), base: CGFloat = 0x36 / 255
        return NSColor(srgbRed: tag.redComponent * 0.3 + base * 0.7, green: tag.greenComponent * 0.3 + base * 0.7,
                       blue: tag.blueComponent * 0.3 + base * 0.7, alpha: 1)
    }

    func tag(isDark: Bool) -> NSColor { isDark ? Self.color(darkValues.tag) : tag }
    func tagText(isDark: Bool) -> NSColor { isDark ? Self.color(darkValues.title) : tagText }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
