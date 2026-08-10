import AppKit
import Foundation
@testable import BeipUI

enum WorkspaceUITestSupport {
    struct IsolatedDefaults {
        let suiteName: String
        let defaults: UserDefaults
    }

    static func makeIsolatedDefaults() throws -> IsolatedDefaults {
        let suiteName = "WorkspaceUITestSupport.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return .init(suiteName: suiteName, defaults: defaults)
    }

    @MainActor
    static func recursiveSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(recursiveSubviews(of:))
    }

    static func isStandaloneSpawnPane(_ pane: WorkspacePaneKind) -> Bool {
        if case .spawn = pane { return true }
        return false
    }

    @MainActor
    static func pageKeyEvent(keyCode: UInt16) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
