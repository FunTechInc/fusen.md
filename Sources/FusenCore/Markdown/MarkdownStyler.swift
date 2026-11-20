import AppKit

extension NSAttributedString.Key {
    /// Value: Int — UTF-16 offset of the character between "[" and "]" of a task checkbox (its state,
    /// see `TaskState`). Set on the whole task prefix ("- [ ]"), which is also the click target for
    /// changing the state.
    static let mdTaskToggle = NSAttributedString.Key("MDTaskToggle")
    /// Value: URL — target of a Markdown link or bare URL (opened with ⌘-click).
    static let mdLink = NSAttributedString.Key("MDLink")
    /// Value: true — a bare URL (not written as [label](url)).
    static let mdBareURL = NSAttributedString.Key("MDBareURL")
    /// Value: true — Markdown syntax (heading #, emphasis delimiters, link brackets and URL, code
    /// backticks, quote >, bullet and task prefixes, thematic breaks). Hidden when concealed, and
    /// never escaped when exported.
    static let mdMarker = NSAttributedString.Key("MDMarker")
    /// Value: true — literal code (inside a code span or a fenced block). Never escaped when exported.
    static let mdCode = NSAttributedString.Key("MDCode")
    /// Value: String (`MarkdownLine` raw value) — the kind of the line, set on its whole paragraph.
    static let mdLine = NSAttributedString.Key("MDLine")
    /// Value: Int — nesting depth of a bullet marker ("-", "*", "+"); drawn as •, ◦, ▪ when concealed.
    static let mdBullet = NSAttributedString.Key("MDBullet")
    /// Value: String — the number of a numbered item ("1."), drawn centred in its box when concealed.
    static let mdOrdinal = NSAttributedString.Key("MDOrdinal")
    /// Value: true — the text of an inline code span, drawn on a rounded background.
    static let mdInlineCode = NSAttributedString.Key("MDInlineCode")
    /// Value: CGFloat — set on the first character of a marker run that, when concealed, is replaced by
    /// a box of this width (checkbox, quote bar), so the text after it does not move.
    static let mdConcealBox = NSAttributedString.Key("MDConcealBox")
    /// Value: true — a line's block marker with the indentation before it ("## ", "- ", "1. ", "- [ ] ",
    /// "> "), or a whole divider line. When Markdown is concealed the caret never stops inside it, and
    /// Backspace right after it turns the block into plain text (as in Notion).
    static let mdBlockPrefix = NSAttributedString.Key("MDBlockPrefix")
    /// Value: NSValue (NSRange) — on the delimiters of an inline span (bold, italic, strike, code, link),
    /// the range of the whole span with its delimiters. Editing uses it to keep a span's delimiters
    /// together (deleting, splitting at Return, the formatting commands).
    static let mdSpan = NSAttributedString.Key("MDSpan")
    /// Value: String (`MarkdownSpan` raw value) — the kind of that span.
    static let mdSpanKind = NSAttributedString.Key("MDSpanKind")
    /// Value: true — a character made literal by a backslash escape ("\\*" shows "*"). The backslash
    /// itself is `.mdMarker`. Exported verbatim, never matched as syntax.
    static let mdEscaped = NSAttributedString.Key("MDEscaped")
    /// Value: CGFloat — 強調表示: on a paragraph that is dimmed, how much of its look is left (its text
    /// colors are faded already; the layout manager fades what it draws for the paragraph by the same).
    static let mdFade = NSAttributedString.Key("MDFade")
    /// Value: NSColor — 強調表示: on a paragraph shown on the darkened paper, the color that replaces the
    /// text color in what the layout manager draws for it (bullets, numbers, quote bars).
    static let mdInk = NSAttributedString.Key("MDInk")
    /// Value: Int — on every character of a card (its opening line through its closing line), the
    /// card's number in the note. Two cards never share one, so each card is one run.
    static let mdCard = NSAttributedString.Key("MDCard")
    /// Value: String (`CardColor` raw value) — on the same characters, the card's color.
    static let mdCardColor = NSAttributedString.Key("MDCardColor")
    /// Value: true — 強調表示: on the characters of a card that holds no emphasized to-do. It is drawn
    /// darkened, like the paper.
    static let mdCardShade = NSAttributedString.Key("MDCardShade")
    /// Value: Int — on every character of a row of cards ("::::columns" through "::::"), the row's
    /// number in the note.
    static let mdCardRow = NSAttributedString.Key("MDCardRow")
}

/// Inline span kinds (see `.mdSpanKind`).
enum MarkdownSpan: String, Sendable {
    case bold, italic, boldItalic, strike, code, link
}

/// Line kinds, matching the block types of Notion-flavored Markdown; and the two lines around a card
/// (":::card orange 名前" and ":::", see CardSyntax), whose lines between keep their own kinds, and
/// around a row of cards ("::::columns" and "::::").
enum MarkdownLine: String, Sendable {
    case text, h1, h2, h3, h4, bullet, ordered, task, quote, fence, code, rule
    case cardOpen, cardClose, rowOpen, rowClose

    /// A line around a card or a row of cards: structure, not a block of the note's text.
    var isCardStructure: Bool { self == .cardOpen || self == .cardClose || self == .rowOpen || self == .rowClose }
    /// A line that shows nothing at all when the Markdown is concealed (a card's opening line shows its title).
    var isHiddenLine: Bool { self == .cardClose || self == .rowOpen || self == .rowClose }

