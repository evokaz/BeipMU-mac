import AppKit

/// The result of asking whether the current editor values should be kept.
/// This is intentionally internal so the editors can share the prompt flow
/// without adding another public UI API.
enum SettingsPromptDecision {
    case save
    case dontSave
    case cancel

    static var discard: Self { .dontSave }
}

typealias SettingsPromptDecisionProvider = @MainActor (String) -> SettingsPromptDecision

enum SettingsPromptPresenter {
    @MainActor
    static func present(window: NSWindow?, editorTitle: String) -> SettingsPromptDecision {
        let alert = NSAlert()
        alert.messageText = "Save changes to \(editorTitle)?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")

        // `runModal()` is deliberately used here so the same synchronous
        // decision path is available to the window delegate and to callers
        // that do not currently have a visible key window.
        _ = window
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .dontSave
        default: return .cancel
        }
    }
}
