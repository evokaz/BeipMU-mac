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
        switch mode {
        case .system:
            return .init(
                foreground: .textColor,
                background: .textBackgroundColor,
                chrome: .windowBackgroundColor,
                accent: .controlAccentColor,
                appearance: nil
            )
        case .light:
            return .init(
                foreground: NSColor(calibratedWhite: 0.08, alpha: 1),
                background: NSColor(calibratedWhite: 0.98, alpha: 1),
                chrome: NSColor(calibratedWhite: 0.92, alpha: 1),
                accent: .controlAccentColor,
                appearance: NSAppearance(named: .aqua)
            )
        case .dark:
            return .init(
                foreground: NSColor(calibratedWhite: 0.9, alpha: 1),
                background: NSColor(calibratedWhite: 0.05, alpha: 1),
                chrome: NSColor(calibratedWhite: 0.12, alpha: 1),
                accent: .controlAccentColor,
                appearance: NSAppearance(named: .darkAqua)
            )
        case .custom:
            let foreground = NSColor(hexString: foregroundHex) ?? NSColor(calibratedWhite: 0.9, alpha: 1)
            let background = NSColor(hexString: backgroundHex) ?? NSColor(calibratedWhite: 0.05, alpha: 1)
            let accent = NSColor(hexString: accentHex) ?? .controlAccentColor
            return .init(
                foreground: foreground,
                background: background,
                chrome: background.blended(withFraction: 0.12, of: foreground) ?? background,
                accent: accent,
                appearance: background.perceivedBrightness < 0.5
                    ? NSAppearance(named: .darkAqua)
                    : NSAppearance(named: .aqua)
            )
        }
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
}
