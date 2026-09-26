import AppKit
import Testing
@testable import FusenCore

/// Headless TextKit 1 stack, the same as NoteWindowController's (never put in a window).
@MainActor
final class ConcealedEditor {
    let storage = NSTextStorage()
    let layoutManager: ConcealingLayoutManager
    let textView: MarkdownTextView
    let styler = MarkdownStyler()
    let undo = UndoManager()
    private let undoProvider: UndoProvider

    init(_ text: String, width: CGFloat = 300) {
        layoutManager = ConcealingLayoutManager(theme: styler.theme)
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: width, height: 400), textContainer: container)
        textView.isVerticallyResizable = true
        textView.isRichText = false
        textView.allowsUndo = true
        undoProvider = UndoProvider(undo)
        textView.delegate = undoProvider
        textView.string = text
        restyle()
    }

    func restyle() {
        styler.restyle(storage)
        layoutManager.ensureLayout(for: layoutManager.textContainers[0])
    }

    /// Reveals the paragraphs containing `sub` (as if the caret were there), or nothing.
    func reveal(_ sub: String?) {
        let ns = storage.string as NSString
        layoutManager.setRevealedRanges(sub.map { [ns.paragraphRange(for: ns.range(of: $0))] } ?? [])
        layoutManager.ensureLayout(for: layoutManager.textContainers[0])
    }

    func index(of sub: String, offset: Int = 0) -> Int { (storage.string as NSString).range(of: sub).location + offset }

    func property(at charIndex: Int) -> NSLayoutManager.GlyphProperty {
        layoutManager.propertyForGlyph(at: layoutManager.glyphIndexForCharacter(at: charIndex))
    }

    func x(at charIndex: Int) -> CGFloat {
        let glyph = layoutManager.glyphIndexForCharacter(at: charIndex)
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
            + layoutManager.location(forGlyphAt: glyph).x
    }

    func png() -> Data? {
        textView.frame.size.height = max(layoutManager.usedRect(for: layoutManager.textContainers[0]).height + 20, 60)
        guard let rep = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) else { return nil }
        textView.cacheDisplay(in: textView.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

@MainActor
final class UndoProvider: NSObject, NSTextViewDelegate {
    let undo: UndoManager
    init(_ undo: UndoManager) { self.undo = undo }
    func undoManager(for view: NSTextView) -> UndoManager? { undo }
}

@MainActor
struct ConcealmentTests {
    @Test func syntaxIsHiddenExceptOnTheRevealedLine() {
        let e = ConcealedEditor("# 見出し\nこれは**太字**と[リンク](https://example.com)")
        e.reveal(nil)
        #expect(e.property(at: 0) == .null)                                  // "#"
        #expect(e.property(at: e.index(of: "**")) == .null)                  // "**"
        #expect(e.property(at: e.index(of: "](https")) == .null)             // link URL
        #expect(e.property(at: e.index(of: "太字")) != .null)
        #expect(e.property(at: e.index(of: "リンク")) != .null)
        e.reveal("これは")
        #expect(e.property(at: e.index(of: "**")) != .null)                  // editing line shows syntax
        #expect(e.property(at: 0) == .null)                                  // other lines stay concealed
    }

    @Test func bulletsBecomeNotionBullets() {
        let e = ConcealedEditor("- 一つ目\n\t- 入れ子")
        e.reveal(nil)
        let font = e.styler.theme.bodyFont
        var dash = UniChar(0x2D), dashGlyph = CGGlyph(0)
        CTFontGetGlyphsForCharacters(font as CTFont, &dash, &dashGlyph, 1)
        let glyph = e.layoutManager.cgGlyph(at: e.layoutManager.glyphIndexForCharacter(at: 0))
        #expect(glyph != dashGlyph)
        #expect(e.property(at: 0) != .null)
        e.reveal("一つ目")
        #expect(e.layoutManager.cgGlyph(at: e.layoutManager.glyphIndexForCharacter(at: 0)) == dashGlyph)
    }

    @Test func checkboxAndQuoteKeepTextInPlace() {
        let e = ConcealedEditor("- [ ] やること\n> 引用の文")
        e.reveal(nil)
        #expect(e.property(at: 0) == .controlCharacter)
        #expect(e.property(at: e.index(of: "[ ]")) == .null)
        let taskText = e.x(at: e.index(of: "やること"))
        let quoteText = e.x(at: e.index(of: "引用の文"))
        e.reveal("やること")
        e.reveal("やること") // idempotent
        #expect(abs(e.x(at: e.index(of: "やること")) - taskText) < 1.5)
        e.reveal("引用の文")
        #expect(abs(e.x(at: e.index(of: "引用の文")) - quoteText) < 1.5)
    }

    @Test func concealingDoesNotChangeLineHeights() {
        let text = "本文\n- [ ] やること\n- [x] 済み\n- 箇条書き\n> 引用\n1. 番号"
        let e = ConcealedEditor(text)
        func heights() -> [CGFloat] {
            let ns = e.storage.string as NSString
            var result: [CGFloat] = []
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { _, range, _, _ in
                let glyph = e.layoutManager.glyphIndexForCharacter(at: NSMaxRange(range) - 1)
                result.append(e.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).height)
            }
            return result
        }
        e.reveal(nil)
        let concealed = heights()
        e.layoutManager.concealsMarkdown = false
        e.layoutManager.ensureLayout(for: e.layoutManager.textContainers[0])
        let revealed = heights()
        #expect(zip(concealed, revealed).allSatisfy { abs($0 - $1) < 0.5 }, "\(concealed) vs \(revealed)")
        // Every line as tall as body text (the last line has no paragraph spacing after it).
        #expect(concealed.dropLast().allSatisfy { abs($0 - concealed[0]) < 0.5 }, "\(concealed)")
    }

    @Test func showingAllMarkdownRevealsEverything() {
        let e = ConcealedEditor("# 見出し\n**太字**")
        e.reveal(nil)
        #expect(e.property(at: 0) == .null)
        e.layoutManager.concealsMarkdown = false
        e.layoutManager.ensureLayout(for: e.layoutManager.textContainers[0])
        #expect(e.property(at: 0) != .null)
        #expect(e.property(at: e.index(of: "**")) != .null)
    }

    @Test func imeCompositionOnAConcealedNote() {
        let e = ConcealedEditor("# 見出し\n**太字**\n")
        func followCaret() {
            e.layoutManager.revealParagraphs(containing: e.textView.selectedRanges.map(\.rangeValue))
            e.layoutManager.ensureLayout(for: e.layoutManager.textContainers[0])
        }
        e.textView.setSelectedRange(NSRange(location: e.storage.length, length: 0)) // empty last line
        followCaret()
        e.textView.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        followCaret()
        #expect(e.property(at: e.index(of: "にほんご")) != .null) // the composing text is never hidden
        e.textView.insertText("日本語", replacementRange: e.textView.markedRange())
        followCaret()
        e.restyle()
        #expect(e.storage.string == "# 見出し\n**太字**\n日本語")
        #expect(e.property(at: 0) == .null) // other lines stay concealed
        #expect(e.property(at: e.index(of: "日本語")) != .null)

        // Composing a heading on the revealed line keeps its "# " visible until the caret leaves.
        e.textView.insertText("\n# ", replacementRange: e.textView.selectedRange())
        e.restyle()
        followCaret()
        #expect(e.property(at: e.index(of: "\n# ", offset: 1)) != .null)
    }

    @Test func tabAndShiftTabNestListItems() {
        let e = ConcealedEditor("- 項目")
        // Without an event loop every change would land in one undo group; group them like key presses.
        e.undo.groupsByEvent = false
        func keyPress(_ action: () -> Void) {
            e.undo.beginUndoGrouping()
            action()
            e.undo.endUndoGrouping()
        }
        e.textView.setSelectedRange(NSRange(location: e.storage.length, length: 0))
        keyPress { e.textView.insertTab(nil) }
        #expect(e.storage.string == "\t- 項目")
        #expect(e.textView.selectedRange().location == e.storage.length) // caret stays after the text
        keyPress { e.textView.insertBacktab(nil) }
        #expect(e.storage.string == "- 項目")
        e.undo.undo()
        #expect(e.storage.string == "\t- 項目")

        let plain = ConcealedEditor("本文")
        plain.textView.setSelectedRange(NSRange(location: 2, length: 0))
        plain.textView.insertTab(nil)
        #expect(plain.storage.string == "本文\t") // outside lists Tab types a tab
    }

    @Test func rendersWithoutCrashingAndDrawsCheckedBox() throws {
        let text = """
        # 今日のメモ
        **大事**なことは *ここ* に。`code` と [リンク](https://example.com)
        - [ ] 牛乳を買う
        - [x] パンを買う
        - 箇条書き
        \t- 入れ子
        1. 番号付き
        > 引用の文
        ---
        ```swift
        let x = 1
        ```
        """
        let e = ConcealedEditor(text)
        e.reveal(nil)
        let data = try #require(e.png())
        let rep = try #require(NSBitmapImageRep(data: data))
        // Somewhere there must be Notion-blue pixels from the checked checkbox.
        var blue = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   c.blueComponent > 0.75, c.redComponent < 0.3, c.greenComponent > 0.4 { blue += 1 }
            }
        }
        #expect(blue > 5)
        if let dir = ProcessInfo.processInfo.environment["MARKDOWN_STICKIES_RENDER_DIR"] {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("concealed.png"))
            e.layoutManager.concealsMarkdown = false
            try e.png()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("revealed.png"))
        }
    }
}
