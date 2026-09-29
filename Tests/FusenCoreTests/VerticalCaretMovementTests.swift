import AppKit
import Testing
@testable import FusenCore

@MainActor
struct VerticalCaretMovementTests {
    // Use the window's first responder and doCommand, as keyboard input does. Calling moveUp
    // directly on a window-less view does not reproduce TextKit's concealed-prefix hit testing.
    private func withEditor(_ text: String, width: CGFloat = 300, _ body: (ConcealedEditor) -> Void) {
        let e = ConcealedEditor(text, width: width)
        let window = NSWindow(contentRect: e.textView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = e.textView
        window.makeFirstResponder(e.textView)
        defer { window.orderOut(nil) }
        e.textView.textContainerInset = NSSize(width: 6, height: 8)
        e.restyle()
        body(e)
    }

    private func placeCaret(at location: Int, in e: ConcealedEditor) {
        // A click before the visible text uses downstream affinity. The convenience setter can
        // retain upstream affinity from the initial end-of-document selection instead.
        e.textView.setSelectedRange(NSRange(location: location, length: 0), affinity: .downstream, stillSelecting: false)
    }

    @Test(arguments: 1...6, ["上の行", "", "# 上の行", "## 上の行", "### 上の行", "**上の行**", "- 項目", "---", "上の行\n"])
    func upArrowLeavesTheStartOfAHeading(level: Int, above: String) {
        withEditor(above + "\n" + String(repeating: "#", count: level) + " 見出し\n下の行") { e in
            placeCaret(at: e.index(of: "見出し"), in: e)
            e.key { e.textView.doCommand(by: #selector(NSResponder.moveUp(_:))) }
            let previous = ConcealedEditing.line(at: above.utf16.count, in: e.storage)
            #expect(e.caret >= previous.range.location)
            #expect(e.caret <= previous.contentsEnd)
        }
    }

    @Test(arguments: 1...6) func downArrowStillLeavesTheStartOfAHeading(level: Int) {
        withEditor("上の行\n\n" + String(repeating: "#", count: level) + " 見出し\n下の行") { e in
            placeCaret(at: e.index(of: "見出し"), in: e)
            e.key { e.textView.moveDown(nil) }
            #expect(e.caret == e.index(of: "下の行"))
        }
    }

    @Test(arguments: 1...6) func shiftUpExtendsAboveAHeadingAndKeepsItsAnchor(level: Int) {
        withEditor("\n\n" + String(repeating: "#", count: level) + " 見出し\n下の行") { e in
            let start = e.index(of: "見出し")
            placeCaret(at: start, in: e)
            e.key { e.textView.doCommand(by: #selector(NSResponder.moveUpAndModifySelection(_:))) }
            #expect(e.textView.selectedRange() == NSRange(location: 1, length: start - 1))
            e.key { e.textView.doCommand(by: #selector(NSResponder.moveUpAndModifySelection(_:))) }
            #expect(e.textView.selectedRange() == NSRange(location: 0, length: start))
            e.key { e.textView.moveRightAndModifySelection(nil) }
            #expect(e.textView.selectedRange() == NSRange(location: 1, length: start - 1))
        }
    }

    @Test func upArrowTargetsTheLastWrappedLineAboveAHeading() {
        let above = String(repeating: "折り返す本文", count: 10)
        withEditor(above + "\n## 見出し", width: 160) { e in
            let lastGlyph = e.layoutManager.glyphIndexForCharacter(at: above.utf16.count)
            let expected = e.layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            #expect(expected.minY > 0)
            placeCaret(at: e.index(of: "見出し"), in: e)
            e.key { e.textView.doCommand(by: #selector(NSResponder.moveUp(_:))) }
            let actualGlyph = e.layoutManager.glyphIndexForCharacter(at: e.caret)
            #expect(e.layoutManager.lineFragmentRect(forGlyphAt: actualGlyph, effectiveRange: nil) == expected)
        }
    }

    @Test(arguments: ["見出し", "**見出し**", "`見出し`", "[見出し](https://example.com)"])
    func upArrowLeavesAHeadingWithInlineSyntax(content: String) {
        withEditor("\n## " + content + "\n下の行") { e in
            placeCaret(at: e.index(of: "見出し"), in: e)
            e.key { e.textView.doCommand(by: #selector(NSResponder.moveUp(_:))) }
            #expect(e.caret == 0)
        }
    }

    @Test(arguments: 1...6) func upArrowAtTheTopDoesNotEnterTheHiddenPrefix(level: Int) {
        withEditor(String(repeating: "#", count: level) + " 見出し\n本文") { e in
            let start = e.index(of: "見出し")
            placeCaret(at: start, in: e)
            e.key { e.textView.doCommand(by: #selector(NSResponder.moveUp(_:))) }
            #expect(e.caret == start)
            e.key { e.textView.doCommand(by: #selector(NSResponder.moveUpAndModifySelection(_:))) }
            #expect(e.textView.selectedRange() == NSRange(location: start, length: 0))
        }
    }

    @Test func upArrowWorksWithMarkdownShown() {
        withEditor("\n## 見出し\n本文") { e in
            e.setConceals(false)
            placeCaret(at: e.index(of: "##"), in: e)
            e.key { e.textView.doCommand(by: #selector(NSResponder.moveUp(_:))) }
            #expect(e.caret == 0)
        }
    }
}
