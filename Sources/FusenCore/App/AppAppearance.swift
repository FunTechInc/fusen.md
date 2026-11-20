import AppKit

/// 外観 (設定 > 一般): the app — its notes and its windows — as the system is, or always light or dark.
enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark

    static let defaultsKey = "appearance"

    var title: String {
        switch self {
        case .system: "システムに合わせる"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }

    /// The chosen one (システムに合わせる until something else is chosen).
    static var current: AppAppearance {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppAppearance.init) ?? .system
    }

    /// The notes follow: each redraws itself when its window's appearance changes.
    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
