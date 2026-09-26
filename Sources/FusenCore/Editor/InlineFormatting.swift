import AppKit

/// Inline formatting on Markdown text as in Notion: ⌘B, ⌘I, ⇧⌘S, ⌘E and ⌘K act on what the selection
/// shows, and Return inside bold (etc.) text leaves both lines bold. Markdown cannot write everything
/// rich text can ("**a **" is not bold, "*a**b*" is not "*a*" next to "**b**"), so each of these tries
/// the ways of writing its result — also respelling the spans around it ("**" as "__", "*" as "_") —
/// and keeps the first one the styler reads back exactly as intended. When none does, nothing changes.
@MainActor
enum InlineFormatting {
    /// A character a line shows, with the inline styles on it: "bold", "italic", "strike", "code", or a
    /// link's "](target)". Spaces carry none (a style on a space shows as nothing).
    struct Shown: Equatable {
        let character: unichar
        let styles: Set<String>
    }

    private typealias Form = (open: String, close: String)

    private static let styler = MarkdownStyler()

    /// A line (without its newline), styled on its own.
    @MainActor
    private struct Draft {
        let text: NSString
        let storage: NSTextStorage
        let spans: [ConcealedEditing.Span]
        /// What the line shows, with each character's index in `text`.
        let shown: [(index: Int, shown: Shown)]

        init(_ string: String) {
            text = string as NSString
            storage = NSTextStorage(string: string)
            InlineFormatting.styler.restyle(storage)
            let line = ConcealedEditing.line(at: 0, in: storage)
            spans = ConcealedEditing.spans(in: line, of: storage)
            shown = InlineFormatting.shown(line, of: storage)
        }

        var looks: [Shown] { shown.map(\.shown) }

        /// Index in `shown` of the first character at or after `p`.
        func position(of p: Int) -> Int { shown.firstIndex { $0.index >= p } ?? shown.count }
    }

    /// What a line of `s` shows, with each character's index.
    private static func shown(_ line: ConcealedEditing.Line, of s: NSTextStorage) -> [(index: Int, shown: Shown)] {
        let text = s.string as NSString
        let spans = ConcealedEditing.spans(in: line, of: s)
        var shown: [(index: Int, shown: Shown)] = []
        for i in line.contentStart..<line.contentsEnd where !ConcealedEditing.isHidden(i, in: s) {
            let c = text.character(at: i)
            var styles = Set<String>()
            if !isSpace(c) {
                for span in spans where NSLocationInRange(i, span.content) { styles.formUnion(names(span, text)) }
            }
            shown.append((i, Shown(character: c, styles: styles)))
        }
        return shown
    }

    /// Whether `span` gives its text `kind`'s style (bold italic gives both bold and italic).
    static func includes(_ span: ConcealedEditing.Span, _ kind: MarkdownSpan) -> Bool {
        span.kind == kind || (span.kind == .boldItalic && (kind == .bold || kind == .italic))
    }

    /// Whether the part `r` of `line` shows any text (spaces aside).
    static func showsText(in r: NSRange, line: String) -> Bool {
        Draft(line).shown.contains { NSLocationInRange($0.index, r) && !isSpace($0.shown.character) }
    }

    /// Whether everything the part `r` of `line` shows (spaces aside) has `kind`'s style.
    static func has(_ kind: MarkdownSpan, in r: NSRange, line: String) -> Bool {
        let chosen = Draft(line).shown.filter { NSLocationInRange($0.index, r) && !isSpace($0.shown.character) }
        return !chosen.isEmpty && chosen.allSatisfy { $0.shown.styles.contains(kind.rawValue) }
    }

    // MARK: ⌘B, ⌘I, ⇧⌘S, ⌘E, ⌘K

