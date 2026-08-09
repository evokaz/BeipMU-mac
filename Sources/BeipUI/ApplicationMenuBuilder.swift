import AppKit

/// Builds the application commands exposed by both the tab-bar menu and the
/// native BeipMU menu-bar item.
@MainActor
enum ApplicationMenuBuilder {
    static func makeMenu(
        shortcuts: [ShortcutAction: KeyboardShortcut] = KeyboardShortcutStore.load(),
        registerShortcutItem: ((ShortcutAction, NSMenuItem) -> Void)? = nil
    ) -> NSMenu {
        let menu = NSMenu(title: "BeipMU")
        menu.autoenablesItems = false
        addWindowsSubmenu(to: menu, shortcuts: shortcuts, registerShortcutItem: registerShortcutItem)
        addToolsSubmenu(to: menu, shortcuts: shortcuts, registerShortcutItem: registerShortcutItem)
        addSettingsItems(to: menu, shortcuts: shortcuts, registerShortcutItem: registerShortcutItem)
        addHelpSubmenu(to: menu)
        addQuitItem(to: menu)
        return menu
    }

    static func makeToolsMenu(
        shortcuts: [ShortcutAction: KeyboardShortcut] = KeyboardShortcutStore.load(),
        registerShortcutItem: ((ShortcutAction, NSMenuItem) -> Void)? = nil
    ) -> NSMenu {
        let menu = NSMenu(title: "Tools")
        menu.autoenablesItems = false
        addToolsItems(to: menu, shortcuts: shortcuts, registerShortcutItem: registerShortcutItem)
        return menu
    }

    static func addWindowItems(
        to menu: NSMenu,
        includeCreationItems: Bool = true,
        includeInputHistory: Bool = true,
        shortcuts: [ShortcutAction: KeyboardShortcut] = KeyboardShortcutStore.load(),
        registerShortcutItem: ((ShortcutAction, NSMenuItem) -> Void)? = nil
    ) {
        if includeCreationItems {
            addShortcutItem(
                to: menu,
                title: "New Tab",
                action: #selector(ApplicationDelegate.newTab(_:)),
                shortcutAction: .newTab,
                shortcuts: shortcuts,
                registerShortcutItem: registerShortcutItem
            )
            addShortcutItem(
                to: menu,
                title: "New Window",
                action: #selector(ApplicationDelegate.newWindow(_:)),
                shortcutAction: .newWindow,
                shortcuts: shortcuts,
                registerShortcutItem: registerShortcutItem
            )
            menu.addItem(applicationMenuItem(
                title: "New Input Window",
                action: #selector(ApplicationDelegate.newInputWindow(_:))
            ))
            menu.addItem(applicationMenuItem(
                title: "New Edit Window",
                action: #selector(ApplicationDelegate.newEditWindow(_:))
            ))
            menu.addItem(.separator())
        }
        if includeInputHistory {
            addShortcutItem(
                to: menu,
                title: "Toggle Input History",
                action: #selector(ApplicationDelegate.toggleInputHistoryWindow(_:)),
                shortcutAction: .toggleInputHistory,
                shortcuts: shortcuts,
                registerShortcutItem: registerShortcutItem
            )
        }
        menu.addItem(applicationMenuItem(
            title: "Toggle Map Window",
            action: #selector(ApplicationDelegate.toggleMapWindow(_:))
        ))
        menu.addItem(applicationMenuItem(
            title: "Toggle Character Notes Window",
            action: #selector(ApplicationDelegate.toggleCharacterNotesWindow(_:))
        ))
        menu.addItem(.separator())
        menu.addItem(applicationMenuItem(
            title: "Copy all window settings",
            action: #selector(ApplicationDelegate.copyAllWindowSettings(_:))
        ))
        menu.addItem(applicationMenuItem(
            title: "Paste all window settings",
            action: #selector(ApplicationDelegate.pasteAllWindowSettings(_:))
        ))
        menu.addItem(.separator())
        menu.addItem(applicationMenuItem(
            title: "Show Hidden Captions",
            action: #selector(ApplicationDelegate.showHiddenCaptions(_:))
        ))
    }

    private static func addWindowsSubmenu(
        to menu: NSMenu,
        shortcuts: [ShortcutAction: KeyboardShortcut],
        registerShortcutItem: ((ShortcutAction, NSMenuItem) -> Void)?
    ) {
        let windowsMenu = NSMenu(title: "Windows")
        addWindowItems(
            to: windowsMenu,
            shortcuts: shortcuts,
            registerShortcutItem: registerShortcutItem
        )
        menu.addItem(submenuItem(title: "Windows", menu: windowsMenu))
    }

