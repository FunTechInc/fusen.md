import AppKit
import Testing
@testable import FusenCore

/// Headless TextKit 1 stack, the same as NoteWindowController's (never put in a window). Its delegate
/// does what the note's does: restyles after every edit and keeps the caret out of concealed syntax.
@MainActor
final class ConcealedEditor {
    let storage = NSTextStorage()
    let layoutManager: ConcealingLayoutManager
    let textView: MarkdownTextView
    let styler = MarkdownStyler()
    let undo = UndoManager()
    private let editorDelegate: EditorDelegate

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
        editorDelegate = EditorDelegate(undo: undo, styler: styler)
        textView.delegate = editorDelegate
        textView.string = text
        restyle()
    }

    var text: String { storage.string }
    var caret: Int { textView.selectedRange().location }

    func restyle() {
        styler.restyle(storage)
        layoutManager.ensureLayout(for: layoutManager.textContainers[0])
    }

    /// Shows the raw Markdown (「Markdown記号をすべて表示」) or conceals it.
    func setConceals(_ conceals: Bool) {
        layoutManager.concealsMarkdown = conceals
        textView.concealsMarkdown = conceals
        layoutManager.ensureLayout(for: layoutManager.textContainers[0])
    }

    /// Puts the caret at `location`, as a click would (through the selection delegate).
    func click(_ location: Int) { textView.setSelectedRange(NSRange(location: location, length: 0)) }

    func index(of sub: String, offset: Int = 0) -> Int { (storage.string as NSString).range(of: sub).location + offset }

    func property(at charIndex: Int) -> NSLayoutManager.GlyphProperty {
        layoutManager.propertyForGlyph(at: layoutManager.glyphIndexForCharacter(at: charIndex))
    }

    func x(at charIndex: Int) -> CGFloat {
        let glyph = layoutManager.glyphIndexForCharacter(at: charIndex)
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
            + layoutManager.location(forGlyphAt: glyph).x
    }

    /// Groups the edits of `action` into one undo step, like one key press.
    func key(_ action: () -> Void) {
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        action()
        undo.endUndoGrouping()
        layoutManager.ensureLayout(for: layoutManager.textContainers[0])
    }

    func type(_ string: String) {
        for character in string {
            key { textView.insertText(String(character), replacementRange: textView.selectedRange()) }
        }
    }

    func png() -> Data? {
        textView.frame.size.height = max(layoutManager.usedRect(for: layoutManager.textContainers[0]).height + 20, 60)
        guard let rep = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) else { return nil }
        textView.cacheDisplay(in: textView.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

@MainActor
final class EditorDelegate: NSObject, NSTextViewDelegate {
    let undo: UndoManager
    let styler: MarkdownStyler
    init(undo: UndoManager, styler: MarkdownStyler) {
        self.undo = undo
        self.styler = styler
    }
    func undoManager(for view: NSTextView) -> UndoManager? { undo }
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? MarkdownTextView, !textView.hasMarkedText() else { return }
        NoteWindowController.restyle(textView, with: styler)
    }
    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRanges old: [NSValue],
                  toCharacterRanges new: [NSValue]) -> [NSValue] {
        guard (textView as? MarkdownTextView)?.concealsMarkdown == true, !textView.hasMarkedText(),
              let storage = textView.textStorage else { return new }
        return NoteWindowController.adjusted(new, from: old, in: storage)
    }
}

@MainActor
struct ConcealmentTests {
    let theme = MarkdownTheme()

    // MARK: Drawing

    @Test func syntaxIsHiddenAlsoOnTheLineBeingEdited() {
        let e = ConcealedEditor("# 見出し\nこれは**太字**と[リンク](https://example.com)")
        e.click(e.index(of: "太字")) // the caret on that line: still concealed, as in Notion
        #expect(e.property(at: 0) == .null)                                  // "#"
        #expect(e.property(at: e.index(of: "**")) == .null)                  // "**"
        #expect(e.property(at: e.index(of: "](https")) == .null)             // link URL
        #expect(e.property(at: e.index(of: "太字")) != .null)
        e.setConceals(false)
        #expect(e.property(at: 0) != .null)
        #expect(e.property(at: e.index(of: "**")) != .null)
    }

