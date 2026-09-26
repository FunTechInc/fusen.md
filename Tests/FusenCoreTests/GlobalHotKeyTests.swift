import AppKit
import Carbon.HIToolbox
import Testing
@testable import FusenCore

@MainActor
struct GlobalHotKeyTests {
    private func keyDown(_ keyCode: Int, _ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: UInt16(keyCode))!
    }

    @Test func defaultIsControlOptionCommandF() {
        #expect(HotKeyShortcut.defaultToggle.displayString == "⌃⌥⌘F")
        #expect(HotKeyShortcut.defaultToggle.keyCode == UInt32(kVK_ANSI_F))
    }

    @Test func recordsCombinationsWithAModifier() throws {
        let s = try #require(HotKeyShortcut(event: keyDown(kVK_ANSI_M, "m", [.control, .shift, .command])))
        #expect(s.displayString == "⌃⇧⌘M")
        #expect(s.carbonModifiers == UInt32(controlKey | shiftKey | cmdKey))
        #expect(try #require(HotKeyShortcut(event: keyDown(kVK_Space, " ", [.option]))).displayString == "⌥Space")
        #expect(try #require(HotKeyShortcut(event: keyDown(kVK_F5, "", [.control]))).displayString == "⌃F5")
        // A plain key or ⇧+key would swallow ordinary typing in every app.
        #expect(HotKeyShortcut(event: keyDown(kVK_ANSI_F, "f", [])) == nil)
        #expect(HotKeyShortcut(event: keyDown(kVK_ANSI_F, "F", [.shift])) == nil)
    }

    @Test func settingIsSavedAndCanBeTurnedOff() throws {
        let suite = "FusenTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let custom = HotKeyShortcut(keyCode: UInt32(kVK_F13), carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
                                    keyName: "F13")
        do {
            let setting = ToggleShortcut(defaults: defaults) {}
            #expect(setting.shortcut == .defaultToggle)
            setting.set(custom)
        }
        do {
            let reloaded = ToggleShortcut(defaults: defaults) {}
            #expect(reloaded.shortcut == custom)
            reloaded.set(nil)
            #expect(!reloaded.isRegistered)
        }
        let off = ToggleShortcut(defaults: defaults) {}
        #expect(off.shortcut == nil)
    }

    @Test func aCombinationAlreadyInUseIsReported() throws {
        // An unusual combination, so no other app on the machine is likely to hold it.
        let combo = HotKeyShortcut(keyCode: UInt32(kVK_F19), carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
                                   keyName: "F19")
        let first = GlobalHotKey {}
        let second = GlobalHotKey {}
        try first.register(combo)
        #expect(first.isRegistered)
        #expect(throws: GlobalHotKey.RegistrationError.taken) { try second.register(combo) }
        first.unregister()
        try second.register(combo) // free again
        #expect(second.isRegistered)
        second.unregister()
    }
}

@MainActor
struct GlobalHotKeyDispatchTests {
    /// Sends the same Carbon event the system sends when the combination is pressed.
    private func press(_ hotKey: GlobalHotKey) {
        var event: EventRef?
        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeNone), &event)
        guard let event else { return }
        defer { ReleaseEvent(event) }
        var id = EventHotKeyID(signature: OSType(0x4653_4E4D), id: hotKey.id)
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          MemoryLayout<EventHotKeyID>.size, &id)
        SendEventToEventTarget(event, GetApplicationEventTarget())
    }

    @Test func aPressedHotKeyRunsItsOwnAction() throws {
        var fired: [String] = []
        let a = GlobalHotKey { fired.append("a") }
        let b = GlobalHotKey { fired.append("b") }
        press(a)
        press(b)
        press(a)
        #expect(fired == ["a", "b", "a"])
    }

    @Test func theToggleSettingTriggersItsAction() throws {
        let suite = "FusenTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var toggles = 0
        let setting = ToggleShortcut(defaults: defaults) { toggles += 1 }
        setting.set(HotKeyShortcut(keyCode: UInt32(kVK_F18), carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
                                   keyName: "F18"))
        #expect(setting.isRegistered)
        #expect(setting.errorMessage == nil)
        press(setting.hotKeyForTesting)
        #expect(toggles == 1)
    }
}
