import AppKit
import Testing
@testable import FusenCore

/// ダークモード: a note follows its window's appearance — light (pastel paper) or dark (the same hue,
/// dark) — and everything on it stays readable.
@MainActor
struct DarkModeTests {
    private let light = MarkdownTheme()
    private let dark = MarkdownTheme.dark

    private func setDark(_ note: TestNote, _ isDark: Bool) {
        note.window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        note.controller.updateAppearance()
    }

    @Test func aNoteFollowsTheAppearanceOfItsWindow() throws {
        let note = TestNote("## 見出し\n- [/] 作業\n:::card orange A\n本文\n:::", color: .blue)
        let storage = try #require(note.textView.textStorage)
        let layout = try #require(note.textView.layoutManager as? ConcealingLayoutManager)
        func color(_ needle: String) -> NSColor? {
            storage.attribute(.foregroundColor, at: (storage.string as NSString).range(of: needle).location, effectiveRange: nil) as? NSColor
        }
        #expect(!note.controller.isDark && note.window.backgroundColor == NoteColor.blue.background)
        setDark(note, true)
        #expect(note.controller.isDark)
        #expect(note.window.backgroundColor == NoteColor.blue.darkBackground)
        #expect(layout.theme.isDark)
        #expect(color("見出し") == dark.textColor && color("作業") == dark.textColor)
        #expect(color("A\n") == CardColor.orange.tagText(isDark: true))
        #expect(note.textView.insertionPointColor == dark.textColor)
        #expect(note.textView.spinnerOverlay?.color == dark.doingColor)
        // What is typed next, and composed, is light too.
        #expect(note.textView.typingAttributes[.foregroundColor] as? NSColor == dark.textColor)
        try note.write("dark-note")
        // 強調表示 on the dark paper.
        note.controller.setFocus(.doing)
        #expect(note.window.backgroundColor == dark.focusPaper(NoteColor.blue.darkBackground))
        #expect(color("作業") == dark.focusInk)
        try note.write("dark-note-focus")
        note.controller.setFocus(nil)
        // And back.
        setDark(note, false)
        #expect(!note.controller.isDark && note.window.backgroundColor == NoteColor.blue.background)
        #expect(color("作業") == light.textColor && !layout.theme.isDark)
        #expect(note.textView.insertionPointColor == light.textColor)
    }

    @Test func everythingStaysReadableOnTheDarkPapers() throws {
        func luminance(_ c: NSColor) throws -> CGFloat {
            let c = try #require(c.usingColorSpace(.sRGB))
            func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        }
        func over(_ ink: NSColor, _ paper: NSColor) throws -> NSColor {
            let i = try #require(ink.usingColorSpace(.sRGB)), p = try #require(paper.usingColorSpace(.sRGB)), a = i.alphaComponent
            return NSColor(srgbRed: i.redComponent * a + p.redComponent * (1 - a), green: i.greenComponent * a + p.greenComponent * (1 - a),
                           blue: i.blueComponent * a + p.blueComponent * (1 - a), alpha: 1)
        }
        func contrast(_ ink: NSColor, on paper: NSColor) throws -> CGFloat {
            let (x, y) = (try luminance(try over(ink, paper)), try luminance(paper))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        for color in NoteColor.allCases {
            let paper = color.darkBackground
            #expect(try contrast(dark.textColor, on: paper) >= 9, "\(color)")
            #expect(try contrast(dark.mutedColor, on: paper) >= 3, "\(color)")          // done to-dos
            #expect(try contrast(dark.inlineCodeColor, on: try over(dark.codeBackground, paper)) >= 4.5, "\(color)")
            #expect(try contrast(dark.doingColor, on: paper) >= 3 && contrast(dark.waitingColor, on: paper) >= 3, "\(color)")
            // 強調表示, as on the pastel papers.
            let shaded = dark.focusPaper(paper)
            let lit = try contrast(dark.focusInk, on: shaded), other = try contrast(dark.focusInk.withAlphaComponent(dark.focusFade), on: shaded)
            #expect(other >= 2.5 && lit >= 13 && lit / other >= 5, "\(color): \(lit) / \(other)")
            // A card is a little lighter than the paper, so that it stands on it (as on the pastel papers,
            // where it is a little lighter too).
            for card in CardColor.allCases {
                #expect(try luminance(card.frame(isDark: true)) > luminance(paper), "\(card) on \(color)")
            }
        }
        for card in CardColor.allCases {
            #expect(try contrast(card.tagText(isDark: true), on: card.tag(isDark: true)) >= 4.5, "\(card)")
            #expect(try contrast(dark.textColor, on: card.frame(isDark: true)) >= 7, "\(card)")
        }
    }
}