    @Test func listTextStartsInNotionsColumn() {
        let e = ConcealedEditor("- 箇条書き\n1. 番号付き\n- [ ] やること\n\t- 入れ子")
        let column = theme.listColumn
        let origin = e.x(at: 0)
        #expect(abs(e.x(at: e.index(of: "箇条書き")) - origin - column) < 1)
        #expect(abs(e.x(at: e.index(of: "番号付き")) - origin - column) < 1)
        #expect(abs(e.x(at: e.index(of: "やること")) - origin - column) < 1)
        #expect(abs(e.x(at: e.index(of: "入れ子")) - origin - 2 * column) < 1) // nested one column deeper
        #expect(e.property(at: 0) == .controlCharacter)                      // "-" is the bullet's box
        #expect(e.property(at: 1) == .null)                                  // the space after it
        // The same place with the Markdown shown.
        e.setConceals(false)
        #expect(abs(e.x(at: e.index(of: "箇条書き")) - origin - column) < 1)
    }

    @Test func quoteTextFollowsTheBar() {
        let e = ConcealedEditor("> 引用の文")
        #expect(e.property(at: 0) == .controlCharacter)
        #expect(abs(e.x(at: e.index(of: "引用")) - e.x(at: 0) - theme.quoteColumn) < 1)
        let font = e.storage.attribute(.font, at: e.index(of: "引用"), effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == theme.fontSize * theme.quoteScale)
    }