    static func heading(_ level: Int) -> MarkdownLine {
        [.h1, .h2, .h3, .h4][min(max(level, 1), 4) - 1]
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
}

func makeRegex(_ pattern: String) -> NSRegularExpression {
    // Patterns are compile-time constants; a failure here is a programming error.
    try! NSRegularExpression(pattern: pattern)
}

/// Colors and sizes of Notion's default (light) page style — Notion publishes no style guide, so the
/// values follow Notion's own layout and the widely used reproduction of its CSS in react-notion-x —
/// scaled to a sticky note (1em = `fontSize`).
struct MarkdownTheme {
    var fontSize: CGFloat = 14
    /// Notion's text color, rgb(55, 53, 47).
    var textColor = NSColor(srgbRed: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 1)
    /// Markdown syntax on the line being edited.
    var markerColor = NSColor(srgbRed: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.35)
    /// Checked to-dos and other de-emphasized text.
    var mutedColor = NSColor(srgbRed: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.45)
    var linkUnderlineColor = NSColor(srgbRed: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.4)
    /// Notion's links: the text color at 70 % opacity, underlined.
    var linkColor = NSColor(srgbRed: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.7)
    /// Notion's inline code: red text on a warm gray background.
    var inlineCodeColor = NSColor(srgbRed: 235 / 255, green: 87 / 255, blue: 87 / 255, alpha: 1)
    var codeBackground = NSColor(srgbRed: 135 / 255, green: 131 / 255, blue: 120 / 255, alpha: 0.15)
    var dividerColor = NSColor(srgbRed: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.16)
    /// Notion's checked checkbox fill.
    var checkboxFill = NSColor(srgbRed: 35 / 255, green: 131 / 255, blue: 226 / 255, alpha: 1)
    /// The marks of the signals (see TaskSignalIcon). The arc of a to-do in progress has the blue of the
    /// checked checkbox — what is being done and what is done are one color, as Notion's "In progress"
    /// is blue too — and the pause mark of one that waits has Notion's orange, which holds its own on
    /// every paper color.
    var doingColor = NSColor(srgbRed: 35 / 255, green: 131 / 255, blue: 226 / 255, alpha: 1)
    var waitingColor = NSColor(srgbRed: 217 / 255, green: 115 / 255, blue: 13 / 255, alpha: 1)
    /// 強調表示 (the Figma): the paper under 67 % black, the emphasized to-dos in white, everything else
    /// at 31 %; the button of the emphasis that is off at 29 %.
    var focusShade: CGFloat = 0.67
    var focusInk = NSColor.white
    var focusFade: CGFloat = 0.31
    var focusButtonFade: CGFloat = 0.29

    // Cards: a rounded rectangle in the card's color, with the title in a tag and "•••" at its top and
    // the card's text right under them, on the card's color (no panel of its own), close to its edges.
    /// Space above and below a card.
    var cardGap: CGFloat = 5
    /// From the card's edges to the tag and the text: above the tag, left and right, below the last line.
    var cardPaddingTop: CGFloat = 7
    var cardPadding: CGFloat = 8
    var cardPaddingBottom: CGFloat = 5
    /// Between the title's tag and the first line of text.
    var cardTagGap: CGFloat = 3
    /// Left and right of the title in its tag.
    var cardTagPadding: CGFloat = 7
    var cardRadius: CGFloat = 8
    var cardTagRadius: CGFloat = 3
    /// The three dots of "•••": their size, the distance between their centres, and how far the last one
    /// is from the card's right edge.
    var cardDotSize: CGFloat = 2.5
    var cardDotSpacing: CGFloat = 7
    var cardDotsInset: CGFloat = 11
    /// The tag is as tall as a line of text, and the title is written in the text's size (the Figma: an
    /// 18px tag and 12px medium for 12px text).
    var cardTagHeight: CGFloat { (fontSize * 1.5).rounded() }
    var cardTitleFont: NSFont { .systemFont(ofSize: fontSize, weight: .medium) }
    /// How far the title is raised so that its capitals sit in the middle of the tag: a line taller than
    /// its font has the extra space above the text, which leaves the text low in it.
    var cardTitleRise: CGFloat {
        let font = cardTitleFont
        let baseline = (cardTagHeight + font.descender).rounded(.up)
        return baseline - font.capHeight / 2 - cardTagHeight / 2
    }
    var cardDotsWidth: CGFloat { 2 * cardDotSpacing + cardDotSize }
    /// How far a card's text is from the card's edges, left and right: it starts under the tag's edge.
    var cardContentInset: CGFloat { cardPadding }
    /// Shown in the tag of a card without a title.
    var cardTitlePlaceholder = "タイトル"
    /// Between two cards that stand side by side.
    var cardRowGap: CGFloat = 10
    /// Cards stand side by side only while each is at least this wide; in a narrower note the cards of a
    /// row are shown one below the other (the note's text stays as it is).
    var cardMinimumWidth: CGFloat = 110

    /// The paper of a note while 強調表示 is on: under black, as the Figma composites it (in sRGB;
    /// NSColor's own blending works in another space and comes out lighter).
    func focusPaper(_ paper: NSColor) -> NSColor { shaded(paper) }

    func shaded(_ color: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return color }
        let keep = 1 - focusShade
        return NSColor(srgbRed: c.redComponent * keep, green: c.greenComponent * keep, blue: c.blueComponent * keep,
                       alpha: c.alphaComponent)
    }
    /// Notion: h1 1.875em, h2 1.5em, h3 1.25em, h4 1.15em, weight 600, line height 1.3.
    var headingScale: [CGFloat] = [1.875, 1.5, 1.25, 1.15]
    /// Notion's quote: 1.2em text after a 3px bar and 0.9em of space.
    var quoteScale: CGFloat = 1.2

    /// Where the text of a bullet, numbered or to-do item starts: Notion puts the marker in a 1.5em
    /// column and the text 2px after it (24px and 26px on a 16px body). Nested items move by the same.
    var listColumn: CGFloat { (fontSize * 1.625).rounded() }
    /// The column the bullet or checkbox is centred in.
    var listMarkerColumn: CGFloat { fontSize * 1.5 }
    var quoteColumn: CGFloat { (3 + fontSize * quoteScale * 0.9).rounded() }

    var bodyFont: NSFont { .systemFont(ofSize: fontSize) }
    func codeFont(size: CGFloat? = nil) -> NSFont {
        .monospacedSystemFont(ofSize: (size ?? fontSize) * 0.85, weight: .regular)
    }
}

