import AppKit

extension NSAttributedString.Key {
    /// Value: Int — UTF-16 offset of the character between "[" and "]" of a task checkbox. Set on the
    /// whole task prefix ("- [ ]"), which is also the click target for toggling.
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
    /// Value: true — the text of an inline code span, drawn on a rounded background.
    static let mdInlineCode = NSAttributedString.Key("MDInlineCode")
    /// Value: CGFloat — set on the first character of a marker run that, when concealed, is replaced by
    /// a box of this width (checkbox, quote bar), so the text after it does not move.
    static let mdConcealBox = NSAttributedString.Key("MDConcealBox")
}

/// Line kinds, matching the block types of Notion-flavored Markdown.
enum MarkdownLine: String, Sendable {
    case text, h1, h2, h3, h4, bullet, ordered, task, quote, fence, code, rule

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

/// Colors and sizes modelled on Notion's default (light) page style, scaled to a sticky note.
struct MarkdownTheme {
    var fontSize: CGFloat = 14
    /// Notion's text color, rgb(55, 53, 47).
    var textColor = NSColor(srgbRed: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 1)
    /// Markdown syntax on the line being edited.
    var markerColor = NSColor(srgbRed: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.35)
    /// Checked to-dos and other de-emphasized text.
    var mutedColor = NSColor(srgbRed: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.45)
    var linkUnderlineColor = NSColor(srgbRed: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.4)
    /// Notion's inline code: red text on a warm gray background.
    var inlineCodeColor = NSColor(srgbRed: 235 / 255, green: 87 / 255, blue: 87 / 255, alpha: 1)
    var codeBackground = NSColor(srgbRed: 135 / 255, green: 131 / 255, blue: 120 / 255, alpha: 0.15)
    var dividerColor = NSColor(srgbRed: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.16)
    /// Notion's checked checkbox fill.
    var checkboxFill = NSColor(srgbRed: 35 / 255, green: 131 / 255, blue: 226 / 255, alpha: 1)
    /// Notion: h1 30px, h2 24px, h3 20px on a 16px body (h4 is newer and slightly larger than body).
    var headingScale: [CGFloat] = [1.875, 1.5, 1.25, 1.125]

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
    /// Code blocks: inset inside their background, like Notion's.
    private let codeParagraph: NSParagraphStyle
    /// Where list and to-do text starts, as in Notion (bullets, numbers and checkboxes line up).
    private var listTextIndent: CGFloat { theme.fontSize * 2 }