    /// The part `r` of `line` given (`adding`) or relieved of `kind`'s style: the new line, and where the
    /// selected characters are in it. Nil if Markdown cannot write that.
    static func toggle(_ kind: MarkdownSpan, adding: Bool, in r: NSRange, line: String) -> (text: String, selection: NSRange)? {
        let d = Draft(line)
        guard case let (selected, core)? = selection(r, d) else { return nil }
        let expected = restyled(d, selected) { adding ? $0.union([kind.rawValue]) : $0.subtracting([kind.rawValue]) }
        let candidates = spellings(d, around: core).flatMap { base in
            adding ? additions(kind, core, base, d) : removals(kind, core, base, d)
        }
        return verified(candidates, d, selected, expected)
    }

    /// ⌘K: the part `r` of `line` made a link to `target`; with nothing selected, the target is inserted
    /// as the link's text. The new line, and the link's text in it (a caret after it, if inserted).
    static func link(to target: String, in r: NSRange, line: String) -> (text: String, selection: NSRange)? {
        let d = Draft(line)
        let closing = "](" + target + ")"
        if r.length == 0 {
            let inserted = "[" + target + closing
            let text = d.text.replacingCharacters(in: r, with: inserted)
            guard typed(text, target, at: r.location, d, check: { $0.contains(closing) }) else { return nil }
            return (text, NSRange(location: r.location + (inserted as NSString).length, length: 0))
        }
        guard case let (selected, core)? = selection(r, d) else { return nil }
        let expected = restyled(d, selected) { $0.union([closing]) }
        let candidates = spellings(d, around: core).flatMap { base in
            [core, grown(core, d)].map { base.replacingCharacters(in: $0, with: "[" + base.substring(with: $0) + closing) }
        }
        return verified(candidates, d, selected, expected)
    }

    // MARK: Typing after ⌘B with nothing selected

    /// Typing `typed` at `p` in `line` after ⌘B (etc.) with nothing selected: the line with the typed
    /// text in the styles `adding`, or, with `leaving`, typed outside the span of that style the caret
    /// is in; and the caret after the typed text, inside its span, so that typing goes on in its style.
    /// Nil if Markdown cannot write it (the text is then typed as it is).
    static func typing(_ typed: String, at p: Int, in line: String, adding: Set<MarkdownSpan>,
                       leaving: MarkdownSpan?) -> (text: String, caret: Int)? {
        let d = Draft(line)
        // Spaces before the text are typed as they are: a span cannot start with one.
        let lead = String(typed.prefix(while: \.isWhitespace))
        let body = String(typed.dropFirst(lead.count))
        guard !body.isEmpty, !body.contains(where: \.isNewline) else { return nil }
        let here = NSRange(location: p, length: 0)
        var candidates: [(text: String, caret: Int)] = []
        if let leaving {
            guard let span = d.spans.last(where: { includes($0, leaving) && $0.content.location < p && p < NSMaxRange($0.content) })
            else { return nil }
            let rest: Set<MarkdownSpan> = span.kind == .boldItalic ? [leaving == .bold ? .italic : .bold] : []
            for base in spellings(d, around: here) {
                let closing = base.substring(with: span.closing), opening = base.substring(with: span.opening)
                for form in wrappings(rest) {
                    let before = closing + lead + form.open + body
                    candidates.append((base.replacingCharacters(in: here, with: before + form.close + opening),
                                       p + (before as NSString).length))
                }
            }
        } else {
            // Right after bold italic text, one of its styles going on: nested, the style kept around all of
            // it ("***ab***" then italic "x" is "*__ab__x*"), which reads the same after Notion's export.
            if adding.count == 1, let kind = adding.first, kind == .bold || kind == .italic, lead.isEmpty,
               let span = d.spans.first(where: { $0.kind == .boldItalic && NSMaxRange($0.range) == p }) {
                let content = d.text.substring(with: span.content)
                for outer in forms(kind) {
                    for inner in forms(kind == .bold ? .italic : .bold) {
                        let before = outer.open + inner.open + content + inner.close + body
                        candidates.append((d.text.replacingCharacters(in: span.range, with: before + outer.close),
                                           span.range.location + (before as NSString).length))
                    }
                }
            }
            for base in spellings(d, around: here) {
                for form in wrappings(adding) {
                    let before = lead + form.open + body
                    candidates.append((base.replacingCharacters(in: here, with: before + form.close), p + (before as NSString).length))
                }
            }
        }
        let names = leaving.map { [$0.rawValue] } ?? adding.map(\.rawValue)
        return candidates.first { candidate in
            self.typed(candidate.text, typed, at: p, d) { styles in
                leaving == nil ? names.allSatisfy(styles.contains) : !names.contains(where: styles.contains)
            }
        }
    }

