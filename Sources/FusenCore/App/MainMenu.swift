import AppKit

@MainActor
enum MainMenu {
    static func build(appDelegate: AppDelegate) -> NSMenu {
        let appName = "fusen.md"
        let main = NSMenu()

        main.addItem(submenu(appName, [
            item("\(appName)について", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("設定…", #selector(AppDelegate.showSettings(_:)), ",", target: appDelegate),
            item("ログイン時に起動", #selector(AppDelegate.toggleLaunchAtLogin(_:)), target: appDelegate),
            .separator(),
            item("\(appName)を隠す", #selector(NSApplication.hide(_:)), "h"),
            item("ほかを隠す", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("すべてを表示", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("\(appName)を終了", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu("ファイル", [
            item("新規メモ", #selector(AppDelegate.newNote(_:)), "n", target: appDelegate),
            item("閉じる", #selector(NSWindow.performClose(_:)), "w"),
            item("最近閉じたメモを開く", #selector(AppDelegate.reopenLastClosedNote(_:)), "t", [.command, .shift],
                 target: appDelegate),
            .separator(),
            item("メモの履歴…", #selector(AppDelegate.showHistory(_:)), "y", target: appDelegate),
            item("メモのフォルダをFinderで表示", #selector(AppDelegate.revealNotesFolder(_:)), target: appDelegate),
            .separator(),
            item("Notionと今すぐ同期", #selector(AppDelegate.syncNotionNow(_:)), target: appDelegate),
        ]))

        // Without these items, ⌘Z/⌘C/⌘V/⌘A do nothing in a nib-less app.
        main.addItem(submenu("編集", [
            item("取り消す", Selector(("undo:")), "z"),
            item("やり直す", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("カット", #selector(NSText.cut(_:)), "x"),
            item("コピー", #selector(NSText.copy(_:)), "c"),
            item("ペースト", #selector(NSText.paste(_:)), "v"),
            item("すべてを選択", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("検索…", #selector(NSTextView.performFindPanelAction(_:)), "f",
                 tag: Int(NSFindPanelAction.showFindPanel.rawValue)),
        ]))

        let colorItems = NoteColor.allCases.enumerated().map { index, color in
            item(color.title, #selector(NoteWindowController.setNoteColor(_:)), "\(index + 1)", tag: index)
        }
        main.addItem(submenu("メモ", [
            item("常に手前に表示", #selector(NoteWindowController.toggleFloating(_:)), "f", [.command, .option]),
            item("半透明", #selector(NoteWindowController.toggleTranslucent(_:)), "t", [.command, .option]),
            item("すべてのデスクトップに表示", #selector(NoteWindowController.toggleOnAllSpaces(_:)), "a", [.command, .option]),
            item("Markdown記号をすべて表示", #selector(AppDelegate.toggleShowsAllMarkdown(_:)), "m", [.command, .shift],
                 target: appDelegate),
            .separator(),
            item("このメモの履歴…", #selector(NoteWindowController.showNoteHistory(_:)), "y", [.command, .option]),
            item("Notion の内容を取り込む…", #selector(NoteWindowController.importFromNotion(_:))),
            .separator(),
        ] + colorItems))

        let windowMenu = submenu("ウインドウ", [
            item("すべてを手前に移動", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu
        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command,
                             target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        item.tag = tag
        return item
    }
}
