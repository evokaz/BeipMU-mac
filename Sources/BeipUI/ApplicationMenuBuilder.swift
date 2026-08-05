import AppKit

/// Builds the application commands exposed by both the tab-bar menu and the
/// native BeipMU menu-bar item.
@MainActor
enum ApplicationMenuBuilder {
    static func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "BeipMU")
        menu.autoenablesItems = false
        addWindowsSubmenu(to: menu)
        addToolsSubmenu(to: menu)
        addSettingsItems(to: menu)
        addHelpSubmenu(to: menu)
        addQuitItem(to: menu)
        return menu
    }

    static func makeToolsMenu() -> NSMenu {
        let menu = NSMenu(title: "Tools")
        menu.autoenablesItems = false
        addToolsItems(to: menu)
        return menu
    }

    static func addWindowItems(
        to menu: NSMenu,
        includeCreationItems: Bool = true,
        includeInputHistory: Bool = true
    ) {
        if includeCreationItems {
            menu.addItem(applicationMenuItem(
                title: "New Tab",
                action: #selector(ApplicationDelegate.newTab(_:)),
                keyEquivalent: "t",
                modifiers: [.control]
            ))
            menu.addItem(applicationMenuItem(
                title: "New Window",
                action: #selector(ApplicationDelegate.newWindow(_:)),
                keyEquivalent: "n",
                modifiers: [.control]
            ))
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
            menu.addItem(applicationMenuItem(
                title: "Toggle Input History",
                action: #selector(ApplicationDelegate.toggleInputHistoryWindow(_:)),
                keyEquivalent: "h",
                modifiers: [.command]
            ))
        }
        menu.addItem(applicationMenuItem(
            title: "Toggle Image Window",
            action: #selector(ApplicationDelegate.toggleImageWindow(_:))
        ))
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

    private static func addWindowsSubmenu(to menu: NSMenu) {
        let windowsMenu = NSMenu(title: "Windows")
        addWindowItems(to: windowsMenu)
        menu.addItem(submenuItem(title: "Windows", menu: windowsMenu))
    }

    private static func addToolsSubmenu(to menu: NSMenu) {
        let toolsMenu = NSMenu(title: "Tools")
        addToolsItems(to: toolsMenu)
        menu.addItem(submenuItem(title: "Tools", menu: toolsMenu))
    }

    private static func addToolsItems(to menu: NSMenu) {
        menu.addItem(applicationMenuItem(
            title: "Triggers…",
            action: #selector(ApplicationDelegate.editTriggers(_:)),
            keyEquivalent: "t",
            modifiers: [.control, .shift]
        ))
        menu.addItem(applicationMenuItem(
            title: "Macros…",
            action: #selector(ApplicationDelegate.editMacros(_:)),
            keyEquivalent: "m",
            modifiers: [.control, .shift]
        ))
        menu.addItem(applicationMenuItem(
            title: "Aliases…",
            action: #selector(ApplicationDelegate.editAliases(_:)),
            keyEquivalent: "a",
            modifiers: [.control, .shift]
        ))
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
        menu.addItem(applicationMenuItem(
            title: "Smart Paste…",
            action: #selector(ApplicationDelegate.smartPaste(_:)),
            keyEquivalent: "v",
            modifiers: [.control, .shift]
        ))
    }

    private static func addSettingsItems(to menu: NSMenu) {
        menu.addItem(applicationMenuItem(
            title: "Logging…",
            action: #selector(ApplicationDelegate.logging(_:)),
            keyEquivalent: "l",
            modifiers: [.control]
        ))
        menu.addItem(applicationMenuItem(
            title: "Settings…",
            action: #selector(ApplicationDelegate.settings(_:)),
            keyEquivalent: ","
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
            keyEquivalent: "?"
        ))
        menu.addItem(submenuItem(title: "Help", menu: helpMenu))
    }

    private static func addQuitItem(to menu: NSMenu) {
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Close all Windows and Exit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
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
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = NSApplication.shared.delegate
        item.isEnabled = NSApplication.shared.delegate != nil
        return item
    }
}