    // MARK: Return

    /// Return at `p` inside inline spans of `line` (bold text, a link, ...): they close before the break
    /// and open again after it, so the two lines show what the one did. `continuation` begins the new
    /// line ("\n" and a list item's marker). Returns the new text for the line and the caret in it.
    static func lineBreak(at p: Int, in line: String, continuation: String) -> (text: String, caret: Int) {
        let d = Draft(line)
        let open = d.spans.filter { $0.content.location < p && p < NSMaxRange($0.content) }
        // Spaces at the break stay outside the spans: a span cannot end or start with one.
        var a = p, b = p
        while a > 0, isSpace(d.text.character(at: a - 1)), open.allSatisfy({ a - 1 > $0.content.location }) { a -= 1 }
        while b < d.text.length, isSpace(d.text.character(at: b)), open.allSatisfy({ b + 1 < NSMaxRange($0.content) }) { b += 1 }
        let at = d.position(of: p)
        let marker = String(continuation.dropFirst()) // without the "\n"
        for base in spellings(d, around: NSRange(location: p, length: 0)) {
            let delimiters = open.map { (open: base.substring(with: $0.opening), close: base.substring(with: $0.closing)) }
            let head = base.substring(to: a) + delimiters.reversed().map(\.close).joined()
                + base.substring(with: NSRange(location: a, length: p - a))
            let tail = marker + base.substring(with: NSRange(location: p, length: b - p))
                + delimiters.map(\.open).joined() + base.substring(from: b)
            let result = (text: head + "\n" + tail, caret: (head as NSString).length + 1 + (marker as NSString).length)
            if Draft(head).looks == Array(d.looks[..<at]), Draft(tail).looks == Array(d.looks[at...]) { return result }
        }
        let head = d.text.substring(to: p)
        return (head + continuation + d.text.substring(from: p), (head as NSString).length + (continuation as NSString).length)
    }

    // MARK: Deleting

