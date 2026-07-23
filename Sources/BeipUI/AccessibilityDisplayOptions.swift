import AppKit

struct AccessibilityDisplayOptions: Sendable, Equatable {
    var increaseContrast = false
    var differentiateWithoutColor = false
    var reduceTransparency = false
    var reduceMotion = false

    static var current: Self {
        let environment = ProcessInfo.processInfo.environment
        let workspace = NSWorkspace.shared
        return .init(
            increaseContrast: environment["BEIPMU_FORCE_INCREASE_CONTRAST"] == "1"
                || workspace.accessibilityDisplayShouldIncreaseContrast,
            differentiateWithoutColor: environment["BEIPMU_FORCE_DIFFERENTIATE_WITHOUT_COLOR"] == "1"
                || workspace.accessibilityDisplayShouldDifferentiateWithoutColor,
            reduceTransparency: environment["BEIPMU_FORCE_REDUCE_TRANSPARENCY"] == "1"
                || workspace.accessibilityDisplayShouldReduceTransparency,
            reduceMotion: environment["BEIPMU_FORCE_REDUCE_MOTION"] == "1"
                || workspace.accessibilityDisplayShouldReduceMotion
        )
    }
}

@MainActor
final class KeyboardFocusableButton: NSButton {
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 48 else { super.keyDown(with: event); return }
        let backwards = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
        let target = backwards ? previousKeyView : nextKeyView
        if let target, window?.makeFirstResponder(target) == true { return }
        super.keyDown(with: event)
    }
}
