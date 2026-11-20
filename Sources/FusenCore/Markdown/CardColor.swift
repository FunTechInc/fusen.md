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

    /// The card itself: the frame around its content.
    var frame: NSColor { Self.color(values.frame) }
    /// The tag behind the title.
    var tag: NSColor { Self.color(values.tag) }
    /// The title.
    var tagText: NSColor { Self.color(values.text) }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
