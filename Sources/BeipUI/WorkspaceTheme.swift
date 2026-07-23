import AppKit

struct WorkspaceThemePalette {
    var foreground: NSColor
    var background: NSColor
    var chrome: NSColor
    var accent: NSColor
    var appearance: NSAppearance?
}

extension WorkspaceThemeSettings {
    var palette: WorkspaceThemePalette {
        palette(displayOptions: .current)
    }

    func palette(displayOptions: AccessibilityDisplayOptions) -> WorkspaceThemePalette {
        let base: WorkspaceThemePalette
        switch mode {
        case .system:
            base = .init(
                foreground: .textColor,
                background: .textBackgroundColor,
                chrome: .windowBackgroundColor,
                accent: .controlAccentColor,
                appearance: nil
            )
        case .light:
            base = .init(
                foreground: NSColor(calibratedWhite: 0.08, alpha: 1),
                background: NSColor(calibratedWhite: 0.98, alpha: 1),
                chrome: NSColor(calibratedWhite: 0.92, alpha: 1),
                accent: .controlAccentColor,
                appearance: NSAppearance(named: .aqua)
            )
        case .dark:
            base = .init(
                foreground: NSColor(calibratedWhite: 0.9, alpha: 1),
                background: NSColor(calibratedWhite: 0.05, alpha: 1),
                chrome: NSColor(calibratedWhite: 0.12, alpha: 1),
                accent: .controlAccentColor,
                appearance: NSAppearance(named: .darkAqua)
            )
        case .custom:
            let foreground = NSColor(hexString: foregroundHex) ?? NSColor(calibratedWhite: 0.9, alpha: 1)
            let background = NSColor(hexString: backgroundHex) ?? NSColor(calibratedWhite: 0.05, alpha: 1)
            let accent: NSColor = NSColor(hexString: accentHex) ?? NSColor.controlAccentColor
            base = .init(
                foreground: foreground,
                background: background,
                chrome: background.blended(withFraction: 0.12, of: foreground) ?? background,
                accent: accent,
                appearance: background.perceivedBrightness < 0.5
                    ? NSAppearance(named: .darkAqua)
                    : NSAppearance(named: .aqua)
            )
        }
        guard displayOptions.increaseContrast else { return base }
        let hasStrongTextContrast = base.foreground.contrastRatio(against: base.background) >= 7
        let background = hasStrongTextContrast
            ? base.background
            : (base.background.perceivedBrightness < 0.5 ? NSColor.black : NSColor.white)
        let foreground = hasStrongTextContrast
            ? base.foreground
            : NSColor.maximumContrastColor(against: background)
        let accent = base.accent.contrastRatio(against: background) >= 4.5
            ? base.accent
            : NSColor.maximumContrastColor(against: background)
        let chrome = background.perceivedBrightness < 0.5
            ? NSColor(calibratedWhite: 0.02, alpha: 1)
            : NSColor(calibratedWhite: 0.98, alpha: 1)
        return .init(
            foreground: foreground,
            background: background.withAlphaComponent(1),
            chrome: chrome,
            accent: accent,
            appearance: base.appearance
        )
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        let value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard (hex.count == 6 || hex.count == 8), let number = UInt32(hex, radix: 16) else { return nil }
        let alpha: UInt32 = hex.count == 8 ? number & 0xff : 0xff
        let rgb = hex.count == 8 ? number >> 8 : number
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }

    var perceivedBrightness: CGFloat {
        guard let rgb = usingColorSpace(.deviceRGB) else { return 0 }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
    }

    func contrastRatio(against other: NSColor) -> CGFloat {
        let first = relativeLuminance
        let second = other.relativeLuminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    static func maximumContrastColor(against color: NSColor) -> NSColor {
        let black = NSColor.black
        let white = NSColor.white
        return black.contrastRatio(against: color) >= white.contrastRatio(against: color) ? black : white
    }

    private var relativeLuminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        func component(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * component(rgb.redComponent)
            + 0.7152 * component(rgb.greenComponent)
            + 0.0722 * component(rgb.blueComponent)
    }
}