/// Re-applies Markdown attributes to an NSTextStorage. It only touches attributes, never characters,
/// and it talks to NSTextStorage only, so it works with any TextKit version. Besides the visible
/// styling it records what each character is (`mdMarker`, `mdCode`, `mdLine`, …); the concealing
/// layout manager and the Notion exporter both read those, so what the note shows and what is
/// exported always agree.
///
/// Deliberately line-based and lenient (not a CommonMark parser). For example, `**「強調」**です` is
/// shown bold although strict CommonMark flanking rules would not emphasize it, which suits Japanese.
@MainActor
final class MarkdownStyler {
    let theme: MarkdownTheme
    let baseAttributes: [NSAttributedString.Key: Any]
    private let baseParagraph: NSParagraphStyle
    /// Code blocks: inset inside their background, like Notion's (1em).
    private let codeParagraph: NSParagraphStyle
    /// Dividers: a thin block, like Notion's.
    private let ruleParagraph: NSParagraphStyle
    /// A card's opening line: the top of the card, the title in its tag, and the space down to the first
    /// line of text. Its closing line: the space from the last line of text to under the card.
    private let cardOpenParagraph: NSParagraphStyle
    private let cardCloseParagraph: NSParagraphStyle
    /// The lines around a row of cards: small (and of no height at all when the Markdown is concealed,
    /// which is the layout manager's doing).
    private let rowLineParagraph: NSParagraphStyle

