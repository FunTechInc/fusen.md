import AppKit
import Testing
@testable import FusenCore

/// Dragging cards: where they can be dropped, and what a drag with the mouse does. (TestNote is in
/// NoteFocusTests.) The press is followed until the release; the tests hand the text view the events
/// that follow it (events put in the real queue come back with other locations for a window that is
/// not on screen).
@MainActor
struct CardDragTests {
    private let theme = MarkdownTheme()
    private func card(_ name: String, _ lines: String...) -> String {
        ([":::card \(name)"] + lines + [":::"]).joined(separator: "\n")
    }

    private func layout(_ note: TestNote) -> ConcealingLayoutManager { note.textView.layoutManager as! ConcealingLayoutManager }

    private func event(_ note: TestNote, _ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        let origin = note.textView.textContainerOrigin
        let inWindow = note.textView.convert(NSPoint(x: point.x + origin.x, y: point.y + origin.y), to: nil)
        return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: 0, windowNumber: note.window.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Presses at `start`, drags through `path` and releases (with no path: a click). Points are in the
    /// text container's coordinates.
    private func mouse(_ note: TestNote, at start: NSPoint, through path: [NSPoint] = [], escape: Bool = false) {
        var events = path.map { event(note, .leftMouseDragged, at: $0) }
        if escape {
            events.append(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: note.window.windowNumber,
                                           context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!)
        } else {
            events.append(event(note, .leftMouseUp, at: path.last ?? start))
        }
        note.textView.trackingEvents = { _ in events.isEmpty ? nil : events.removeFirst() }
        note.textView.mouseDown(with: event(note, .leftMouseDown, at: start))
        note.textView.trackingEvents = nil
    }

    /// A point on the frame of a card where it can be picked up: between its title and "•••".
    private func handle(_ card: ConcealingLayoutManager.CardGeometry) -> NSPoint {
        NSPoint(x: card.dots.minX - 12, y: card.dots.midY)
    }

    // MARK: Where a card can be dropped

    @Test func aCardCanGoBetweenThePiecesAndBesideOtherCards() throws {
        let a = card("orange A", "一"), b = card("purple B", "二")
        let note = TestNote("一行目\n" + a + "\n二行目\n" + b + "\n三行目", size: CGSize(width: 320, height: 420))
        let cards = layout(note).cardGeometries()
        let targets = note.textView.cardDropTargets(forCard: 0)
        // Everywhere between the pieces except around itself; both sides of the other card.
        #expect(Set(targets.map(\.destination)) == [.before(piece: 0), .before(piece: 3), .before(piece: 4), .before(piece: 5),
                                                    .beside(card: 1, after: false), .beside(card: 1, after: true)])
        // The lines that show them: across the note between the pieces, along the card's side beside it.
        let above = try #require(targets.first { $0.destination == .before(piece: 3) })
        #expect(above.indicator.width > 250 && above.indicator.height == 2)
        #expect(above.indicator.midY < cards[1].frame.minY && above.indicator.midY > cards[0].frame.maxY)
        let right = try #require(targets.first { $0.destination == .beside(card: 1, after: true) })
        #expect(right.indicator.width == 2 && right.indicator.height == cards[1].frame.height)
        #expect(right.indicator.minX >= cards[1].frame.maxX)
        // What the pointer means.
        func target(_ point: NSPoint) -> CardArrangement.Destination? { note.textView.cardDropTarget(forCard: 0, at: point)?.destination }
        #expect(target(NSPoint(x: cards[0].frame.midX, y: cards[0].frame.midY)) == nil)                  // still over itself
        #expect(target(NSPoint(x: cards[1].frame.maxX - 8, y: cards[1].frame.midY)) == .beside(card: 1, after: true))
        #expect(target(NSPoint(x: cards[1].frame.minX + 8, y: cards[1].frame.midY)) == .beside(card: 1, after: false))
        #expect(target(NSPoint(x: cards[1].frame.midX, y: cards[1].frame.minY + 4)) == .before(piece: 3))  // its middle: above it
        #expect(target(NSPoint(x: cards[1].frame.midX, y: cards[1].frame.maxY - 4)) == .before(piece: 4))
        #expect(target(NSPoint(x: 40, y: 2)) == .before(piece: 0))
        #expect(target(NSPoint(x: 40, y: 2000)) == .before(piece: 5))
    }

    @Test func aRowTakesNoMoreCardsThanTheNoteHasRoomFor() {
        let a = card("A"), b = card("B"), c = card("C")
        let text = "::::columns\n" + a + "\n" + b + "\n::::\n" + c
        func sides(_ width: CGFloat) -> Int {
            TestNote(text, size: CGSize(width: width, height: 300)).textView.cardDropTargets(forCard: 2)
                .filter { if case .beside = $0.destination { true } else { false } }.count
        }
        #expect(sides(420) == 4)   // room for three: both sides of both cards
        #expect(sides(300) == 0)   // room for two only
        // The cards of the row can still change places.
        let swap = TestNote(text, size: CGSize(width: 300, height: 300)).textView.cardDropTargets(forCard: 0)
        #expect(swap.contains { $0.destination == .beside(card: 1, after: true) })
        // In a note too narrow for two there is no place beside a card at all.
        let narrow = TestNote(a + "\n" + b, size: CGSize(width: 200, height: 300)).textView.cardDropTargets(forCard: 0)
        #expect(!narrow.isEmpty && narrow.allSatisfy { $0.zone == nil })
    }

    // MARK: Dragging

    @Test func draggedToTheSideOfACardTheTwoStandSideBySide() {
        let a = card("orange A", "一"), b = card("purple B", "二")
        let note = TestNote("本文\n" + a + "\n" + b + "\nおわり", size: CGSize(width: 320, height: 420))
        var cards = layout(note).cardGeometries()
        let side = NSPoint(x: cards[0].frame.maxX - 6, y: cards[0].frame.midY)
        mouse(note, at: handle(cards[1]), through: [NSPoint(x: side.x - 40, y: side.y + 30), side])
        #expect(note.textView.string == "本文\n::::columns\n" + a + "\n" + b + "\n::::\nおわり")
        cards = layout(note).cardGeometries()
        #expect(cards.count == 2 && abs(cards[0].frame.minY - cards[1].frame.minY) < 0.5 && cards[1].frame.minX > cards[0].frame.maxX)
        #expect(note.textView.subviews.count == 1)                 // the picture and the line are gone
        #expect(note.textView.selectedRange().location == (note.textView.string as NSString).range(of: "purple B").upperBound)
        // ⌘Z takes it back in one step.
        note.textView.undoManager?.undo()
        #expect(note.textView.string == "本文\n" + a + "\n" + b + "\nおわり")
    }

    @Test func draggedOutOfARowTheCardsStandOneBelowTheOther() {
        let a = card("orange A", "一"), b = card("purple B", "二")
        let note = TestNote("本文\n::::columns\n" + a + "\n" + b + "\n::::\nおわり", size: CGSize(width: 320, height: 420))
        let cards = layout(note).cardGeometries()
        mouse(note, at: handle(cards[0]), through: [NSPoint(x: 60, y: 300), NSPoint(x: 60, y: 2000)])
        #expect(note.textView.string == "本文\n" + b + "\nおわり\n" + a)
        // And up again, by its title this time: a card is picked up by its tag too.
        let again = layout(note).cardGeometries()
        mouse(note, at: NSPoint(x: again[1].tags[0].midX, y: again[1].tags[0].midY), through: [NSPoint(x: 60, y: 30), NSPoint(x: 60, y: 1)])
        #expect(note.textView.string == a + "\n本文\n" + b + "\nおわり")
    }

    @Test func aClickOnTheFrameIsNotADrag() {
        let a = card("orange 名前", "一行目", "二行目")
        let note = TestNote("本文\n" + a + "\nおわり", size: CGSize(width: 320, height: 420))
        let text = note.textView.string as NSString
        let geometry = layout(note).cardGeometries()[0]
        // Beside the title: into the title, at its end. On the title: where the click is.
        mouse(note, at: handle(geometry))
        #expect(note.textView.selectedRange() == NSRange(location: text.range(of: "名前").upperBound, length: 0))
        mouse(note, at: NSPoint(x: geometry.tags[0].minX + 3, y: geometry.tags[0].midY))
        #expect(note.textView.selectedRange() == NSRange(location: text.range(of: "名前").location, length: 0))
        // Under the text: to its end. A press that hardly moves is a click too.
        let under = NSPoint(x: geometry.frame.midX, y: geometry.frame.maxY - 3)
        mouse(note, at: under, through: [NSPoint(x: under.x + 2, y: under.y + 1)])
        #expect(note.textView.selectedRange() == NSRange(location: text.range(of: "二行目").upperBound, length: 0))
        #expect(note.textView.string == "本文\n" + a + "\nおわり")
    }

    @Test func escapeLetsGoOfTheCard() {
        let a = card("orange A", "一"), b = card("purple B", "二")
        let text = "本文\n" + a + "\n" + b
        let note = TestNote(text, size: CGSize(width: 320, height: 420))
        let cards = layout(note).cardGeometries()
        mouse(note, at: handle(cards[1]), through: [NSPoint(x: cards[0].frame.maxX - 6, y: cards[0].frame.midY)], escape: true)
        #expect(note.textView.string == text)
        #expect(note.textView.subviews.count == 1)
        // Dropped on itself: nothing either.
        mouse(note, at: handle(cards[1]), through: [NSPoint(x: cards[1].frame.midX, y: cards[1].frame.midY + 8)])
        #expect(note.textView.string == text)
    }

    @Test func whileACardIsDraggedALineShowsWhereItWouldGo() throws {
        let a = card("orange A", "- [/] 一", "- [ ] 二"), b = card("purple B", "- [>] 三")
        let note = TestNote("本文\n" + a + "\n" + b + "\nおわり", size: CGSize(width: 320, height: 330))
        let cards = layout(note).cardGeometries()
        let origin = note.textView.textContainerOrigin
        let side = NSPoint(x: cards[0].frame.maxX - 10, y: cards[0].frame.midY + 6)
        var events = [event(note, .leftMouseDragged, at: side), event(note, .leftMouseUp, at: side)]
        var lines: [NSRect] = []
        var pictures = 0
        note.textView.trackingEvents = { _ in
            if events.count == 1 {
                // The drag is under way: the picture of the card follows the pointer, and the line is drawn.
                lines = note.textView.subviews.filter { $0 is CardDropLine && !$0.isHidden }.map(\.frame)
                pictures = note.textView.subviews.filter { $0 is NSImageView }.count
                try? note.write("card-drag")
            }
            return events.isEmpty ? nil : events.removeFirst()
        }
        note.textView.mouseDown(with: event(note, .leftMouseDown, at: handle(cards[1])))
        note.textView.trackingEvents = nil
        #expect(pictures == 1)
        let line = try #require(lines.first)
        #expect(line.width == 2 && line.height == cards[0].frame.height)
        #expect(line.minX - origin.x >= cards[0].frame.maxX)                    // along card A's right side
        #expect(note.textView.string == "本文\n::::columns\n" + a + "\n" + b + "\n::::\nおわり")
        try note.write("card-dropped")
    }

    @Test func resizingTheNoteFitsItsRows() {
        let note = TestNote("::::columns\n" + card("A") + "\n" + card("B") + "\n::::", size: CGSize(width: 320, height: 300))
        func stacked() -> Bool { let cards = layout(note).cardGeometries(); return cards[1].frame.minY > cards[0].frame.maxY }
        #expect(!stacked())
        note.window.setFrame(NSRect(x: 100, y: 100, width: 200, height: 300), display: false)
        #expect(stacked())
        note.window.setFrame(NSRect(x: 100, y: 100, width: 320, height: 300), display: false)
        #expect(!stacked())
    }

    @Test func thePointerShowsWhatCanBeDragged() {
        let note = TestNote("本文\n" + card("orange A", "一"), size: CGSize(width: 320, height: 300))
        let geometry = layout(note).cardGeometries()[0]
        #expect(note.textView.cardCursor(at: handle(geometry)) == .openHand)
        #expect(note.textView.cardCursor(at: NSPoint(x: geometry.tags[0].midX, y: geometry.tags[0].midY)) == .openHand)
        #expect(note.textView.cardCursor(at: NSPoint(x: geometry.dots.midX, y: geometry.dots.midY)) == .pointingHand)
        #expect(note.textView.cardCursor(at: NSPoint(x: geometry.panel!.midX, y: geometry.panel!.midY)) == nil)
        #expect(note.textView.cardCursor(at: NSPoint(x: 20, y: 4)) == nil)
    }
}