    private static func addToolsSubmenu(
        to menu: NSMenu,
        shortcuts: [ShortcutAction: KeyboardShortcut],
        registerShortcutItem: ((ShortcutAction, NSMenuItem) -> Void)?
    ) {
        let toolsMenu = NSMenu(title: "Tools")
        addToolsItems(
            to: toolsMenu,
            shortcuts: shortcuts,
            registerShortcutItem: registerShortcutItem
        )
        menu.addItem(submenuItem(title: "Tools", menu: toolsMenu))
    }

    private static func addToolsItems(
        to menu: NSMenu,
        shortcuts: [ShortcutAction: KeyboardShortcut],
        registerShortcutItem: ((ShortcutAction, NSMenuItem) -> Void)?
    ) {
        addShortcutItem(
            to: menu,
            title: "Triggers…",
            action: #selector(ApplicationDelegate.editTriggers(_:)),
            shortcutAction: .triggers,
            shortcuts: shortcuts,
            registerShortcutItem: registerShortcutItem
        )
        addShortcutItem(
            to: menu,
            title: "Macros…",
            action: #selector(ApplicationDelegate.editMacros(_:)),
            shortcutAction: .macros,
            shortcuts: shortcuts,
            registerShortcutItem: registerShortcutItem
        )
        addShortcutItem(
            to: menu,
            title: "Aliases…",
            action: #selector(ApplicationDelegate.editAliases(_:)),
            shortcutAction: .aliases,
            shortcuts: shortcuts,
            registerShortcutItem: registerShortcutItem
        )
        menu.addItem(.separator())
        menu.addItem(applicationMenuItem(
            title: "Trigger Debugger",
            action: #selector(ApplicationDelegate.debugTriggers(_:))
        ))
        menu.addItem(applicationMenuItem(
            title: "Alias Debugger",
            action: #selector(ApplicationDelegate.debugAliases(_:))
        ))
        menu.addItem(applicationMenuItem(
            title: "Network Debugger",
            action: #selector(ApplicationDelegate.debugNetwork(_:))
        ))
        addShortcutItem(
            to: menu,
            title: "Smart Paste…",
            action: #selector(ApplicationDelegate.smartPaste(_:)),
            shortcutAction: .smartPaste,
            shortcuts: shortcuts,
            registerShortcutItem: registerShortcutItem
        )
    }

    private static func addSettingsItems(
        to menu: NSMenu,
        shortcuts: [ShortcutAction: KeyboardShortcut],
        registerShortcutItem: ((ShortcutAction, NSMenuItem) -> Void)?
    ) {
        addShortcutItem(
            to: menu,
            title: "Logging…",
            action: #selector(ApplicationDelegate.logging(_:)),
            shortcutAction: .logging,
            shortcuts: shortcuts,
            registerShortcutItem: registerShortcutItem
        )
        menu.addItem(applicationMenuItem(
            title: "Settings…",
            action: #selector(ApplicationDelegate.settings(_:)),
            shortcut: FixedShortcut.settings
        ))
        menu.addItem(applicationMenuItem(
            title: "Global Output Settings…",
            action: #selector(ApplicationDelegate.globalTextWindowSettings(_:))
        ))
        menu.addItem(applicationMenuItem(
            title: "Global Input Settings…",
            action: #selector(ApplicationDelegate.globalInputWindowSettings(_:))
        ))
    }

    private static func addHelpSubmenu(to menu: NSMenu) {
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(applicationMenuItem(
            title: "BeipMU Help",
            action: #selector(ApplicationDelegate.showHelp(_:)),
            shortcut: FixedShortcut.help
        ))
        menu.addItem(submenuItem(title: "Help", menu: helpMenu))
    }

    private static func addQuitItem(to menu: NSMenu) {
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Close all Windows and Exit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: FixedShortcut.quit.keyEquivalent
        )
        quit.keyEquivalentModifierMask = FixedShortcut.quit.modifiers
        quit.target = NSApplication.shared
        quit.isEnabled = true
        menu.addItem(quit)
    }

    private static func submenuItem(title: String, menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        item.isEnabled = true
        return item
    }

    private static func applicationMenuItem(
        title: String,
        action: Selector,
        shortcut: KeyboardShortcut? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: shortcut?.keyEquivalent ?? ""
        )
        if let shortcut {
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
        item.target = NSApplication.shared.delegate
        item.isEnabled = NSApplication.shared.delegate != nil
        return item
    }

    private static func addShortcutItem(
        to menu: NSMenu,
        title: String,
        action: Selector,
        shortcutAction: ShortcutAction,
        shortcuts: [ShortcutAction: KeyboardShortcut],
        registerShortcutItem: ((ShortcutAction, NSMenuItem) -> Void)?
    ) {
        let item = applicationMenuItem(
            title: title,
            action: action,
            shortcut: shortcuts[shortcutAction] ?? shortcutAction.defaultShortcut
        )
        menu.addItem(item)
        registerShortcutItem?(shortcutAction, item)
    }
}