    /// What the lines `region` of `s` become when the characters `deleted` go, written so that the rest
    /// shows as it did: spans of one style that the deletion brings together merge ("*a*x*b*" without "x"
    /// is "*ab*", not "*a**b*"), spaces left at the edge of a span move out of it ("**very important**"
    /// without "very" is " **important**"), and spans are respelled if need be ("**a***b*" is "__a__*b*").
    /// Returns the new text for `region` and where `caret` (an index in `s`) goes in it; nil if the plain
    /// result shows as it should already, or if nothing does.
    static func remainder(of region: NSRange, deleting deleted: IndexSet, in s: NSTextStorage,
                          caret: Int) -> (text: String, caret: Int)? {
        let ns = s.string as NSString
        var expected: [Shown] = []
        var location = region.location
        repeat {
            let line = ConcealedEditing.line(at: location, in: s)
            expected += shown(line, of: s).filter { !deleted.contains($0.index) }.map(\.shown)
            location = NSMaxRange(line.range)
        } while location < NSMaxRange(region)

        struct Unit {
            let index: Int
            var character: unichar
            /// The span this character is a delimiter of, and whether it opens it.
            var span: NSRange?
            let kind: MarkdownSpan?
            let opens: Bool
        }
        var units: [Unit] = []
        for i in region.location..<NSMaxRange(region) where !deleted.contains(i) {
            let span = ConcealedEditing.span(at: i, in: s)
            units.append(Unit(index: i, character: ns.character(at: i), span: span?.range, kind: span?.kind,
                              opens: span.map { i < NSMaxRange($0.opening) } ?? false))
        }
        func text(_ units: [Unit]) -> String {
            let characters = units.map(\.character)
            return String(utf16CodeUnits: characters, count: characters.count)
        }
        guard Draft(text(units)).looks != expected else { return nil }
        func run(_ key: NSRange, opening: Bool) -> Range<Int>? {
            guard let start = units.firstIndex(where: { $0.span == key && $0.opens == opening }) else { return nil }
            var end = start
            while end < units.count, units[end].span == key, units[end].opens == opening { end += 1 }
            return start..<end
        }
        // Spans of one style brought together become one: the first one's opening, the second one's closing.
        var i = 0
        while i < units.count {
            guard let a = units[i].span, !units[i].opens, let closing = run(a, opening: false), closing.lowerBound == i,
                  closing.upperBound < units.count, let b = units[closing.upperBound].span, b != a,
                  units[closing.upperBound].opens, units[closing.upperBound].kind == units[i].kind,
                  let opening = run(b, opening: true), let end = run(b, opening: false),
                  opening.count == closing.count, end.count == closing.count else { i += 1; continue }
            let spelling = units[closing].map(\.character)
            for (offset, k) in end.enumerated() {
                units[k].character = spelling[offset]
                units[k].span = a
            }
            units.removeSubrange(closing.lowerBound..<opening.upperBound)
        }
        // Spaces at the edges of a span move out of it; a span left with nothing in it goes.
        func isSpaceUnit(_ unit: Unit) -> Bool { unit.span == nil && isSpace(unit.character) }
        var keys: [NSRange] = []
        for unit in units where unit.opens { if let key = unit.span, !keys.contains(key) { keys.append(key) } }
        for key in keys {
            while let open = run(key, opening: true), let close = run(key, opening: false), open.upperBound < close.lowerBound,
                  isSpaceUnit(units[open.upperBound]) {
                units.insert(units.remove(at: open.upperBound), at: open.lowerBound)
            }
            while let open = run(key, opening: true), let close = run(key, opening: false), open.upperBound < close.lowerBound,
                  isSpaceUnit(units[close.lowerBound - 1]) {
                units.insert(units.remove(at: close.lowerBound - 1), at: close.upperBound - 1)
            }
            if let open = run(key, opening: true), let close = run(key, opening: false), open.upperBound == close.lowerBound {
                units.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        // Where the caret goes: after the last character still shown that was before it, else before the
        // first one after it.
        func caretOffset() -> Int {
            func shows(_ unit: Unit) -> Bool { unit.span == nil && !ConcealedEditing.isEscapeBackslash(unit.index, in: s) }
            if let k = units.lastIndex(where: { shows($0) && $0.index < caret }) { return k + 1 }
            return units.firstIndex(where: { shows($0) && $0.index >= caret }) ?? units.count
        }
        let offset = caretOffset()
        // Then respelled, the spans nearest the caret first.
        var bases = [units]
        let respellable = keys.filter { key in
            units.contains { $0.span == key } && [.bold, .italic, .boldItalic].contains(units.first { $0.span == key }?.kind)
        }.sorted { abs(($0.location) - caret) < abs(($1.location) - caret) }
        for key in respellable {
            guard let kind = units.first(where: { $0.span == key })?.kind else { continue }
            bases += bases.flatMap { base in
                forms(kind).dropFirst(0).compactMap { form -> [Unit]? in
                    var respelled = base
                    let opening = respelled.indices.filter { respelled[$0].span == key && respelled[$0].opens }
                    let closing = respelled.indices.filter { respelled[$0].span == key && !respelled[$0].opens }
                    let open = Array(form.open.utf16), close = Array(form.close.utf16)
                    guard open.count == opening.count, close.count == closing.count,
                          open != opening.map({ respelled[$0].character }) else { return nil }
                    for (k, index) in opening.enumerated() { respelled[index].character = open[k] }
                    for (k, index) in closing.enumerated() { respelled[index].character = close[k] }
                    return respelled
                }
            }
            if bases.count >= 24 { break }
        }
        for base in bases where Draft(text(base)).looks == expected {
            return (text(base), (text(Array(base[..<offset])) as NSString).length)
        }
        return nil
    }

    // MARK: Candidates

    /// The selected characters (indices in `d.shown`) and the range to style: from the first to the last
    /// selected character that shows (spaces aside), with the backslash of an escaped first one.
    private static func selection(_ r: NSRange, _ d: Draft) -> (selected: [Int], core: NSRange)? {
        let selected = d.shown.indices.filter { NSLocationInRange(d.shown[$0].index, r) }
        let marked = selected.filter { !isSpace(d.shown[$0].shown.character) }
        guard let first = marked.first, let last = marked.last else { return nil }
        let start = d.shown[first].index
        var core = NSRange(location: start, length: NSMaxRange(d.text.rangeOfComposedCharacterSequence(at: d.shown[last].index)) - start)
        if ConcealedEditing.isEscapeBackslash(core.location - 1, in: d.storage) {
            core = NSRange(location: core.location - 1, length: core.length + 1)
        }
        return (selected, core)
    }

    /// What `d` shows with the styles of the `selected` characters (spaces aside) changed by `change`.
    private static func restyled(_ d: Draft, _ selected: [Int], _ change: (Set<String>) -> Set<String>) -> [Shown] {
        var looks = d.looks
        for k in selected where !isSpace(looks[k].character) {
            looks[k] = Shown(character: looks[k].character, styles: change(looks[k].styles))
        }
        return looks
    }

    /// The line of `d` with the spans around `r` spelled each way Markdown allows ("**" or "__", …), the
    /// line as it is first. Delimiters of one style all have the same length, so indices do not move.
    private static func spellings(_ d: Draft, around r: NSRange) -> [NSString] {
        let area = NSRange(location: max(r.location - 1, 0), length: r.length + 2)
        var bases = [d.text]
        for span in d.spans where NSIntersectionRange(span.range, area).length > 0 && forms(span.kind).count > 1 {
            let written: Form = (d.text.substring(with: span.opening), d.text.substring(with: span.closing))
            let others = forms(span.kind).filter { $0 != written && ($0.open as NSString).length == span.opening.length }
            bases += bases.flatMap { base in
                others.map { form in
                    let respelled = NSMutableString(string: base)
                    respelled.replaceCharacters(in: span.closing, with: form.close)
                    respelled.replaceCharacters(in: span.opening, with: form.open)
                    return respelled as NSString
                }
            }
            if bases.count >= 24 { break }
        }
        return bases
    }

    private static func additions(_ kind: MarkdownSpan, _ core: NSRange, _ base: NSString, _ d: Draft) -> [String] {
        func wrapping(_ range: NSRange, _ inner: String) -> [String] {
            wrappings([kind]).map { base.replacingCharacters(in: range, with: $0.open + inner + $0.close) }
        }
        let whole = grown(core, d)
        var candidates: [String] = []
        // Next to (or over) spans of the same style: one span ("**ab**" and "c" make "**abc**", not
        // "**ab****c**", which other Markdown readers — Notion's — read differently).
        var merged = core
        for span in d.spans where span.kind == kind
            && (NSMaxRange(span.range) >= core.location && span.range.location <= NSMaxRange(core)) {
            merged = NSUnionRange(merged, span.range)
        }
        if merged != core {
            let region = grown(merged, d)
            candidates += wrapping(region, without(kind, in: region, base, d))
        }
        candidates += wrapping(core, base.substring(with: core))
        // Grown to whole spans, with the same style inside dropped (it merges into the new span).
        candidates += wrapping(whole, without(kind, in: whole, base, d))
        if kind == .code {
            // Code shows its text as written: only what the selection shows goes inside.
            candidates += wrapping(core, shownText(in: core, d)) + wrapping(whole, shownText(in: whole, d))
        } else if let code = d.spans.first(where: {
            $0.kind == .code && core.location >= $0.content.location && NSMaxRange(core) <= NSMaxRange($0.content)
        }) {
            // Nothing is styled inside code: the style goes around the code, split off if need be.
            let tick: Form = (base.substring(with: code.opening), base.substring(with: code.closing))
            let before = NSRange(location: code.content.location, length: core.location - code.content.location)
            let after = NSRange(location: NSMaxRange(core), length: NSMaxRange(code.content) - NSMaxRange(core))
            for form in wrappings([kind]) {
                let split = piece(before, tick, base) + form.open + tick.open + base.substring(with: core) + tick.close
                    + form.close + piece(after, tick, base)
                candidates.append(base.replacingCharacters(in: code.range, with: split))
            }
        }
        return candidates
    }

    private static func removals(_ kind: MarkdownSpan, _ core: NSRange, _ base: NSString, _ d: Draft) -> [String] {
        let touched = d.spans.filter { includes($0, kind) && NSIntersectionRange($0.content, core).length > 0 }
        // Only the outermost: an inner one is rewritten with the span around it.
        let targets = touched.filter { span in !touched.contains { $0 != span && NSIntersectionRange($0.range, span.range) == span.range } }
        guard !targets.isEmpty else { return [] }
        // Bold italic losing one style in part: first nested, the kept style around all of it ("***abc***"
        // without bold on "b" is "*__a__b__c__*"), which reads the same after Notion's export turns "_" into
        // "*"; then side by side ("***a***_b_***c***").
        let keep: MarkdownSpan = kind == .bold ? .italic : .bold
        var plans: [(outer: Form, inner: Form)?] = []
        if targets.contains(where: { $0.kind == .boldItalic }) {
            for outer in forms(keep) { for inner in forms(kind) { plans.append((outer, inner)) } }
        }
        plans += [nil, nil]
        return plans.enumerated().map { number, plan in
            let result = NSMutableString(string: base)
            for span in targets.sorted(by: { $0.range.location > $1.range.location }) {
                // The part of the span to unstyle, holding whole any spans inside it that it touches or is in.
                var cut = NSIntersectionRange(grown(NSIntersectionRange(span.content, core), d), span.content)
                for inner in d.spans where inner != span && NSIntersectionRange(inner.range, span.content) == inner.range
                    && cut.location >= inner.content.location && NSMaxRange(cut) <= NSMaxRange(inner.content) {
                    cut = NSUnionRange(cut, inner.range)
                }
                let before = NSRange(location: span.content.location, length: cut.location - span.content.location)
                let after = NSRange(location: NSMaxRange(cut), length: NSMaxRange(span.content) - NSMaxRange(cut))
                let replacement: String
                if span.kind == .boldItalic, let plan {
                    replacement = plan.outer.open + piece(before, plan.inner, base) + base.substring(with: cut)
                        + piece(after, plan.inner, base) + plan.outer.close
                } else {
                    let own: Form = (base.substring(with: span.opening), base.substring(with: span.closing))
                    let middle = span.kind == .boldItalic ? piece(cut, pick(forms(keep), number), base) : base.substring(with: cut)
                    replacement = piece(before, own, base) + middle + piece(after, own, base)
                }
                result.replaceCharacters(in: span.range, with: replacement)
            }
            return result as String
        }
    }

    /// The first candidate that shows `expected`, and where the `selected` characters are in it.
    private static func verified(_ candidates: [String], _ d: Draft, _ selected: [Int],
                                 _ expected: [Shown]) -> (text: String, selection: NSRange)? {
        var tried = Set<String>()
        for candidate in candidates where tried.insert(candidate).inserted {
            let result = Draft(candidate)
            guard result.looks == expected, let first = selected.first, let last = selected.last else { continue }
            let start = result.shown[first].index
            let end = NSMaxRange(result.text.rangeOfComposedCharacterSequence(at: result.shown[last].index))
            return (candidate, NSRange(location: start, length: end - start))
        }
        return nil
    }

    /// Whether `candidate` is the line of `d` with `typed` inserted at `p`, all of it shown, and each of its
    /// characters (spaces aside) passing `check`.
    private static func typed(_ candidate: String, _ typed: String, at p: Int, _ d: Draft,
                              check: (Set<String>) -> Bool) -> Bool {
        let result = Draft(candidate).looks
        let units = Array(typed.utf16)
        let at = d.position(of: p)
        guard result.count == d.shown.count + units.count else { return false }
        let inserted = result[at..<(at + units.count)]
        return Array(result[..<at]) == Array(d.looks[..<at])
            && Array(result[(at + units.count)...]) == Array(d.looks[at...])
            && inserted.map(\.character) == units
            && inserted.allSatisfy { isSpace($0.character) || check($0.styles) }
    }

    /// `r` grown until every span it overlaps lies inside it or holds it.
    private static func grown(_ r: NSRange, _ d: Draft) -> NSRange {
        var r = r
        var changed = true
        while changed {
            changed = false
            for span in d.spans where NSIntersectionRange(span.range, r).length > 0 {
                let held = r.location >= span.content.location && NSMaxRange(r) <= NSMaxRange(span.content)
                if !held, NSIntersectionRange(span.range, r) != span.range {
                    r = NSUnionRange(r, span.range)
                    changed = true
                }
            }
        }
        return r
    }

    /// The text of `r` without the delimiters of the spans of `kind` inside it (bold italic keeps its
    /// other style).
    private static func without(_ kind: MarkdownSpan, in r: NSRange, _ base: NSString, _ d: Draft) -> String {
        var edits: [(range: NSRange, string: String)] = []
        for span in d.spans where NSIntersectionRange(span.range, r) == span.range && includes(span, kind) {
            let rest: Form = span.kind == .boldItalic ? forms(kind == .bold ? .italic : .bold)[0] : ("", "")
            edits += [(span.opening, rest.open), (span.closing, rest.close)]
        }
        let result = NSMutableString(string: base.substring(with: r))
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: NSRange(location: edit.range.location - r.location, length: edit.range.length), with: edit.string)
        }
        return result as String
    }