    // Block level (matched against one line; ^ and $ bind to the search range).
    private let fenceOpen = makeRegex(#"^[ \t]*(`{3,}|~{3,})"#)
    private let fenceClose = makeRegex(#"^[ \t]*(`{3,}|~{3,})[ \t]*$"#)
    // Only dashes, as in Notion: "***" is the start of bold italic, not a divider.
    private let thematicBreak = makeRegex(#"^ {0,3}-(?:[ \t]*-){2,}[ \t]*$"#)
    // A block becomes a heading, quote, list item or to-do once a space follows its marker ("## "),
    // as in Notion: typing "#" or "-" alone keeps it text.
    private let heading = makeRegex(#"^ {0,3}(#{1,6})[ \t]+"#)
    private let quote = makeRegex(#"^ {0,3}(?:>[ \t]+)+"#)
    /// A bare ">" continues a quote begun on the line above (an empty line inside the quote).
    private let quoteContinuation = makeRegex(#"^ {0,3}>[ \t]*$"#)
    private let task = makeRegex(#"^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+(\["# + TaskState.characterClass + #"\])[ \t]+"#)
    private let listItem = makeRegex(#"^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+"#)

    // Inline. Emphasis patterns expose groups 1 = opening delimiter, 2 = content, 3 = closing.
    private let codeSpan = makeRegex(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private let link = makeRegex(#"\[([^\]\n]+)\]\(([^()\s]+)(?:[ \t]+"[^"\n]*")?\)"#)
    // ASCII-only so that Japanese text right after a URL ("…/pathを参照") is not swallowed.
    static let bareURLPattern = #"https?://[A-Za-z0-9\-._~:/?#@!$&'*+,;=%]*[A-Za-z0-9\-_~/#@$&*+=%]"#
    private let bareURL = makeRegex(MarkdownStyler.bareURLPattern)
    private let boldItalic = makeRegex(#"(\*\*\*|___)(?=\S)(.+?)(?<=\S)(\1)"#)
    private let bold = makeRegex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)(\1)"#)
    private let italicStar = makeRegex(#"(?<![*])(\*)(?![\s*])(.+?)(?<![\s*])(\*)(?!\*)"#)
    private let italicUnderscore = makeRegex(#"(?<![_\w])(_)(?![\s_])(.+?)(?<![\s_])(_)(?![_\w])"#)
    private let strike = makeRegex(#"(~~)(?=\S)(.+?)(?<=\S)(~~)"#)

    private struct Fence {
        let character: unichar
        let length: Int
    }

    init(theme: MarkdownTheme = MarkdownTheme()) {
        self.theme = theme
        // A fixed line height (Notion uses 1.5): otherwise a line gets taller as soon as a fallback
        // font with larger metrics (e.g. Hiragino for brackets next to Japanese) appears in it.
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = (theme.fontSize * 1.5).rounded()
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        paragraph.paragraphSpacing = 2
        paragraph.tabStops = []
        paragraph.defaultTabInterval = theme.listColumn // a tab nests by one list level
        baseParagraph = paragraph
        let code = paragraph.mutableCopy() as! NSMutableParagraphStyle
        code.firstLineHeadIndent = theme.fontSize
        code.headIndent = theme.fontSize
        code.tailIndent = -theme.fontSize
        code.minimumLineHeight = (theme.fontSize * 1.3).rounded()
        code.maximumLineHeight = code.minimumLineHeight
        codeParagraph = code
        let rule = paragraph.mutableCopy() as! NSMutableParagraphStyle
        rule.minimumLineHeight = theme.fontSize.rounded()
        rule.maximumLineHeight = rule.minimumLineHeight
        rule.paragraphSpacing = 4
        rule.paragraphSpacingBefore = 2
        ruleParagraph = rule
        let cardOpen = paragraph.mutableCopy() as! NSMutableParagraphStyle
        cardOpen.minimumLineHeight = theme.cardTagHeight
        cardOpen.maximumLineHeight = theme.cardTagHeight
        cardOpen.paragraphSpacingBefore = theme.cardGap + theme.cardPaddingTop
        cardOpen.paragraphSpacing = theme.cardTagGap
        cardOpen.firstLineHeadIndent = theme.cardPadding + theme.cardTagPadding
        cardOpen.headIndent = cardOpen.firstLineHeadIndent
        // The title ends before "•••".
        cardOpen.tailIndent = -(theme.cardDotsInset + theme.cardDotsWidth + theme.cardTagPadding + 6)
        cardOpenParagraph = cardOpen
        let cardClose = paragraph.mutableCopy() as! NSMutableParagraphStyle
        cardClose.minimumLineHeight = theme.cardPaddingBottom + theme.cardGap
        cardClose.maximumLineHeight = cardClose.minimumLineHeight
        cardClose.paragraphSpacing = 0
        cardClose.firstLineHeadIndent = theme.cardContentInset // where ":::" stands when the Markdown is shown
        cardCloseParagraph = cardClose
        let rowLine = paragraph.mutableCopy() as! NSMutableParagraphStyle
        rowLine.minimumLineHeight = theme.fontSize.rounded()
        rowLine.maximumLineHeight = rowLine.minimumLineHeight
        rowLine.paragraphSpacing = 0
        rowLineParagraph = rowLine
        baseAttributes = [.font: theme.bodyFont, .foregroundColor: theme.textColor, .paragraphStyle: paragraph,
                          .mdLine: MarkdownLine.text.rawValue]
    }

    /// Restyles the whole storage. Sticky notes are small, so a full pass per keystroke is cheap.
    /// With `focus` (強調表示), only the to-dos in that state keep their look; see `applyFocus`.
    /// `width` is how wide the text is laid out, if that is known: in a note too narrow for a row of
    /// cards, the row's cards are shown one below the other.
    func restyle(_ storage: NSTextStorage, focus: NoteFocus? = nil, width: CGFloat? = nil) {
        let text = storage.string
        let ns = text as NSString
        storage.beginEditing()
        defer { storage.endEditing() }
        defer { if let focus { applyFocus(focus, storage, ns) } }
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: ns.length))

        // The cards first: which lines open and close one is known before the lines are styled.
        var scanned: Fence?
        let blocks = CardSyntax.blocks(in: ns) { isFenced($0, text, ns, &scanned) }
        let cards = blocks.cards
        var card = 0 // the card the pass is in, or comes to next
        var row = 0  // and the row of cards

        var fence: Fence?
        var previous = MarkdownLine.text
        var location = 0
        while location < ns.length {
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                            for: NSRange(location: location, length: 0))
            let paragraph = NSRange(location: start, length: end - start)
            if row < blocks.rows.count, start == blocks.rows[row].open.location {
                styleRowLine(.rowOpen, paragraph, storage, ns)
            } else if row < blocks.rows.count, start == blocks.rows[row].close.location {
                styleRowLine(.rowClose, paragraph, storage, ns)
                storage.addAttribute(.mdCardRow, value: row, range: blocks.rows[row].range)
                putSideBySide(blocks.rows[row], cards, storage, ns, width: width)
                row += 1
            } else if card < cards.count, start == cards[card].open.location {
                styleCardOpen(cards[card], storage)
            } else if card < cards.count, start == cards[card].close.location {
                styleCardClose(cards[card], number: card, storage)
                card += 1
            } else {
                styleLine(NSRange(location: start, length: contentsEnd - start), paragraph: paragraph,
                          storage: storage, text: text, fence: &fence, previous: previous)
                if card < cards.count, start > cards[card].open.location {
                    inset(paragraph, by: theme.cardContentInset, storage) // a line of the card's text
                }
            }
            previous = (storage.attribute(.mdLine, at: start, effectiveRange: nil) as? String).flatMap(MarkdownLine.init) ?? .text
            location = end
        }
        fixBrackets(in: NSRange(location: 0, length: ns.length), storage, ns)
    }

    // MARK: Cards

    /// The opening line: its syntax is hidden, and what follows is the title, shown in the tag.
    private func styleCardOpen(_ card: CardSyntax.Card, _ s: NSTextStorage) {
        s.addAttribute(.mdLine, value: MarkdownLine.cardOpen.rawValue, range: card.open)
        dim(card.prefix, s)
        s.addAttribute(.mdBlockPrefix, value: true, range: card.prefix)
        concealAsLineStart(card.prefix, s)
        s.addAttributes([.font: theme.cardTitleFont, .foregroundColor: card.color.tagText,
                         .baselineOffset: theme.cardTitleRise], range: card.title)
        s.addAttribute(.paragraphStyle, value: cardOpenParagraph, range: card.open)
    }

    /// The closing line: all syntax, a thin strip under the card's text. Now that the card is whole, its
    /// characters are marked as its own.
    private func styleCardClose(_ card: CardSyntax.Card, number: Int, _ s: NSTextStorage) {
        let ns = s.string as NSString
        var end = NSMaxRange(card.close)
        while end > card.close.location, ns.character(at: end - 1) == 0x0A || ns.character(at: end - 1) == 0x0D { end -= 1 }
        let line = NSRange(location: card.close.location, length: end - card.close.location)
        s.addAttribute(.mdLine, value: MarkdownLine.cardClose.rawValue, range: card.close)
        dim(line, s)
        s.addAttributes([.mdBlockPrefix: true, .font: NSFont.systemFont(ofSize: (theme.fontSize * 0.7).rounded())], range: line)
        concealAsLineStart(line, s)
        s.addAttribute(.paragraphStyle, value: cardCloseParagraph, range: card.close)
        s.addAttributes([.mdCard: number, .mdCardColor: card.color.rawValue], range: card.range)
    }

    /// A line around a row of cards: all syntax.
    private func styleRowLine(_ kind: MarkdownLine, _ paragraph: NSRange, _ s: NSTextStorage, _ ns: NSString) {
        var end = NSMaxRange(paragraph)
        while end > paragraph.location, ns.character(at: end - 1) == 0x0A || ns.character(at: end - 1) == 0x0D { end -= 1 }
        let line = NSRange(location: paragraph.location, length: end - paragraph.location)
        s.addAttribute(.mdLine, value: kind.rawValue, range: paragraph)
        dim(line, s)
        s.addAttributes([.mdBlockPrefix: true, .font: NSFont.systemFont(ofSize: (theme.fontSize * 0.7).rounded())], range: line)
        concealAsLineStart(line, s)
        s.addAttribute(.paragraphStyle, value: rowLineParagraph, range: paragraph)
    }

    /// The cards of a row stand side by side as the cells of a text table with one row: each card's
    /// paragraphs are one cell, all cells equally wide. (TextKit 1 has no other way to set editable text
    /// in columns.) Not in a note too narrow for them: there they stay one below the other.
    private func putSideBySide(_ row: CardSyntax.Row, _ cards: [CardSyntax.Card], _ s: NSTextStorage, _ ns: NSString, width: CGFloat?) {
        let count = row.cards.count
        guard count > 1 else { return }
        if let width, width / CGFloat(count) < theme.cardMinimumWidth { return }
        let table = NSTextTable()
        table.numberOfColumns = count
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = false
        table.hidesEmptyCells = false
        for (column, index) in row.cards.enumerated() {
            // No widths: the columns share the line equally. The space between two cards is padding of
            // their cells, half of it on each side (the outer edges stay where a single card's are).
            let cell = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: column, columnSpan: 1)
            if column > 0 { cell.setWidth(theme.cardRowGap / 2, type: .absoluteValueType, for: .padding, edge: .minX) }
            if column < count - 1 { cell.setWidth(theme.cardRowGap / 2, type: .absoluteValueType, for: .padding, edge: .maxX) }
            var location = cards[index].range.location
            while location < NSMaxRange(cards[index].range) {
                let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
                let current = s.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
                let style = (current ?? baseParagraph).mutableCopy() as! NSMutableParagraphStyle
                style.textBlocks = [cell]
                s.addAttribute(.paragraphStyle, value: style, range: paragraph)
                location = NSMaxRange(paragraph)
            }
        }
    }

    /// Syntax that is hidden at the start of a line: its first character becomes a box of no width
    /// rather than nothing, because TextKit 1 lays the hidden (null) glyphs a paragraph starts with out
    /// on the line before it — which moves that line, and breaks a table cell that starts with them.
    private func concealAsLineStart(_ syntax: NSRange, _ s: NSTextStorage) {
        guard syntax.length > 0 else { return }
        s.addAttribute(.mdConcealBox, value: CGFloat(0), range: NSRange(location: syntax.location, length: 1))
    }

    /// Moves a paragraph in from both sides, keeping its own indents (a list item's, a code block's).
    private func inset(_ paragraph: NSRange, by inset: CGFloat, _ s: NSTextStorage) {
        guard paragraph.length > 0 else { return }
        let current = s.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
        let style = (current ?? baseParagraph).mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent += inset
        style.headIndent += inset
        style.tailIndent -= inset
        s.addAttribute(.paragraphStyle, value: style, range: paragraph)
    }

    /// Whether `line` is part of a fenced code block (its fences included), moving `fence` past it.
    private func isFenced(_ line: NSRange, _ text: String, _ ns: NSString, _ fence: inout Fence?) -> Bool {
        if let open = fence {
            if let m = fenceClose.firstMatch(in: text, range: line) {
                let marker = m.range(at: 1)
                if ns.character(at: marker.location) == open.character, marker.length >= open.length { fence = nil }
            }
            return true
        }
        if let m = fenceOpen.firstMatch(in: text, range: line) {
            let marker = m.range(at: 1)
            fence = Fence(character: ns.character(at: marker.location), length: marker.length)
            return true
        }
        return false
    }

    // MARK: To-dos

    /// Where the state of the to-do whose prefix holds `index` is written ("- [/] ": the "/"), if `index`
    /// is in one. Found in the prefix itself: the attribute's value is where it was when the text was last
    /// styled, and text being composed with the IME further up (which is not restyled until it is
    /// committed) moves the to-do away from it.
    nonisolated static func taskCheck(at index: Int, in s: NSAttributedString) -> Int? {
        guard index >= 0, index < s.length else { return nil }
        let ns = s.string as NSString
        var run = NSRange()
        guard s.attribute(.mdTaskToggle, at: index, longestEffectiveRange: &run,
                          in: ns.paragraphRange(for: NSRange(location: index, length: 0))) != nil else { return nil }
        var i = run.location
        while i + 2 < NSMaxRange(run) {
            if ns.character(at: i) == 0x5B, TaskState(character: ns.character(at: i + 1)) != nil, ns.character(at: i + 2) == 0x5D {
                return i + 1
            }
            i += 1
        }
        return nil
    }

    /// The state of the to-do whose prefix holds `index`, if it is in one.
    nonisolated static func taskState(at index: Int, in s: NSAttributedString) -> TaskState? {
        taskCheck(at: index, in: s).flatMap { TaskState(character: (s.string as NSString).character(at: $0)) }
    }

    /// The states of the to-dos in `storage` (styled).
    static func taskStates(in storage: NSTextStorage) -> Set<TaskState> {
        var states: Set<TaskState> = []
        storage.enumerateAttribute(.mdTaskToggle, in: NSRange(location: 0, length: storage.length)) { value, run, _ in
            guard value != nil, let state = taskState(at: run.location, in: storage) else { return }
            states.insert(state)
        }
        return states
    }

    // MARK: 強調表示

    /// 強調表示: the paper is darkened (by the window) and every card with it, so a to-do in the emphasized
    /// state is written in white — and with it what is nested under it: the lines that follow it and are
    /// indented deeper than it (Tab nests a list item under the one above). Every other line, a card's
    /// title too, fades to `theme.focusFade` of its colors.
    private func applyFocus(_ focus: NoteFocus, _ s: NSTextStorage, _ ns: NSString) {
        /// How deep the emphasized to-do is indented whose nested lines the pass is in.
        var parent: Int?
        var location = 0
        while location < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            var state: TaskState?
            s.enumerateAttribute(.mdTaskToggle, in: paragraph) { value, _, stop in
                guard let check = value as? Int, check < ns.length else { return }
                state = TaskState(character: ns.character(at: check))
                stop.pointee = true
            }
            let kind = (s.attribute(.mdLine, at: paragraph.location, effectiveRange: nil) as? String).flatMap(MarkdownLine.init) ?? .text
            if s.attribute(.mdCard, at: paragraph.location, effectiveRange: nil) != nil {
                s.addAttribute(.mdCardShade, value: true, range: paragraph)
            }
            // The indentation, and whether anything follows it on the line.
            var end = paragraph.location
            while end < NSMaxRange(paragraph), ns.character(at: end) == 0x20 || ns.character(at: end) == 0x09 { end += 1 }
            let depth = self.depth(of: NSRange(location: paragraph.location, length: end - paragraph.location), ns)
            let isEmpty = end == NSMaxRange(paragraph) || ns.character(at: end) == 0x0A || ns.character(at: end) == 0x0D
            var isLit = false
            if kind.isCardStructure {
                parent = nil // nothing is nested across a card's edge
            } else if state == focus.state {
                isLit = true
                parent = min(parent ?? depth, depth)
            } else if let outer = parent {
                // An empty line between nested lines does not end them.
                if isEmpty || depth > outer { isLit = true } else { parent = nil }
            }
            if isLit {
                recolor(paragraph, s) { isText($0) ? theme.focusInk.withAlphaComponent($0.alphaComponent) : $0 }
                s.addAttribute(.mdInk, value: theme.focusInk, range: paragraph)
            } else {
                recolor(paragraph, s) { $0.withAlphaComponent($0.alphaComponent * theme.focusFade) }
                s.addAttribute(.mdFade, value: theme.focusFade, range: paragraph)
            }
        }
    }

    /// The text color or a tint of it (links, markers, muted text), which white replaces on dark paper.
    private func isText(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB), let t = theme.textColor.usingColorSpace(.sRGB) else { return false }
        return abs(c.redComponent - t.redComponent) + abs(c.greenComponent - t.greenComponent) + abs(c.blueComponent - t.blueComponent) < 0.01
    }

    private func recolor(_ range: NSRange, _ s: NSTextStorage, _ change: (NSColor) -> NSColor) {
        for key in [NSAttributedString.Key.foregroundColor, .underlineColor, .strikethroughColor] {
            s.enumerateAttribute(key, in: range) { value, run, _ in
                guard let color = value as? NSColor else { return }
                s.addAttribute(key, value: change(color), range: run)
            }
        }
    }

    /// On a Japanese system, font fixing gives "[" and "]" in the system font a Japanese fallback font,
    /// whose metrics make that line taller than its neighbours (links and checkboxes contain brackets).
    /// Helvetica Neue's brackets look the same and are left alone.
    private func fixBrackets(in range: NSRange, _ s: NSTextStorage, _ ns: NSString) {
        for i in range.location..<NSMaxRange(range) {
            let c = ns.character(at: i)
            guard c == 0x5B || c == 0x5D, let font = s.attribute(.font, at: i, effectiveRange: nil) as? NSFont,
                  !font.isFixedPitch else { continue }
            let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
            if let replacement = NSFont(name: bold ? "HelveticaNeue-Bold" : "HelveticaNeue", size: font.pointSize) {
                s.addAttribute(.font, value: replacement, range: NSRange(location: i, length: 1))
            }
        }
    }

    // MARK: Block level

    private func styleLine(_ line: NSRange, paragraph: NSRange, storage s: NSTextStorage,
                           text: String, fence: inout Fence?, previous: MarkdownLine) {
        let ns = text as NSString
        func kind(_ k: MarkdownLine) { s.addAttribute(.mdLine, value: k.rawValue, range: paragraph) }

        // Inside a fenced code block: everything is literal until the matching closing fence.
        if let open = fence {
            if let m = fenceClose.firstMatch(in: text, range: line) {
                let marker = m.range(at: 1)
                if ns.character(at: marker.location) == open.character, marker.length >= open.length {
                    kind(.fence)
                    styleFenceLine(line, paragraph, s)
                    fence = nil
                    return
                }
            }
            kind(.code)
            s.addAttributes([.font: theme.codeFont(), .mdCode: true, .paragraphStyle: codeParagraph], range: paragraph)
            return
        }
        if let m = fenceOpen.firstMatch(in: text, range: line) {
            let marker = m.range(at: 1)
            fence = Fence(character: ns.character(at: marker.location), length: marker.length)
            kind(.fence)
            styleFenceLine(line, paragraph, s)
            return
        }
        if thematicBreak.firstMatch(in: text, range: line) != nil {
            kind(.rule)
            dim(line, s)
            s.addAttributes([.mdBlockPrefix: true], range: line)
            s.addAttribute(.paragraphStyle, value: ruleParagraph, range: paragraph)
            return
        }
        if let m = heading.firstMatch(in: text, range: line) {
            let level = min(m.range(at: 1).length, 4) // Notion has four heading levels; 5 and 6 become 4
            kind(.heading(level))
            let size = theme.fontSize * theme.headingScale[level - 1]
            let style = baseParagraph.mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacingBefore = (size * 0.5).rounded() // Notion's is ~1em; halved for a sticky
            style.minimumLineHeight = (size * 1.3).rounded()
            style.maximumLineHeight = style.minimumLineHeight
            s.addAttribute(.paragraphStyle, value: style, range: paragraph)
            // Font only on the line content, not on its newline: the newline keeps the body font,
            // so text typed (or composed with the IME) on the next line starts at body size.
            s.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold), range: line)
            dim(m.range, s)
            s.addAttribute(.mdBlockPrefix, value: true, range: NSRange(location: line.location,
                                                                        length: NSMaxRange(m.range) - line.location))
            styleInline(after: m.range, in: line, s, text)
            return
        }

        var content = line
        var prefixEnd = line.location
        var lineKind = MarkdownLine.text
        var hangingIndent: CGFloat = 0

        if let m = quote.firstMatch(in: text, range: content)
            ?? (previous == .quote ? quoteContinuation.firstMatch(in: text, range: content) : nil) {
            lineKind = .quote
            // Notion's quote text is 1.2em; its line height grows with it.
            let size = theme.fontSize * theme.quoteScale
            s.addAttribute(.font, value: NSFont.systemFont(ofSize: size), range: line)
            dim(m.range, s)
            pad(m.range, to: theme.quoteColumn, s, ns)
            // Concealed, the "> " becomes a box that holds Notion's quote bar; the text follows it.
            s.addAttribute(.mdConcealBox, value: theme.quoteColumn, range: NSRange(location: m.range.location, length: 1))
            hangingIndent = theme.quoteColumn
            prefixEnd = NSMaxRange(m.range)
            content = NSRange(location: prefixEnd, length: NSMaxRange(line) - prefixEnd)
        }

        if let m = task.firstMatch(in: text, range: content) {
            if lineKind == .text { lineKind = .task }
            let box = m.range(at: 3)
            let checkLocation = box.location + 1
            let state = TaskState(character: ns.character(at: checkLocation)) ?? .todo
            // "- [ ] ": concealed, the whole prefix is one list-column-wide box holding the checkbox.
            let marker = m.range(at: 2)
            let prefix = NSRange(location: marker.location, length: NSMaxRange(m.range) - marker.location)
            fixBrackets(in: box, s, ns) // before measuring the prefix
            dim(prefix, s)
            pad(NSRange(location: marker.location, length: NSMaxRange(box) - marker.location), through: prefix,
                to: theme.listColumn, s, ns)
            s.addAttributes([.mdTaskToggle: checkLocation, .mdConcealBox: theme.listColumn],
                            range: NSRange(location: prefix.location, length: 1))
            s.addAttribute(.mdTaskToggle, value: checkLocation, range: prefix)
            hangingIndent += CGFloat(depth(of: m.range(at: 1), ns) + 1) * theme.listColumn
            prefixEnd = NSMaxRange(m.range)
            content = NSRange(location: prefixEnd, length: NSMaxRange(line) - prefixEnd)
            if state == .done {
                s.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                 .strikethroughColor: theme.mutedColor,
                                 .foregroundColor: theme.mutedColor], range: content)
            }
        } else if let m = listItem.firstMatch(in: text, range: content) {
            let marker = m.range(at: 2)
            let prefix = NSRange(location: marker.location, length: NSMaxRange(m.range) - marker.location)
            var box = theme.listColumn
            s.addAttribute(.mdMarker, value: true, range: prefix)
            if ns.character(at: marker.location) >= 0x30, ns.character(at: marker.location) <= 0x39 {
                if lineKind == .text { lineKind = .ordered }
                // Concealed, "1. " is a box with the number centred in it, as in Notion (wider for "100.").
                box = max(box, width(of: marker, s, ns) + theme.fontSize * 0.5)
                s.addAttributes([.mdOrdinal: ns.substring(with: marker), .mdConcealBox: box],
                                range: NSRange(location: marker.location, length: 1))
            } else {
                if lineKind == .text { lineKind = .bullet }
                // Concealed, "- " is one list-column-wide box with Notion's bullet centred in it.
                s.addAttributes([.mdBullet: depth(of: m.range(at: 1), ns), .mdConcealBox: box], range: marker)
            }
            pad(marker, through: prefix, to: box, s, ns)
            hangingIndent += CGFloat(depth(of: m.range(at: 1), ns)) * theme.listColumn + box
            prefixEnd = NSMaxRange(m.range)
            content = NSRange(location: prefixEnd, length: NSMaxRange(line) - prefixEnd)
        }

        kind(lineKind)
        if prefixEnd > line.location {
            s.addAttribute(.mdBlockPrefix, value: true, range: NSRange(location: line.location, length: prefixEnd - line.location))
            let style = baseParagraph.mutableCopy() as! NSMutableParagraphStyle
            style.headIndent = hangingIndent // wrapped lines align with the text after the marker
            if lineKind == .quote {
                style.minimumLineHeight = (theme.fontSize * theme.quoteScale * 1.5).rounded()
                style.maximumLineHeight = style.minimumLineHeight
            }
            s.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
        styleInline(content, s, text)
    }

    private func styleFenceLine(_ line: NSRange, _ paragraph: NSRange, _ s: NSTextStorage) {
        // Fence lines stay visible (small and gray, like Notion's language label); never concealed.
        s.addAttributes([.font: theme.codeFont(size: theme.fontSize * 0.85),
                         .foregroundColor: theme.markerColor], range: line)
        s.addAttribute(.paragraphStyle, value: codeParagraph, range: paragraph)
    }

    /// Widens a marker with kerning after its last character so that the marker plus the whitespace
    /// after it (`span`, default the marker itself) is `target` wide: text after bullets, numbers,
    /// checkboxes and quote bars then starts at the same place, whether the marker is shown or concealed.
    private func pad(_ marker: NSRange, through span: NSRange? = nil, to target: CGFloat,
                     _ s: NSTextStorage, _ ns: NSString) {
        let current = width(of: span ?? marker, s, ns)
        guard current < target, marker.length > 0 else { return }
        s.addAttribute(.kern, value: target - current, range: NSRange(location: NSMaxRange(marker) - 1, length: 1))
    }

    /// Nesting depth from leading whitespace: one level per tab or per two spaces.
    private func depth(of indentation: NSRange, _ ns: NSString) -> Int {
        var tabs = 0, spaces = 0
        for i in 0..<indentation.length {
            if ns.character(at: indentation.location + i) == 0x09 { tabs += 1 } else { spaces += 1 }
        }
        return tabs + spaces / 2
    }

    private func width(of range: NSRange, _ s: NSTextStorage, _ ns: NSString) -> CGFloat {
        ceil(s.attributedSubstring(from: range).size().width)
    }

    // MARK: Inline

    private func styleInline(after marker: NSRange, in line: NSRange, _ s: NSTextStorage, _ text: String) {
        let start = NSMaxRange(marker)
        styleInline(NSRange(location: start, length: NSMaxRange(line) - start), s, text)
    }

    private func styleInline(_ range: NSRange, _ s: NSTextStorage, _ text: String) {
        guard range.length > 1 else { return }
        var claimed: [NSRange] = []

        // Backslash escapes (CommonMark): "\\" before one of the app's syntax characters makes it literal.
        let ns = text as NSString
        var escaped = IndexSet()
        var i = range.location
        while i < NSMaxRange(range) - 1 {
            if ns.character(at: i) == 0x5C, Self.isEscapable(ns.character(at: i + 1)) {
                escaped.insert(i + 1)
                i += 2
            } else {
                i += 1
            }
        }

        // `code` next: nothing inside a code span is Markdown (not even an escape), but an escaped
        // backtick cannot open one.
        var searchFrom = range.location
        while searchFrom < NSMaxRange(range),
              let m = codeSpan.firstMatch(in: text, range: NSRange(location: searchFrom, length: NSMaxRange(range) - searchFrom)) {
            if escaped.contains(m.range.location) { searchFrom = m.range.location + 1; continue }
            searchFrom = NSMaxRange(m.range)
            let open = m.range(at: 1)
            let close = NSRange(location: NSMaxRange(m.range) - open.length, length: open.length)
            let size = (s.attribute(.font, at: m.range.location, effectiveRange: nil) as? NSFont)?.pointSize
            s.addAttributes([.font: theme.codeFont(size: size), .foregroundColor: theme.inlineCodeColor,
                             .mdInlineCode: true, .mdCode: true], range: m.range(at: 2))
            delimit(open, close, span: m.range, .code, s)
            claimed.append(m.range)
        }
        var escapes = IndexSet() // backslash + escaped character: kept apart from `claimed`, which is scanned linearly
        for index in escaped where isFree(NSRange(location: index - 1, length: 2), claimed) {
            dim(NSRange(location: index - 1, length: 1), s) // the backslash: hidden like other syntax
            s.addAttribute(.mdEscaped, value: true, range: NSRange(location: index, length: 1))
            escapes.insert(integersIn: (index - 1)...index)
        }
        func free(_ r: NSRange) -> Bool {
            isFree(r, claimed) && !escapes.intersects(integersIn: r.location..<NSMaxRange(r))
        }

        // [label](url): the label looks like a Notion link, the syntax around it is Markdown.
        // Escapes may be inside the label ([\*\*x\*\*](url)), not on the syntax around it.
        for m in link.matches(in: text, range: range) where isFree(m.range, claimed)
            && free(NSRange(location: m.range.location, length: 1))
            && free(NSRange(location: NSMaxRange(m.range(at: 1)), length: NSMaxRange(m.range) - NSMaxRange(m.range(at: 1)))) {
            let label = m.range(at: 1)
            let target = (text as NSString).substring(with: m.range(at: 2))
            delimit(NSRange(location: m.range.location, length: 1),
                    NSRange(location: NSMaxRange(label), length: NSMaxRange(m.range) - NSMaxRange(label)), span: m.range, .link, s)
            s.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: theme.linkColor,
                             .underlineColor: theme.linkUnderlineColor], range: label)
            if let url = URL(string: target) {
                s.addAttribute(.mdLink, value: url, range: label)
            }
            let tail = NSMaxRange(label)
            claimed.append(NSRange(location: m.range.location, length: 1))
            claimed.append(NSRange(location: tail, length: NSMaxRange(m.range) - tail))
        }

        for m in bareURL.matches(in: text, range: range) where free(m.range) {
            s.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: theme.linkColor,
                             .underlineColor: theme.linkUnderlineColor, .mdBareURL: true], range: m.range)
            if let url = URL(string: (text as NSString).substring(with: m.range)) {
                s.addAttribute(.mdLink, value: url, range: m.range)
            }
            claimed.append(m.range)
        }

        // Obliqueness instead of an italic font face: CJK fonts have no italic, so this
        // slants Japanese text as well as Latin text.
        applyDelimited(boldItalic, .boldItalic, in: range, text, s, &claimed, escapes) {
            addBold($0, s)
            s.addAttribute(.obliqueness, value: 0.2, range: $0)
        }
        applyDelimited(bold, .bold, in: range, text, s, &claimed, escapes) { addBold($0, s) }
        applyDelimited(italicStar, .italic, in: range, text, s, &claimed, escapes) { s.addAttribute(.obliqueness, value: 0.2, range: $0) }
        applyDelimited(italicUnderscore, .italic, in: range, text, s, &claimed, escapes) {
            s.addAttribute(.obliqueness, value: 0.2, range: $0)
        }
        applyDelimited(strike, .strike, in: range, text, s, &claimed, escapes) {
            s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: $0)
        }
    }

    private func applyDelimited(_ regex: NSRegularExpression, _ kind: MarkdownSpan, in range: NSRange, _ text: String,
                                _ s: NSTextStorage, _ claimed: inout [NSRange], _ escapes: IndexSet, style: (NSRange) -> Void) {
        for m in regex.matches(in: text, range: range) {
            let open = m.range(at: 1), close = m.range(at: 3)
            guard isFree(open, claimed), isFree(close, claimed),
                  !escapes.intersects(integersIn: open.location..<NSMaxRange(open)),
                  !escapes.intersects(integersIn: close.location..<NSMaxRange(close)) else { continue }
            style(m.range(at: 2))
            delimit(open, close, span: m.range, kind, s)
            claimed.append(open)
            claimed.append(close)
        }
    }

    /// Marks a span's delimiters as syntax and records the span they belong to.
    private func delimit(_ open: NSRange, _ close: NSRange, span: NSRange, _ kind: MarkdownSpan, _ s: NSTextStorage) {
        for delimiter in [open, close] {
            dim(delimiter, s)
            s.addAttributes([.mdSpan: NSValue(range: span), .mdSpanKind: kind.rawValue], range: delimiter)
        }
    }

    private func addBold(_ range: NSRange, _ s: NSTextStorage) {
        s.enumerateAttribute(.font, in: range) { value, run, _ in
            let font = value as? NSFont ?? theme.bodyFont
            let traits = font.fontDescriptor.symbolicTraits.union(.bold)
            let boldFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize)
            s.addAttribute(.font, value: boldFont ?? font, range: run)
        }
    }

    /// Marks Markdown syntax: dimmed where it is shown, hidden where the note is concealed.
    private func dim(_ range: NSRange, _ s: NSTextStorage) {
        s.addAttributes([.foregroundColor: theme.markerColor, .mdMarker: true], range: range)
    }

    /// Only characters that are syntax in this app: "\\{", "\\%", "\\\"" typed in a note stay as typed.
    private static let escapable = Set("\\`*_~[]()#+-.>!".utf16)
    /// (Also asked by the import from Notion: a backslash before any other character would be shown.)
    static func isEscapable(_ c: unichar) -> Bool { escapable.contains(c) }

    private func isFree(_ range: NSRange, _ claimed: [NSRange]) -> Bool {
        !claimed.contains { NSIntersectionRange($0, range).length > 0 }
    }
}
