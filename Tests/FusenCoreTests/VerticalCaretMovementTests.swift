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

    // MARK: Cards

    /// The line each press of ↓ (↑) puts the caret on, as the keyboard does it.
    private func lines(_ e: ConcealedEditor, down: Bool, presses: Int) -> [Int] {
        (0..<presses).map { _ in
            e.key { e.textView.doCommand(by: down ? #selector(NSResponder.moveDown(_:)) : #selector(NSResponder.moveUp(_:))) }
            return ConcealedEditing.line(at: e.caret, in: e.storage).range.location
        }
    }

    @Test(arguments: [":::card orange 名前", ":::card blue ", ":::card"], ["おわり", "", ":::card red B\n別\n:::"])
    func arrowsGoThroughACardAndPastItsClosingLine(open: String, after: String) {
        withEditor("本文\n" + open + "\n- [/] 一行目\n二行目\n:::\n" + after) { e in
            let title = e.index(of: open), first = e.index(of: "- [/]"), second = e.index(of: "二行目")
            let below = e.index(of: "二行目\n:::\n") + ("二行目\n:::\n" as NSString).length
            placeCaret(at: 0, in: e)
            #expect(lines(e, down: true, presses: 4) == [title, first, second, below])
            #expect(lines(e, down: false, presses: 4) == [second, first, title, 0])
            // Never on a hidden line, and never inside the opening line's syntax.
            for start in [e.index(of: "一行目") + 1, below] {
                for down in [true, false] {
                    placeCaret(at: start, in: e)
                    for _ in 0..<4 {
                        e.key { e.textView.doCommand(by: down ? #selector(NSResponder.moveDown(_:)) : #selector(NSResponder.moveUp(_:))) }
                        let line = ConcealedEditing.line(at: e.caret, in: e.storage)
                        #expect(line.kind != .cardClose, "from \(start), down \(down)")
                        #expect(e.caret >= line.contentStart, "from \(start), down \(down)")
                    }
                }
            }
        }
    }

    @Test func arrowsKeepTheirColumnAcrossACard() {
        withEditor("あいうえおかきくけこ\n:::card orange 名前\n一二三四五六七八九十\n:::\nさしすせそたちつてと") { e in
            let start = e.index(of: "えお")
            placeCaret(at: start, in: e)
            let x = e.x(at: start)
            _ = lines(e, down: true, presses: 3)
            #expect(ConcealedEditing.line(at: e.caret, in: e.storage).range.location == e.index(of: "さしすせそ"))
            #expect(abs(e.x(at: e.caret) - x) < 8)   // the same place across, not the start or the end of the line
            _ = lines(e, down: false, presses: 1)
            #expect(ConcealedEditing.line(at: e.caret, in: e.storage).range.location == e.index(of: "一二三"))
            #expect(e.caret > e.index(of: "一二三") && e.caret < e.index(of: "九十"))
        }
    }

    @Test func shiftDownIntoACardSelectsAllOfIt() {
        withEditor("本文\n:::card orange 名前\n中身\n:::\nおわり") { e in
            placeCaret(at: 0, in: e)
            e.key { e.textView.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:))) }
            #expect(e.textView.selectedRange() == NSRange(location: 0, length: 3))    // the line above the card
            e.key { e.textView.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:))) }
            // Reaching into the card takes the card: up to the line after it.
            #expect(e.textView.selectedRange() == NSRange(location: 0, length: e.index(of: "おわり")))
            e.key { e.textView.deleteBackward(nil) }
            #expect(e.text == "おわり")
        }
        // Deleting the line above a card, with its line break, leaves the card as it is.
        withEditor("本文\n:::card orange 名前\n中身\n:::\nおわり") { e in
            e.textView.setSelectedRange(NSRange(location: 0, length: 3))
            e.key { e.textView.deleteBackward(nil) }
            #expect(e.text == ":::card orange 名前\n中身\n:::\nおわり")
            #expect(e.layoutManager.cardGeometries().count == 1)
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

    @Test(arguments: [
        "---", "   ---", "- - -", "", "本文", "## 見出し", "## ",
        "- 項目", "1. 項目", "123. 項目", "- [ ] 項目", "- [x] 項目", "\t- 項目", "- ", "- [ ] ",
        "> 引用", "> ", "> > 引用", "**太字**", "*斜体*", "~~取消~~", "`code`",
        "[リンク](https://example.com)", "\\# 本文", "```swift\nlet value = 1\n```"
    ], [false, true])
    func upArrowLeavesEveryBlock(block: String, atEnd: Bool) {
        for extend in [false, true] {
            let text = "先頭の本文\n\n" + block + (atEnd ? "" : "\n下の行")
            withEditor(text) { e in
                let line = ConcealedEditing.line(at: "先頭の本文\n\n".utf16.count, in: e.storage)
                let visibleStart = ConcealedEditing.visibleContentStart(of: line, in: e.storage)
                let start = ConcealedEditing.adjustCaret(visibleStart, from: visibleStart, in: e.storage)
                placeCaret(at: start, in: e)
                e.key {
                    e.textView.doCommand(by: extend ? #selector(NSResponder.moveUpAndModifySelection(_:))
                                                  : #selector(NSResponder.moveUp(_:)))
                }
                let previous = ConcealedEditing.line(at: line.range.location - 1, in: e.storage)
                #expect(e.caret >= previous.range.location && e.caret <= previous.contentsEnd,
                        "block=\(block), atEnd=\(atEnd), shift=\(extend), selection=\(e.textView.selectedRange())")
                if extend { #expect(NSMaxRange(e.textView.selectedRange()) == start) }
                #expect(e.text == text)
            }
        }
    }

    @Test(arguments: [
        "---", "## 見出し", "- 項目", "1. 項目", "- [ ] 項目", "- [x] 項目", "\t- 項目", "> 引用",
        "**太字**", "*斜体*", "~~取消~~", "`code`", "[リンク](https://example.com)", "\\# 本文",
        "本文**太字**続き", "絵文字👩‍💻とe\u{301}", "```swift"
    ], ["up", "down", "shift-up", "shift-down"])
    func verticalArrowsWorkFromEveryInsertionPoint(block: String, command: String) async {
        let down = command.hasSuffix("down")
        let extend = command.hasPrefix("shift")
        let prefix = "上の行\n\n"
        let text = prefix + block + "\n\n下の行"
        let offsets = block.indices.map { $0.utf16Offset(in: block) } + [block.utf16.count]
        let parsed = ConcealedEditor(text)
        let starts = Set(offsets.map { offset in
            let raw = prefix.utf16.count + offset
            return ConcealedEditing.adjustCaret(raw, from: raw, in: parsed.storage)
        }).sorted()
        for start in starts {
            withEditor(text) { e in
                placeCaret(at: start, in: e)
                e.key {
                    let up = extend ? #selector(NSResponder.moveUpAndModifySelection(_:)) : #selector(NSResponder.moveUp(_:))
                    let down = extend ? #selector(NSResponder.moveDownAndModifySelection(_:)) : #selector(NSResponder.moveDown(_:))
                    e.textView.doCommand(by: command.hasSuffix("down") ? down : up)
                }
                let expected = down ? prefix.utf16.count + block.utf16.count + 1 : prefix.utf16.count - 1
                let moving = extend && down ? NSMaxRange(e.textView.selectedRange()) : e.caret
                #expect(moving == expected, "block=\(block), command=\(command), start=\(start), selection=\(e.textView.selectedRange())")
                if extend {
                    #expect((down ? e.caret : NSMaxRange(e.textView.selectedRange())) == start)
                }
                #expect(e.text == text)
            }
            // Let the app's asynchronous timer tests run between window fixtures.
            await Task.yield()
        }
    }

    @Test func repeatedUpCrossesDividersAndCodeLines() {
        withEditor("本文\n\n---\n\n```swift\nlet value = 1\n```\n\n---\n末尾") { e in
            var line = ConcealedEditing.line(at: e.index(of: "末尾"), in: e.storage)
            placeCaret(at: line.range.location, in: e)
            while line.range.location > 0 {
                let above = ConcealedEditing.line(at: line.range.location - 1, in: e.storage)
                e.key { e.textView.doCommand(by: #selector(NSResponder.moveUp(_:))) }
                #expect(e.caret >= above.range.location && e.caret <= above.contentsEnd,
                        "line=\(line.range), above=\(above.range), caret=\(e.caret)")
                line = above
            }
        }
    }

    @Test(arguments: ["## ", "- ", "> ", "**", ""], [false, true])
    func verticalArrowsMoveOneWrappedRow(prefix: String, down: Bool) {
        let text = "先頭\n" + prefix + String(repeating: "折り返す本文", count: 12) + (prefix == "**" ? "**" : "") + "\n末尾"
        withEditor(text, width: 160) { e in
            var rows: [(glyphs: NSRange, characters: NSRange)] = []
            e.layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: e.layoutManager.numberOfGlyphs)) {
                _, _, _, glyphs, _ in
                rows.append((glyphs, e.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)))
            }
            #expect(rows.count > 4)
            let last = e.index(of: "末尾")
            placeCaret(at: down ? 0 : last, in: e)
            let targets = down ? Array(rows.indices.dropFirst()) : Array(rows.indices.dropLast().reversed())
            for index in targets {
                e.key { e.textView.doCommand(by: down ? #selector(NSResponder.moveDown(_:)) : #selector(NSResponder.moveUp(_:))) }
                let characters = rows[index].characters
                #expect(e.caret >= characters.location && e.caret <= NSMaxRange(characters),
                        "prefix=\(prefix), down=\(down), row=\(index), caret=\(e.caret)")
            }
        }
    }

    @Test func upwardCorrectionKeepsTheColumnAcrossABlankLine() {
        withEditor("abcdefghijklmnop\n\n**abcdefghijklmnop**") { e in
            let start = e.index(of: "**") + 10
            let x = e.x(at: start)
            let top = e.layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            let point = NSPoint(x: x + e.textView.textContainerOrigin.x, y: top.midY + e.textView.textContainerOrigin.y)
            let expected = e.textView.characterIndexForInsertion(at: point)
            #expect(expected > 0)
            placeCaret(at: start, in: e)
            e.key { e.textView.doCommand(by: #selector(NSResponder.moveUp(_:))) }
            #expect(e.caret == e.index(of: "\n\n") + 1)
            e.key { e.textView.doCommand(by: #selector(NSResponder.moveUp(_:))) }
            #expect(e.caret == expected)
        }
    }
}