    /// What `r` shows, without its syntax.
    private static func shownText(in r: NSRange, _ d: Draft) -> String {
        let units = d.shown.filter { NSLocationInRange($0.index, r) }.map(\.shown.character)
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// The text of `r` in the delimiters `form`, with spaces at its ends outside them.
    private static func piece(_ r: NSRange, _ form: Form, _ base: NSString) -> String {
        let text = base.substring(with: r)
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard !body.isEmpty else { return text }
        let lead = String(text.prefix { $0 == " " || $0 == "\t" })
        let trail = String(String(text.reversed()).prefix { $0 == " " || $0 == "\t" })
        return lead + form.open + body + form.close + trail
    }

    /// The ways of writing text in all of `kinds` at once, the usual one first.
    private static func wrappings(_ kinds: Set<MarkdownSpan>) -> [Form] {
        var kinds = kinds
        if kinds.contains(.bold), kinds.contains(.italic) {
            kinds.subtract([.bold, .italic])
            kinds.insert(.boldItalic)
        }
        var results: [Form] = [("", "")]
        for kind in [MarkdownSpan.code, .strike, .italic, .bold, .boldItalic] where kinds.contains(kind) {
            results = results.flatMap { inner in forms(kind).map { (open: $0.open + inner.open, close: inner.close + $0.close) } }
        }
        return results
    }

    private static func forms(_ kind: MarkdownSpan) -> [Form] {
        switch kind {
        case .bold: [("**", "**"), ("__", "__")]
        case .italic: [("*", "*"), ("_", "_")]
        case .boldItalic: [("***", "***"), ("___", "___"), ("*__", "__*"), ("_**", "**_"), ("**_", "_**"), ("__*", "*__")]
        case .strike: [("~~", "~~")]
        case .code: [("`", "`")]
        case .link: [("", "")]
        }
    }

    private static func pick(_ forms: [Form], _ variant: Int) -> Form { forms[variant % forms.count] }

    private static func names(_ span: ConcealedEditing.Span, _ text: NSString) -> [String] {
        switch span.kind {
        case .boldItalic: ["bold", "italic"]
        case .link: [text.substring(with: span.closing)]
        default: [span.kind.rawValue]
        }
    }

    /// White space, as the styler's patterns (`\s`) see it.
    static func isSpace(_ c: unichar) -> Bool {
        Unicode.Scalar(c).map { CharacterSet.whitespaces.contains($0) } ?? false
    }
}
