import AppKit

@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    private enum Links {
        static let projectGitHub: URL = URL(string: "https://github.com/evokaz/BeipMU-mac")!
        static let originalDeveloper = URL(string: "https://beipdev.github.io/BeipMU/")!
    }

    init(bundle: Bundle = .main) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "About BeipMU for Mac"
        panel.setAccessibilityIdentifier("aboutWindow")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        super.init(window: panel)
        panel.delegate = self
        configureContent(in: panel, bundle: bundle)
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func configureContent(in panel: NSPanel, bundle: Bundle) {
        let icon = NSImageView()
        icon.image = NSApplication.shared.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel("BeipMU for Mac application icon")
        icon.translatesAutoresizingMaskIntoConstraints = false

        let appName = NSTextField(labelWithString: "BeipMU for Mac")
        appName.font = .systemFont(ofSize: 26, weight: .semibold)
        appName.setAccessibilityIdentifier("aboutAppName")

        let version = NSTextField(labelWithString: Self.versionDescription(bundle: bundle))
        version.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        version.textColor = .secondaryLabelColor
        version.setAccessibilityIdentifier("aboutVersion")

        let headingStack = NSStackView(views: [appName, version])
        headingStack.orientation = .vertical
        headingStack.alignment = .leading
        headingStack.spacing = 5

        let header = NSStackView(views: [icon, headingStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 20

        let separator = NSBox()
        separator.boxType = .separator

        let projectLabel = NSTextField(labelWithString: "Project GitHub")
        projectLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let projectLink = linkButton(
            title: Links.projectGitHub.absoluteString,
            action: #selector(openProjectGitHub(_:)),
            identifier: "aboutProjectGitHub"
        )

        let projectRow = NSStackView(views: [projectLabel, projectLink])
        projectRow.orientation = .horizontal
        projectRow.alignment = .firstBaseline
        projectRow.spacing = 8

        let thanks = NSTextField(wrappingLabelWithString:
            "Special thanks to BeipDev, the original developer, for creating BeipMU and making its source code available."
        )
        thanks.textColor = .secondaryLabelColor

        let originalProjectLabel = NSTextField(labelWithString: "Original Project:")
        originalProjectLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        originalProjectLabel.setAccessibilityIdentifier("aboutOriginalProjectLabel")

        let originalLink = linkButton(
            title: Links.originalDeveloper.absoluteString,
            action: #selector(openOriginalDeveloperWebsite(_:)),
            identifier: "aboutOriginalDeveloperLink"
        )

        let originalProjectRow = NSStackView(views: [originalProjectLabel, originalLink])
        originalProjectRow.orientation = .horizontal
        originalProjectRow.alignment = .firstBaseline
        originalProjectRow.spacing = 8

        let content = NSStackView(views: [header, separator, projectRow, thanks, originalProjectRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false

        panel.contentView = NSView()
        panel.contentView?.addSubview(content)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            separator.widthAnchor.constraint(equalTo: content.widthAnchor),
            projectRow.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
            originalProjectRow.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
            thanks.widthAnchor.constraint(equalTo: content.widthAnchor),
            content.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -32),
            content.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 28),
            content.bottomAnchor.constraint(lessThanOrEqualTo: panel.contentView!.bottomAnchor, constant: -28),
        ])
    }

    private func linkButton(title: String, action: Selector, identifier: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.contentTintColor = .linkColor
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    @objc private func openProjectGitHub(_ sender: Any?) {
        NSWorkspace.shared.open(Links.projectGitHub)
    }

    @objc private func openOriginalDeveloperWebsite(_ sender: Any?) {
        NSWorkspace.shared.open(Links.originalDeveloper)
    }

    private static func versionDescription(bundle: Bundle) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (version?, build?) where version != build:
            return "Version \(version) (\(build))"
        case let (version?, _):
            return "Version \(version)"
        case let (_, build?):
            return "Version \(build)"
        default:
            return "Development build"
        }
    }
}
