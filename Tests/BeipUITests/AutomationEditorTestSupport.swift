import AppKit
import BeipPersistence
@testable import BeipUI
import XCTest

@MainActor
enum AutomationEditorTestSupport {
    static func backgroundColor(in value: NSAttributedString, at location: Int) -> NSColor? {
        value.attribute(.backgroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    static func row(titled title: String, in outline: NSOutlineView) -> Int? {
        for row in 0..<outline.numberOfRows {
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  cell.textField?.stringValue == title else { continue }
            return row
        }
        return nil
    }

    static func recursiveSubviews(of root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { recursiveSubviews(of: $0) }
    }

    static func triggerOutline(in content: NSView) throws -> NSOutlineView {
        try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "triggerScopeOutline" }
        )
    }

    static func textField(identifier: String, in content: NSView) throws -> NSTextField {
        try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == identifier }
        )
    }

    static func textView(identifier: String, in content: NSView) throws -> NSTextView {
        try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSTextView }
                .first { $0.accessibilityIdentifier() == identifier }
        )
    }

    static func button(titled title: String, in content: NSView) throws -> NSButton {
        try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSButton }
                .first { $0.title == title }
        )
    }

    static func button(identifier: String, in content: NSView) throws -> NSButton {
        try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == identifier }
        )
    }

    static func workspaceWithNestedGlobalTrigger() throws -> LegacyConfigurationWorkspace {
        try workspace(
            """
            Version=331
            Connections {
              Triggers {
                Active=true
                { Description="Parent" FindString { MatchText="parent" }
                  Triggers {
                    Active=true
                    { Description="Child" FindString { MatchText="child" } }
                  }
                }
              }
            }
            """
        )
    }

    static func workspaceWithNestedGlobalAlias() throws -> LegacyConfigurationWorkspace {
        try workspace(
            """
            Version=331
            Connections {
              Aliases {
                Active=true Echo=true ProcessCommands=false
                { Description="Folder" Folder=true FindString.MatchText=""
                  Aliases { Active=true AfterCount=0
                    { Description="Child" Example="old" Replace="old" FindString.MatchText="x" }
                  }
                }
              }
            }
            """
        )
    }

    static func workspace(_ source: String) throws -> LegacyConfigurationWorkspace {
        try LegacyConfigurationWorkspace(document: .init(source: source))
    }
}
