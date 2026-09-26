import AppKit
import Testing
@testable import FusenCore

/// Headless: only NSTextStorage, no windows.
@MainActor
struct MarkdownStylerTests {
    let styler = MarkdownStyler()
    var theme: MarkdownTheme { styler.theme }

    private func styled(_ s: String) -> NSTextStorage {
        let storage = NSTextStorage(string: s)
        styler.restyle(storage)
        return storage
    }
    private func range(_ st: NSTextStorage, _ sub: String) -> NSRange { (st.string as NSString).range(of: sub) }
    private func font(_ st: NSTextStorage, _ sub: String) -> NSFont? {
        st.attribute(.font, at: range(st, sub).location, effectiveRange: nil) as? NSFont
    }
    private func color(_ st: NSTextStorage, _ sub: String) -> NSColor? {
        st.attribute(.foregroundColor, at: range(st, sub).location, effectiveRange: nil) as? NSColor
    }
    private func has(_ st: NSTextStorage, _ key: NSAttributedString.Key, _ sub: String) -> Bool {
        st.attribute(key, at: range(st, sub).location, effectiveRange: nil) != nil
    }
    private func isBold(_ f: NSFont?) -> Bool { f?.fontDescriptor.symbolicTraits.contains(.bold) ?? false }

    @Test func headings() {
        let st = styled("# 見出し\n本文")
        #expect((font(st, "見出し")?.pointSize ?? 0) > theme.fontSize * 1.5)
        #expect(color(st, "#") == theme.markerColor)
        #expect(font(st, "本文")?.pointSize == theme.fontSize)
        // The heading's newline keeps the body font, so IME input on the next line starts at body size.
        #expect((st.attribute(.font, at: range(st, "\n").location, effectiveRange: nil) as? NSFont)?.pointSize == theme.fontSize)
    }

    @Test func emphasisIncludingJapanese() {
        let st = styled("これは**太字**です、**「強調」**も。*斜体*と~~消す~~")
        #expect(isBold(font(st, "太字")))
        #expect(color(st, "**") == theme.markerColor)
        #expect(isBold(font(st, "「強調」")))
        #expect(has(st, .obliqueness, "斜体"))
        #expect(has(st, .strikethroughStyle, "消す"))
        #expect(!isBold(font(st, "これは")))
    }

    @Test func codeIsLiteral() {
        var st = styled("`**not bold**` and **bold**")
        #expect(font(st, "not")?.isFixedPitch == true)
        #expect(!isBold(font(st, "not")))
        st = styled("```swift\nlet a = **x**\n```\n**after**")
        #expect(font(st, "let a")?.isFixedPitch == true)
        #expect(!isBold(font(st, "x**")))
        #expect(isBold(font(st, "after")))
    }

    @Test func listsAndTasks() {
        let st = styled("- [ ] やること\n- [x] 完了\n1. first\n- item")
        let toggle = st.attribute(.mdTaskToggle, at: range(st, "[ ]").location, effectiveRange: nil) as? Int
        #expect(toggle == range(st, "[ ]").location + 1)
        #expect(has(st, .strikethroughStyle, "完了"))
        #expect(!has(st, .strikethroughStyle, "やること"))
        #expect(color(st, "1.") == theme.textColor) // numbers stay visible, as in Notion
        let para = st.attribute(.paragraphStyle, at: range(st, "item").location, effectiveRange: nil) as? NSParagraphStyle
        #expect((para?.headIndent ?? 0) > 0)
    }

    private func line(_ st: NSTextStorage, _ sub: String) -> MarkdownLine? {
        (st.attribute(.mdLine, at: range(st, sub).location, effectiveRange: nil) as? String).flatMap(MarkdownLine.init)
    }

