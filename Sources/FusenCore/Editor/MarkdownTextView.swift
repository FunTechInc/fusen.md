import AppKit

final class MarkdownTextView: NSTextView {
    private static let listPrefix =
        makeRegex(#"^([ \t]*)(?:([-*+])|(\d{1,9})([.)]))([ \t]+)(\[[ xX]\][ \t]+)?"#)

    // Return continues a list / task list; Return on an empty item ends the list.
    // While the IME is composing, Return commits the composition and never reaches this method,
    // but guard on marked text anyway.
    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        guard !hasMarkedText(), selection.length == 0, let storage = textStorage else {
            return super.insertNewline(sender)
        }
        let text = storage.string
        let ns = text as NSString
        var start = 0, contentsEnd = 0
        ns.getLineStart(&start, end: nil, contentsEnd: &contentsEnd,
                        for: NSRange(location: selection.location, length: 0))
        let line = NSRange(location: start, length: contentsEnd - start)
        guard let m = Self.listPrefix.firstMatch(in: text, range: line),
              selection.location >= NSMaxRange(m.range) else {
            return super.insertNewline(sender)
        }
        if NSMaxRange(m.range) == NSMaxRange(line) {
            replaceCharacters(in: m.range, with: "", actionName: "リストの終了")
            return
        }
        let marker: String
        if m.range(at: 2).location != NSNotFound {
            marker = ns.substring(with: m.range(at: 2))
        } else {
            let number = Int(ns.substring(with: m.range(at: 3))) ?? 0
            marker = "\(number + 1)" + ns.substring(with: m.range(at: 4))
        }
        let continuation = "\n" + ns.substring(with: m.range(at: 1)) + marker + ns.substring(with: m.range(at: 5))
            + (m.range(at: 6).location != NSNotFound ? "[ ] " : "")
        insertText(continuation, replacementRange: selection)
    }

    // Tab / Shift-Tab on a list item nests it one level deeper / shallower, as in Notion. Nesting uses
    // tabs, which is also how Notion-flavored Markdown writes child blocks.
    override func insertTab(_ sender: Any?) {
        guard let line = currentListLine() else { return super.insertTab(sender) }
        replaceCharacters(in: NSRange(location: line.location, length: 0), with: "\t", actionName: "字下げ")
    }

    override func insertBacktab(_ sender: Any?) {
        guard let line = currentListLine(), let storage = textStorage else { return super.insertBacktab(sender) }
        let ns = storage.string as NSString
        var remove = 0
        if line.length > 0, ns.character(at: line.location) == 0x09 {
            remove = 1
        } else {
            while remove < 2, remove < line.length, ns.character(at: line.location + remove) == 0x20 { remove += 1 }
        }
        guard remove > 0 else { return }
        replaceCharacters(in: NSRange(location: line.location, length: remove), with: "", actionName: "字下げ解除")
    }

    /// The caret's line if it is a list item (and nothing is selected or being composed).
    private func currentListLine() -> NSRange? {
        let selection = selectedRange()
        guard !hasMarkedText(), selection.length == 0, let storage = textStorage else { return nil }
        let ns = storage.string as NSString
        var start = 0, contentsEnd = 0
        ns.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: selection.location, length: 0))
        let line = NSRange(location: start, length: contentsEnd - start)
        return Self.listPrefix.firstMatch(in: storage.string, range: line) == nil ? nil : line
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, let location = attributeValue(.mdTaskToggle, under: event, precise: true) as? Int {
            toggleTask(checkLocation: location)
            return
        }
        if event.modifierFlags.contains(.command), let url = attributeValue(.mdLink, under: event, precise: false) as? URL {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    private func toggleTask(checkLocation: Int) {
        guard let storage = textStorage, checkLocation < storage.length else { return }
        let range = NSRange(location: checkLocation, length: 1)
        let current = (storage.string as NSString).substring(with: range)
        replaceCharacters(in: range, with: current == " " ? "x" : " ", actionName: "チェックボックスの切り替え")
    }

    /// Replaces the whole text as one undoable step (used to restore a version from history).
    func replaceAllText(with string: String, actionName: String) {
        guard let storage = textStorage else { return }
        replaceCharacters(in: NSRange(location: 0, length: storage.length), with: string, actionName: actionName)
        setSelectedRange(NSRange(location: 0, length: 0))
        scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// Undoable replacement that goes through the normal NSTextView change pipeline.
    private func replaceCharacters(in range: NSRange, with string: String, actionName: String) {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: string) else { return }
        let selection = selectedRange()
        storage.replaceCharacters(in: range, with: string)
        didChangeText()
        undoManager?.setActionName(actionName)
        let delta = (string as NSString).length - range.length
        let caret = selection.location >= NSMaxRange(range) ? selection.location + delta : range.location
        setSelectedRange(NSRange(location: min(max(caret, 0), storage.length), length: 0))
    }

    /// Attribute value under the mouse. `precise` also requires the pointer to be inside the
    /// run's glyph rectangle (so clicking just after a checkbox places the caret instead).
    private func attributeValue(_ key: NSAttributedString.Key, under event: NSEvent, precise: Bool) -> Any? {
        guard let storage = textStorage, let window, storage.length > 0 else { return nil }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            var run = NSRange()
            guard let value = storage.attribute(key, at: candidate, effectiveRange: &run) else { continue }
            if !precise { return value }
            let rect = firstRect(forCharacterRange: run, actualRange: nil).insetBy(dx: -2, dy: -2)
            if rect.contains(screenPoint) { return value }
        }
        return nil
    }
}
