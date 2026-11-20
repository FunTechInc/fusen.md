import Foundation

/// The state of a to-do, written between the brackets of its marker: "- [ ]" not started, "- [>]"
/// waiting (picked to do next), "- [/]" in progress, "- [x]" done. Waiting and in progress are the
/// note's signals: they show a pause mark and a turning ring instead of the checkbox.
enum TaskState: String, CaseIterable, Sendable {
    case todo = " "
    case waiting = ">"
    case doing = "/"
    case done = "x"

    /// A regex character class matching every way a state is written ("X" is done too).
    static let characterClass = "[ xX/>]"

    init?(character: unichar) {
        switch character {
        case 0x20: self = .todo
        case 0x3E: self = .waiting
        case 0x2F: self = .doing
        case 0x78, 0x58: self = .done
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .todo: "未着手"
        case .waiting: "待機"
        case .doing: "進行中"
        case .done: "完了"
        }
    }

    /// One step forward (a click): a waiting to-do starts, one in progress is done. A plain to-do is
    /// checked off at once, and a done one is unchecked, as a checkbox always did.
    var advanced: TaskState {
        switch self {
        case .todo: .done
        case .waiting: .doing
        case .doing: .done
        case .done: .todo
        }
    }

    /// ⌥-click: the to-do waits; one that waits already goes back to not started.
    var toggledWaiting: TaskState { self == .waiting ? .todo : .waiting }

    /// Shown as a signal (not as a checkbox).
    var isSignal: Bool { self == .waiting || self == .doing }
}