    @Test func concealingDoesNotChangeLineHeights() {
        let e = ConcealedEditor("本文\n- [ ] やること\n- [x] 済み\n- 箇条書き\n1. 番号\n末尾")
        func heights() -> [CGFloat] {
            let ns = e.storage.string as NSString
            var result: [CGFloat] = []
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { _, range, _, _ in
                let glyph = e.layoutManager.glyphIndexForCharacter(at: NSMaxRange(range) - 1)
                result.append(e.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).height)
            }
            return result
        }
        let concealed = heights()
        e.setConceals(false)
        #expect(zip(concealed, heights()).allSatisfy { abs($0 - $1) < 0.5 })
        // Every line as tall as body text (the last line has no paragraph spacing after it).
        #expect(concealed.dropLast().allSatisfy { abs($0 - concealed[0]) < 0.5 }, "\(concealed)")
    }

    @Test func escapeBackslashesAreConcealed() {
        let e = ConcealedEditor("2\\*3\\*4\n次の行")
        #expect(e.property(at: 1) == .null)  // "\" hidden: shows 2*3*4
        #expect(e.property(at: 2) != .null)  // "*" shown
        e.setConceals(false)
        #expect(e.property(at: 1) != .null)
    }

    @Test func rendersNotionLikeAndDrawsTheBoxes() throws {
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
        let data = try #require(e.png())
        let rep = try #require(NSBitmapImageRep(data: data))
        var blue = 0, bulletInk = 0
        let scale = CGFloat(rep.pixelsWide) / e.textView.bounds.width
        let bulletY = e.layoutManager.lineFragmentRect(forGlyphAt: e.layoutManager.glyphIndexForCharacter(at: e.index(of: "箇条書き")),
                                                       effectiveRange: nil).midY
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.blueComponent > 0.75, c.redComponent < 0.3, c.greenComponent > 0.4 { blue += 1 }
                // Dark pixels of the bullet, left of the text, on the bullet's line.
                if abs(CGFloat(y) / scale - bulletY - e.textView.textContainerInset.height) < 4,
                   CGFloat(x) / scale < e.x(at: e.index(of: "箇条書き")) - 3, c.brightnessComponent < 0.4 { bulletInk += 1 }
            }
        }
        #expect(blue > 5)        // the checked checkbox
        #expect(bulletInk > 0)   // the bullet is drawn
        if let dir = ProcessInfo.processInfo.environment["MARKDOWN_STICKIES_RENDER_DIR"] {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("concealed.png"))
            e.setConceals(false)
            try e.png()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("revealed.png"))
        }
    }

    @Test func scrollBarIsStickiesSmallSize() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        NoteWindowController.configureScroller(of: scrollView)
        #expect(scrollView.verticalScroller?.controlSize == .small)
        #expect(scrollView.autohidesScrollers)
    }

    // MARK: Converting as you type

    @Test func markersBecomeBlocksOnlyAfterASpace() {
        let e = ConcealedEditor("")
        e.type("##")
        #expect(e.property(at: 0) != .null)                // "##" alone is still text
        e.type(" 見出し")
        #expect(e.property(at: 0) == .null)                // now an h2; its "## " disappears
        #expect(e.caret == e.text.utf16.count)
        let line = ConcealedEditing.line(at: 0, in: e.storage)
        #expect(line.kind == .h2)
    }

    @Test func threeDashesMakeADividerAndMoveToTheNextLine() {
        let e = ConcealedEditor("")
        e.type("---")
        #expect(e.text == "---\n")
        #expect(e.caret == 4)
        #expect(ConcealedEditing.line(at: 0, in: e.storage).kind == .rule)
        e.type("次")
        #expect(e.text == "---\n次")
    }

    @Test func typingOnADividerStartsANewLine() {
        let e = ConcealedEditor("---")
        e.click(3)
        e.type("x")
        #expect(e.text == "---\nx")
    }

    // MARK: Caret

    @Test func theCaretNeverStopsInHiddenSyntax() {
        let e = ConcealedEditor("前\n## 見出し\n本文")
        e.click(e.index(of: "## ") + 1)                     // inside "## "
        #expect(e.caret == e.index(of: "見出し"))            // → the heading's text
        // Moving left out of the heading goes to the end of the line above.
        e.key { e.textView.moveLeft(nil) }
        #expect(e.caret == e.index(of: "\n## "))
        e.key { e.textView.moveRight(nil) }
        #expect(e.caret == e.index(of: "見出し"))
    }

    @Test func arrowKeysCrossHiddenDelimitersInOneStep() {
        let e = ConcealedEditor("a**bold**c")
        e.click(1)                                          // after "a"
        e.key { e.textView.moveRight(nil) }
        #expect(e.caret == 4)                               // after "b": one visible character, not into "**"
        e.key { e.textView.moveLeft(nil) }
        #expect(e.caret == 3)                               // before "b" (inside the bold)
        e.key { e.textView.moveLeft(nil) }
        #expect(e.caret == 0)                               // before "a": one visible step again
        e.click(8)                                          // inside the closing "**"
        #expect(e.caret == 7 || e.caret == 9)
    }

    // MARK: Deleting

    @Test func backspaceAtTheStartOfABlockMakesItText() {
        let e = ConcealedEditor("## 見出し")
        e.click(e.index(of: "見出し"))
        e.key { e.textView.deleteBackward(nil) }
        #expect(e.text == "見出し")
        let list = ConcealedEditor("\t- 項目")
        list.click(list.index(of: "項目"))
        list.key { list.textView.deleteBackward(nil) }
        #expect(list.text == "\t項目")                    // the nesting stays
        list.undo.undo()
        #expect(list.text == "\t- 項目")
    }

    @Test func backspaceDeletesWhatIsVisible() {
        let e = ConcealedEditor("x **bold**")
        e.click(e.text.utf16.count)                          // after the hidden closing "**"
        e.key { e.textView.deleteBackward(nil) }
        #expect(e.text == "x **bol**")                      // "d" goes, the bold stays
        let single = ConcealedEditor("x **a** y")
        single.click(single.index(of: "** y") + 2)           // after the closing "**"
        single.key { single.textView.deleteBackward(nil) }
        #expect(single.text == "x  y")                      // no empty "****" is left
        let escaped = ConcealedEditor("2\\*3")
        escaped.click(3)
        escaped.key { escaped.textView.deleteBackward(nil) }
        #expect(escaped.text == "23")                       // the "*" with its hidden backslash
    }

    @Test func dividersAreDeletedWhole() {
        let e = ConcealedEditor("上\n---\n下")
        e.click(e.index(of: "下"))
        e.key { e.textView.deleteBackward(nil) }
        #expect(e.text == "上\n下")
        let f = ConcealedEditor("上\n---\n下")
        f.click(1)
        f.key { f.textView.deleteForward(nil) }
        #expect(f.text == "上\n下")
    }

    @Test func deleteAtTheEndOfALineJoinsTheNextBlocksText() {
        let e = ConcealedEditor("本文\n- 項目")
        e.click(2)
        e.key { e.textView.deleteForward(nil) }
        #expect(e.text == "本文項目")
    }

    // MARK: Return

    @Test func returnAtTheStartOfAHeadingAddsALineAbove() {
        let e = ConcealedEditor("## 見出し")
        e.click(e.index(of: "見出し"))
        e.key { e.textView.insertNewline(nil) }
        #expect(e.text == "\n## 見出し")
        #expect(e.caret == e.index(of: "見出し"))
    }

    // MARK: Formatting

    @Test func formattingShortcutsWrapAndUnwrap() {
        let e = ConcealedEditor("大事な点")
        e.textView.setSelectedRange(NSRange(location: 0, length: 2))
        e.key { e.textView.toggleBold(nil) }
        #expect(e.text == "**大事**な点")
        #expect(e.textView.selectedRange() == NSRange(location: 2, length: 2))
        e.key { e.textView.toggleItalic(nil) }
        #expect(e.text == "***大事***な点")
        e.key { e.textView.toggleBold(nil) }
        #expect(e.text == "*大事*な点")
        e.key { e.textView.toggleItalic(nil) }
        #expect(e.text == "大事な点")
        e.textView.setSelectedRange(NSRange(location: 2, length: 2))
        e.key { e.textView.toggleInlineCode(nil) }
        e.key { e.textView.toggleStrikethrough(nil) }
        #expect(e.text == "大事~~`な点`~~" || e.text == "大事`~~な点~~`")
        e.undo.undo()
        e.undo.undo()
        #expect(e.text == "大事な点")
    }

    @Test func insertingADivider() {
        let e = ConcealedEditor("段落")
        e.click(1)
        e.key { e.textView.insertDivider(nil) }
        #expect(e.text == "段落\n---\n")
        #expect(e.caret == e.text.utf16.count)
        let empty = ConcealedEditor("")
        empty.key { empty.textView.insertDivider(nil) }
        #expect(empty.text == "---\n")
    }

    // MARK: IME

    @Test func imeCompositionOnAConcealedNote() {
        let e = ConcealedEditor("# 見出し\n**太字**\n")
        e.click(e.storage.length)
        e.textView.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        e.layoutManager.ensureLayout(for: e.layoutManager.textContainers[0])
        #expect(e.property(at: e.index(of: "にほんご")) != .null) // the composing text is never hidden
        e.textView.insertText("日本語", replacementRange: e.textView.markedRange())
        #expect(e.text == "# 見出し\n**太字**\n日本語")
        #expect(e.property(at: 0) == .null)
        // Composing right after "## " goes into the heading.
        let h = ConcealedEditor("")
        h.type("## ")
        h.textView.setMarkedText("みだし", selectedRange: NSRange(location: 3, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        h.textView.insertText("見出し", replacementRange: h.textView.markedRange())
        h.restyle()
        #expect(h.text == "## 見出し")
        #expect(ConcealedEditing.line(at: 0, in: h.storage).kind == .h2)
    }

    @Test func tabAndShiftTabNestListItems() {
        let e = ConcealedEditor("- 項目")
        e.click(e.text.utf16.count)
        e.key { e.textView.insertTab(nil) }
        #expect(e.text == "\t- 項目")
        #expect(e.caret == e.text.utf16.count)
        e.key { e.textView.insertBacktab(nil) }
        #expect(e.text == "- 項目")
        e.undo.undo()
        #expect(e.text == "\t- 項目")
        let plain = ConcealedEditor("本文")
        plain.click(2)
        plain.key { plain.textView.insertTab(nil) }
        #expect(plain.text == "本文\t") // outside lists Tab types a tab
    }
}