    // Block level (matched against one line; ^ and $ bind to the search range).
    private let fenceOpen = makeRegex(#"^[ \t]*(`{3,}|~{3,})"#)
    private let fenceClose = makeRegex(#"^[ \t]*(`{3,}|~{3,})[ \t]*$"#)
    private let thematicBreak = makeRegex(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private let heading = makeRegex(#"^ {0,3}(#{1,6})(?:[ \t]+|$)"#)
    private let quote = makeRegex(#"^ {0,3}(?:>[ \t]?)+"#)
    private let task = makeRegex(#"^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+(\[[ xX]\])(?:[ \t]+|$)"#)
    private let listItem = makeRegex(#"^([ \t]*)([-*+]|\d{1,9}[.)])(?:[ \t]+|$)"#)

    // Inline. Emphasis patterns expose groups 1 = opening delimiter, 2 = content, 3 = closing.
    private let codeSpan = makeRegex(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private let link = makeRegex(#"\[([^\]\n]+)\]\(([^()\s]+)(?:[ \t]+"[^"\n]*")?\)"#)
    // ASCII-only so that Japanese text right after a URL ("…/pathを参照") is not swallowed.
    private let bareURL = makeRegex(#"https?://[A-Za-z0-9\-._~:/?#@!$&'*+,;=%]*[A-Za-z0-9\-_~/#@$&*+=%]"#)
    private let bold = makeRegex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)(\1)"#)
    private let italicStar = makeRegex(#"(?<![*\\])(\*)(?![\s*])(.+?)(?<![\s*\\])(\*)(?!\*)"#)
    private let italicUnderscore = makeRegex(#"(?<![_\w\\])(_)(?![\s_])(.+?)(?<![\s_\\])(_)(?![_\w])"#)
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
        baseParagraph = paragraph
        let code = paragraph.mutableCopy() as! NSMutableParagraphStyle
        code.firstLineHeadIndent = 10
        code.headIndent = 10
        code.tailIndent = -10
        code.minimumLineHeight = (theme.fontSize * 1.3).rounded()
        code.maximumLineHeight = code.minimumLineHeight
        codeParagraph = code
        baseAttributes = [.font: theme.bodyFont, .foregroundColor: theme.textColor, .paragraphStyle: paragraph,
                          .mdLine: MarkdownLine.text.rawValue]
    }

    /// Restyles the whole storage. Sticky notes are small, so a full pass per keystroke is cheap.
    func restyle(_ storage: NSTextStorage) {
        let text = storage.string
        let ns = text as NSString
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: ns.length))

        var fence: Fence?
        var location = 0
        while location < ns.length {
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                            for: NSRange(location: location, length: 0))
            styleLine(NSRange(location: start, length: contentsEnd - start),
                      paragraph: NSRange(location: start, length: end - start),
                      storage: storage, text: text, fence: &fence)
            location = end
        }
        fixBrackets(in: NSRange(location: 0, length: ns.length), storage, ns)
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
                           text: String, fence: inout Fence?) {
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
            return
        }
        if let m = heading.firstMatch(in: text, range: line) {
            let level = min(m.range(at: 1).length, 4) // Notion has four heading levels; 5 and 6 become 4
            kind(.heading(level))
            let size = theme.fontSize * theme.headingScale[level - 1]
            let style = baseParagraph.mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacingBefore = level <= 2 ? 8 : 4
            style.minimumLineHeight = (size * 1.3).rounded()
            style.maximumLineHeight = style.minimumLineHeight
            s.addAttribute(.paragraphStyle, value: style, range: paragraph)
            // Font only on the line content, not on its newline: the newline keeps the body font,
            // so text typed (or composed with the IME) on the next line starts at body size.
            s.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold), range: line)
            dim(m.range, s)
            styleInline(after: m.range, in: line, s, text)
            return
        }

        var content = line
        var prefixEnd = line.location
        var lineKind = MarkdownLine.text

        if let m = quote.firstMatch(in: text, range: content) {
            lineKind = .quote
            dim(m.range, s)
            pad(m.range, to: theme.fontSize * 1.2, s, ns)
            // Concealed, the "> " becomes a box of the same width that holds Notion's quote bar.
            s.addAttribute(.mdConcealBox, value: width(of: m.range, s, ns),
                           range: NSRange(location: m.range.location, length: 1))
            prefixEnd = NSMaxRange(m.range)
            content = NSRange(location: prefixEnd, length: NSMaxRange(line) - prefixEnd)
        }

        if let m = task.firstMatch(in: text, range: content) {
            if lineKind == .text { lineKind = .task }
            let box = m.range(at: 3)
            let checkLocation = box.location + 1
            let isChecked = ns.character(at: checkLocation) != 0x20 // " "
            // "- [ ]": concealed, the whole prefix becomes one checkbox box of the same width.
            let prefix = NSRange(location: m.range(at: 2).location, length: NSMaxRange(box) - m.range(at: 2).location)
            fixBrackets(in: box, s, ns) // before measuring the prefix
            dim(prefix, s)
            pad(prefix, through: NSRange(location: prefix.location, length: NSMaxRange(m.range) - prefix.location),
                to: listTextIndent, s, ns)
            s.addAttributes([.mdTaskToggle: checkLocation,
                             .mdConcealBox: width(of: prefix, s, ns)],
                            range: NSRange(location: prefix.location, length: 1))
            s.addAttribute(.mdTaskToggle, value: checkLocation, range: prefix)
            prefixEnd = NSMaxRange(m.range)
            content = NSRange(location: prefixEnd, length: NSMaxRange(line) - prefixEnd)
            if isChecked {
                s.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                 .strikethroughColor: theme.mutedColor,
                                 .foregroundColor: theme.mutedColor], range: content)
            }
        } else if let m = listItem.firstMatch(in: text, range: content) {
            let marker = m.range(at: 2)
            if ns.character(at: marker.location) >= 0x30, ns.character(at: marker.location) <= 0x39 {
                if lineKind == .text { lineKind = .ordered } // "1." stays visible, as in Notion
            } else {
                if lineKind == .text { lineKind = .bullet }
                // Syntax, but in the text color: concealed, the same glyph slot shows a Notion bullet.
                s.addAttributes([.mdMarker: true, .mdBullet: depth(of: m.range(at: 1), ns)], range: marker)
            }
            pad(marker, through: NSRange(location: marker.location, length: NSMaxRange(m.range) - marker.location),
                to: listTextIndent, s, ns)
            prefixEnd = NSMaxRange(m.range)
            content = NSRange(location: prefixEnd, length: NSMaxRange(line) - prefixEnd)
        }

        kind(lineKind)
        if prefixEnd > line.location {
            applyHangingIndent(prefix: NSRange(location: line.location, length: prefixEnd - line.location),
                               paragraph: paragraph, s, ns)
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

    /// Wrapped lines of a list item / quote align with the text after the marker.
    /// The concealed prefix has the same width as the visible one (see mdConcealBox), so this holds
    /// for both.
    private func applyHangingIndent(prefix: NSRange, paragraph: NSRange, _ s: NSTextStorage, _ ns: NSString) {
        let style = baseParagraph.mutableCopy() as! NSMutableParagraphStyle
        style.headIndent = width(of: prefix, s, ns)
        s.addAttribute(.paragraphStyle, value: style, range: paragraph)
    }

    // MARK: Inline

    private func styleInline(after marker: NSRange, in line: NSRange, _ s: NSTextStorage, _ text: String) {
        let start = NSMaxRange(marker)
        styleInline(NSRange(location: start, length: NSMaxRange(line) - start), s, text)
    }

    private func styleInline(_ range: NSRange, _ s: NSTextStorage, _ text: String) {
        guard range.length > 1 else { return }
        var claimed: [NSRange] = []

        // `code` first: nothing inside a code span is Markdown.
        for m in codeSpan.matches(in: text, range: range) {
            let open = m.range(at: 1)
            let close = NSRange(location: NSMaxRange(m.range) - open.length, length: open.length)
            let size = (s.attribute(.font, at: m.range.location, effectiveRange: nil) as? NSFont)?.pointSize
            s.addAttributes([.font: theme.codeFont(size: size), .foregroundColor: theme.inlineCodeColor,
                             .mdInlineCode: true, .mdCode: true], range: m.range(at: 2))
            dim(open, s)
            dim(close, s)
            claimed.append(m.range)
        }

        // [label](url): the label looks like a Notion link, the syntax around it is Markdown.
        for m in link.matches(in: text, range: range) where isFree(m.range, claimed) {
            let label = m.range(at: 1)
            let target = (text as NSString).substring(with: m.range(at: 2))
            dim(NSRange(location: m.range.location, length: 1), s)
            dim(NSRange(location: NSMaxRange(label), length: NSMaxRange(m.range) - NSMaxRange(label)), s)
            s.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                             .underlineColor: theme.linkUnderlineColor], range: label)
            if let url = URL(string: target) {
                s.addAttribute(.mdLink, value: url, range: label)
            }
            let tail = NSMaxRange(label)
            claimed.append(NSRange(location: m.range.location, length: 1))
            claimed.append(NSRange(location: tail, length: NSMaxRange(m.range) - tail))
        }

        for m in bareURL.matches(in: text, range: range) where isFree(m.range, claimed) {
            s.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                             .underlineColor: theme.linkUnderlineColor, .mdBareURL: true], range: m.range)
            if let url = URL(string: (text as NSString).substring(with: m.range)) {
                s.addAttribute(.mdLink, value: url, range: m.range)
            }
            claimed.append(m.range)
        }

        applyDelimited(bold, in: range, text, s, &claimed) { addBold($0, s) }
        // Obliqueness instead of an italic font face: CJK fonts have no italic, so this
        // slants Japanese text as well as Latin text.
        applyDelimited(italicStar, in: range, text, s, &claimed) { s.addAttribute(.obliqueness, value: 0.2, range: $0) }
        applyDelimited(italicUnderscore, in: range, text, s, &claimed) { s.addAttribute(.obliqueness, value: 0.2, range: $0) }
        applyDelimited(strike, in: range, text, s, &claimed) {
            s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: $0)
        }
    }

    private func applyDelimited(_ regex: NSRegularExpression, in range: NSRange, _ text: String,
                                _ s: NSTextStorage, _ claimed: inout [NSRange], style: (NSRange) -> Void) {
        for m in regex.matches(in: text, range: range) {
            let open = m.range(at: 1), close = m.range(at: 3)
            guard isFree(open, claimed), isFree(close, claimed) else { continue }
            style(m.range(at: 2))
            dim(open, s)
            dim(close, s)
            claimed.append(open)
            claimed.append(close)
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

    private func isFree(_ range: NSRange, _ claimed: [NSRange]) -> Bool {
        !claimed.contains { NSIntersectionRange($0, range).length > 0 }
    }
}