    @Test func lineKindsMatchNotionBlocks() {
        let st = styled("# A\n##### E\n- b\n\t- nested\n1. o\n- [x] t\n> q\n---\n```swift\nlet x\n```\nplain")
        #expect(line(st, "# A") == .h1)
        #expect(line(st, "E") == .h4) // Notion has four heading levels
        #expect(line(st, "- b") == .bullet)
        #expect(line(st, "1. o") == .ordered)
        #expect(line(st, "- [x]") == .task)
        #expect(line(st, "> q") == .quote)
        #expect(line(st, "---") == .rule)
        #expect(line(st, "```swift") == .fence)
        #expect(line(st, "let x") == .code)
        #expect(line(st, "plain") == .text)
        #expect(st.attribute(.mdBullet, at: range(st, "- nested").location, effectiveRange: nil) as? Int == 1)
    }

    @Test func markersAndCodeAreRecorded() {
        let st = styled("**太字** と `a*b` と [リンク](https://x.y/?q=1) と $5")
        let ns = st.string as NSString
        func marker(_ i: Int) -> Bool { st.attribute(.mdMarker, at: i, effectiveRange: nil) != nil }
        func code(_ i: Int) -> Bool { st.attribute(.mdCode, at: i, effectiveRange: nil) != nil }
        #expect(marker(0) && marker(1))                          // **
        #expect(!marker(range(st, "太字").location))
        #expect(code(range(st, "a*b").location + 1))              // * inside code is literal
        #expect(marker(range(st, "[リンク]").location))           // [
        #expect(!marker(range(st, "リンク").location))
        #expect(marker(range(st, "](https").location + 3))        // URL is syntax, not text
        #expect(!marker(ns.range(of: "$5").location))             // plain text to be escaped on export
    }

    @Test func concealBoxesKeepTheirWidth() {
        let st = styled("- [ ] やること\n> 引用")
        let task = st.attribute(.mdConcealBox, at: 0, effectiveRange: nil) as? CGFloat
        let quote = st.attribute(.mdConcealBox, at: range(st, "> ").location, effectiveRange: nil) as? CGFloat
        #expect((task ?? 0) > 10)
        #expect((quote ?? 0) > 3)
        #expect(st.attribute(.mdTaskToggle, at: 0, effectiveRange: nil) as? Int == 3) // whole prefix toggles
    }

    @Test func links() {
        let st = styled("[Apple](https://www.apple.com) と https://example.com/pathを参照")
        #expect((st.attribute(.mdLink, at: range(st, "Apple").location, effectiveRange: nil) as? URL)?.absoluteString
                == "https://www.apple.com")
        var run = NSRange()
        _ = st.attribute(.mdLink, at: range(st, "example").location, effectiveRange: &run)
        #expect((st.string as NSString).substring(with: run) == "https://example.com/path")
    }

    @Test func titles() {
        #expect(NoteTitle.derive(from: "\n\n## 買い物リスト\nfoo") == "買い物リスト")
        #expect(NoteTitle.derive(from: "- [ ] 牛乳を買う") == "牛乳を買う")
        #expect(NoteTitle.derive(from: "  \n") == "無題のメモ")
    }

    @Test func backslashEscapesMakeSyntaxLiteral() {
        let st = styled(#"\*\*not bold\*\* と 2\*3\*4 と \`x\` と [a]\(b)"#)
        #expect(!isBold(font(st, "not")))
        #expect(!has(st, .obliqueness, "3"))
        #expect(font(st, "x")?.isFixedPitch != true)
        #expect(st.attribute(.mdMarker, at: 0, effectiveRange: nil) != nil)   // the backslash is syntax
        #expect(st.attribute(.mdEscaped, at: 1, effectiveRange: nil) != nil)  // the star is literal
        #expect(line(styled(##"\# 見出しではない"##), "見出し") == .text)
        #expect(line(styled(#"\- 箇条書きではない"#), "箇条書き") == .text)
        // A backslash before a letter is just a backslash.
        let path = styled(#"C:\Users"#)
        #expect(path.attribute(.mdMarker, at: 2, effectiveRange: nil) == nil)
        // Inside code, a backslash is literal.
        let code = styled(#"`a\*b`"#)
        #expect(code.attribute(.mdEscaped, at: 3, effectiveRange: nil) == nil)
    }
}
