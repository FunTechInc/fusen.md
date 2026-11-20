import AppKit
import Testing
@testable import FusenCore

/// A note window that is never put on screen, with its own notes folder.
@MainActor
final class TestNote {
    let root = makeTempDirectory()
    let store: NoteStore
    let controller: NoteWindowController
    var meta: NoteMeta { controller.meta }
    var textView: MarkdownTextView { controller.textView }
    var window: NSWindow { controller.window! }

    init(_ body: String, size: CGSize = CGSize(width: 280, height: 240), focus: NoteFocus? = nil) {
        store = NoteStore(rootURL: root)
        store.load()
        var meta = NoteMeta(frame: CGRect(origin: CGPoint(x: 100, y: 100), size: size))
        meta.focus = focus
        store.add(meta, body: body)
        controller = NoteWindowController(meta: meta, body: body, store: store,
                                          history: HistoryStore(rootURL: store.historyURL),
                                          styler: MarkdownStyler(), concealsMarkdown: true)
    }

    /// The whole window as it would be drawn, title bar included: the paper, the visible text, the rings
    /// of the to-dos in progress (which are layers, so they are drawn here as they stand) and the title bar.
    func png() -> Data? {
        guard let frameView = window.contentView?.superview else { return nil }
        frameView.layoutSubtreeIfNeeded()
        let size = frameView.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size // before the context is made: two pixels per point
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        window.backgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()

        let visible = textView.visibleRect
        if let text = textView.bitmapImageRepForCachingDisplay(in: visible) {
            textView.cacheDisplay(in: visible, to: text)
            text.draw(in: textView.convert(visible, to: frameView), from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
        }
        textView.updateTaskSpinners()
        for ring in textView.spinnerOverlay?.rings ?? [] {
            let rect = textView.convert(ring.frame, to: frameView)
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: 0, y: rect.minY + rect.maxY) // the icons are drawn y-down
            context.cgContext.scaleBy(x: 1, y: -1)
            TaskSignalIcon.draw(.doing, in: rect, theme: MarkdownTheme(), alpha: CGFloat(ring.opacity))
            context.cgContext.restoreGState()
        }
        if let chrome = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: chrome)
            chrome.draw(in: frameView.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        return rep.representation(using: .png, properties: [:])
    }

    func write(_ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["MARKDOWN_STICKIES_RENDER_DIR"] else { return }
        try png()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
}

/// 強調表示: only the to-dos in progress, or only the waiting ones, keep their look.
@MainActor
struct NoteFocusTests {
    private let text = "本文\n- [/] 進行中\n- [>] 待機\n- 箇条書き\n> 引用"
    private let theme = MarkdownTheme()

    private func alpha(_ storage: NSTextStorage, _ index: Int) -> CGFloat {
        (storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)?.alphaComponent ?? -1
    }

    @Test func onlyTheEmphasizedToDosKeepTheirLook() {
        let e = ConcealedEditor(text)
        e.styler.restyle(e.storage, focus: .doing)
        let doing = e.index(of: "進行中"), waiting = e.index(of: "待機")
        // The to-do in progress: white, for the darkened paper.
        #expect(e.storage.attribute(.foregroundColor, at: doing, effectiveRange: nil) as? NSColor == theme.focusInk)
        #expect(e.storage.attribute(.mdInk, at: doing, effectiveRange: nil) as? NSColor == theme.focusInk)
        #expect(e.storage.attribute(.mdFade, at: doing, effectiveRange: nil) == nil)
        // Everything else: faded.
        for index in [0, waiting, e.index(of: "箇条書き"), e.index(of: "引用")] {
            #expect(e.storage.attribute(.mdFade, at: index, effectiveRange: nil) as? CGFloat == theme.focusFade, "\(index)")
            #expect(abs(alpha(e.storage, index) - theme.focusFade) < 0.001, "\(index)")
            #expect(e.storage.attribute(.mdInk, at: index, effectiveRange: nil) == nil, "\(index)")
        }
        // The other emphasis.
        e.styler.restyle(e.storage, focus: .waiting)
        #expect(e.storage.attribute(.mdInk, at: waiting, effectiveRange: nil) != nil)
        #expect(e.storage.attribute(.mdFade, at: doing, effectiveRange: nil) as? CGFloat == theme.focusFade)
        // Off: as always.
        e.styler.restyle(e.storage)
        #expect(e.storage.attribute(.mdFade, at: 0, effectiveRange: nil) == nil)
        #expect(e.storage.attribute(.mdInk, at: waiting, effectiveRange: nil) == nil)
        #expect(alpha(e.storage, 0) == 1)
    }

