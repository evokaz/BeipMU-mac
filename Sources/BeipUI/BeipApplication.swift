import AppKit

@MainActor
public enum BeipApplication {
    private static var retainedDelegate: ApplicationDelegate?

    public static func run() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = ApplicationDelegate()
        retainedDelegate = delegate
        application.delegate = delegate
        application.run()
        fatalError("NSApplication.run unexpectedly returned")
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var windows: [ClientWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        newWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func newWindow(_ sender: Any?) {
        let controller = ClientWindowController()
        windows.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windows.removeAll { $0 === controller }
        }
        controller.showWindow(sender)
    }

    @objc func connect(_ sender: Any?) { activeController?.showConnectDialog() }
    @objc func disconnect(_ sender: Any?) { activeController?.disconnect() }
    @objc func clear(_ sender: Any?) { activeController?.clearOutput() }

    private var activeController: ClientWindowController? {
        NSApplication.shared.keyWindow?.windowController as? ClientWindowController ?? windows.last
    }

    private func configureMenu() {
        let main = NSMenu()
        NSApplication.shared.mainMenu = main

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About BeipMU", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit BeipMU", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let connectionItem = NSMenuItem()
        main.addItem(connectionItem)
        let connectionMenu = NSMenu(title: "Connection")
        connectionItem.submenu = connectionMenu
        connectionMenu.addItem(withTitle: "Connect…", action: #selector(connect(_:)), keyEquivalent: "[")
        connectionMenu.addItem(withTitle: "Disconnect", action: #selector(disconnect(_:)), keyEquivalent: "]")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Clear Output", action: #selector(clear(_:)), keyEquivalent: "k")

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApplication.shared.windowsMenu = windowMenu
    }
}

