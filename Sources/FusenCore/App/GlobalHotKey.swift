import AppKit
import Carbon.HIToolbox

/// A key combination for a global hot key (one that works while another app is active).
struct HotKeyShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier mask: cmdKey, optionKey, controlKey, shiftKey.
    var carbonModifiers: UInt32
    /// How the key is shown ("F", "1", "Space", …).
    var keyName: String

    /// ⌃⌥⌘F ("F" for fusen): not used by macOS or common apps.
    static let defaultToggle = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_F),
                                              carbonModifiers: UInt32(controlKey | optionKey | cmdKey), keyName: "F")

    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyName = keyName
    }

    /// The combination pressed in `event`, or nil unless it has ⌘, ⌃ or ⌥ (a plain key or ⇧+key as a
    /// global hot key would swallow ordinary typing in every app).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.isDisjoint(with: [.command, .control, .option]) else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let name = Self.specialKeyNames[Int(event.keyCode)]
            ?? event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers, keyName: name)
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_JIS_Eisu: "英数", kVK_JIS_Kana: "かな",
    ]
}

/// A system-wide hot key through Carbon's RegisterEventHotKey, which needs no Accessibility
/// permission. The handler runs on the main thread. RegisterEventHotKey only reports combinations
/// this app already registered; another app using the same one is not detected (then usually only
/// one of the two apps reacts).
@MainActor
final class GlobalHotKey {
    enum RegistrationError: Error, Equatable {
        /// Another hot key of this app already uses the combination.
        case taken
        case failed(OSStatus)
    }

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var isEventHandlerInstalled = false

    /// Identifies this hot key in the pressed event (EventHotKeyID.id).
    let id: UInt32
    private var hotKeyRef: EventHotKeyRef?

    init(action: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = action
        Self.installEventHandler()
    }

    isolated deinit {
        unregister()
        Self.handlers[id] = nil
    }

    var isRegistered: Bool { hotKeyRef != nil }

    func register(_ shortcut: HotKeyShortcut) throws(RegistrationError) {
        unregister()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4653_4E4D) /* "FSNM" */, id: id)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            throw status == OSStatus(eventHotKeyExistsErr) ? .taken : .failed(status)
        }
        hotKeyRef = ref
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private static func installEventHandler() {
        guard !isEventHandlerInstalled else { return }
        isEventHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            MainActor.assumeIsolated { GlobalHotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// The 「表示・非表示」 hot key setting: persisted in UserDefaults, registered at launch, edited in 設定.
@MainActor
@Observable
final class ToggleShortcut {
    /// nil: turned off.
    private(set) var shortcut: HotKeyShortcut?
    /// Why the current shortcut could not be registered (Japanese), if it could not.
    private(set) var errorMessage: String?

    @ObservationIgnored private let hotKey: GlobalHotKey
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "toggleShortcut"
    private static let offKey = "toggleShortcutOff"

    init(defaults: UserDefaults = .standard, action: @escaping () -> Void) {
        self.defaults = defaults
        hotKey = GlobalHotKey(action: action)
        if defaults.bool(forKey: Self.offKey) {
            shortcut = nil
        } else if let data = defaults.data(forKey: Self.key),
                  let saved = try? JSONDecoder().decode(HotKeyShortcut.self, from: data) {
            shortcut = saved
        } else {
            shortcut = .defaultToggle
        }
        activate()
    }

    var isRegistered: Bool { hotKey.isRegistered }
    var hotKeyForTesting: GlobalHotKey { hotKey }

    func set(_ new: HotKeyShortcut?) {
        shortcut = new
        defaults.set(new == nil, forKey: Self.offKey)
        if let new, let data = try? JSONEncoder().encode(new) {
            defaults.set(data, forKey: Self.key)
        }
        activate()
    }

    /// While the settings window records a new combination, the old one must not fire.
    func suspend() {
        hotKey.unregister()
    }

    /// Registers the current shortcut again (after `suspend`, or to retry).
    func activate() {
        errorMessage = nil
        guard let shortcut else { return hotKey.unregister() }
        do {
            try hotKey.register(shortcut)
        } catch .taken {
            errorMessage = "\(shortcut.displayString) はこのアプリのほかの機能で使われています。別の組み合わせにしてください。"
        } catch {
            errorMessage = "\(shortcut.displayString) を登録できませんでした。別の組み合わせにしてください。"
        }
    }
}