    @Test func theEmphasisIsSavedWithTheNote() throws {
        var meta = NoteMeta(frame: CGRect(x: 1, y: 2, width: 280, height: 240))
        meta.focus = .waiting
        let data = try JSONEncoder().encode(meta)
        #expect(try JSONDecoder().decode(NoteMeta.self, from: data).focus == .waiting)
        // A note saved before the key existed, and one saved by a later version with another value.
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["focus"] = nil
        #expect(try JSONDecoder().decode(NoteMeta.self, from: JSONSerialization.data(withJSONObject: json)).focus == nil)
        json["focus"] = "later"
        #expect(try JSONDecoder().decode(NoteMeta.self, from: JSONSerialization.data(withJSONObject: json)).focus == nil)
    }

    @Test func turningItOnDarkensThePaperAndIsSaved() throws {
        let note = TestNote(text)
        let paper = note.meta.color.background
        #expect(note.window.backgroundColor == paper)
        note.controller.setFocus(.doing)
        #expect(note.window.backgroundColor == theme.focusPaper(paper))
        #expect(note.textView.insertionPointColor == theme.focusInk)
        #expect(note.textView.textStorage?.attribute(.mdFade, at: 0, effectiveRange: nil) as? CGFloat == theme.focusFade)
        #expect(note.store.meta(note.meta.id)?.focus == .doing)
        try note.write("focus-doing")
        // The same button again turns it off; the other one switches.
        let item = NSMenuItem()
        item.tag = 0
        note.controller.toggleFocus(item)
        #expect(note.meta.focus == nil)
        #expect(note.window.backgroundColor == paper)
        #expect(note.textView.insertionPointColor == theme.textColor)
        try note.write("focus-off")
        item.tag = 1
        note.controller.toggleFocus(item)
        #expect(note.meta.focus == .waiting)
        note.controller.toggleFocus(item)
        #expect(note.store.meta(note.meta.id)?.focus == nil)
    }

    @Test func aNoteOpensWithItsEmphasis() throws {
        let note = TestNote(text, focus: .waiting)
        #expect(note.window.backgroundColor == theme.focusPaper(note.meta.color.background))
        #expect(note.textView.textStorage?.attribute(.mdInk, at: (text as NSString).range(of: "待機").location,
                                                     effectiveRange: nil) != nil)
        try note.write("focus-waiting")
    }

    @Test func textTypedWhileItIsOnIsStyledToo() {
        let note = TestNote("- [/] 進行中\n", focus: .doing)
        note.textView.setSelectedRange(NSRange(location: (note.textView.string as NSString).length, length: 0))
        note.textView.insertText("本文", replacementRange: note.textView.selectedRange())
        let storage = note.textView.textStorage!
        #expect(storage.attribute(.mdFade, at: storage.length - 1, effectiveRange: nil) as? CGFloat == theme.focusFade)
        #expect(storage.attribute(.mdInk, at: 8, effectiveRange: nil) != nil)
    }

    @Test func theButtonsAreOnlyOnNotesWithSignals() {
        let plain = TestNote("本文\n- [ ] 未着手")
        let accessory = plain.window.titlebarAccessoryViewControllers.first
        #expect(accessory?.isHidden == true)
        // A signal appears: the buttons do too.
        plain.textView.setSelectedRange(NSRange(location: 0, length: 0))
        plain.textView.insertText("- [/] 進行中\n", replacementRange: NSRange(location: 0, length: 0))
        #expect(accessory?.isHidden == false)
        // While an emphasis is on they stay, so that it can be turned off.
        plain.controller.setFocus(.doing)
        plain.textView.replaceAllText(with: "本文", actionName: "テスト")
        #expect(accessory?.isHidden == false)
        plain.controller.setFocus(nil)
        #expect(accessory?.isHidden == true)
    }
}
