import BeipCore
import Foundation
import XCTest

final class ANSISettingsTests: XCTestCase {
    func testDefaultsAndColorOrdering() {
        let settings = ANSISettings.default
        XCTAssertEqual(settings.colors.count, 16)
        XCTAssertEqual(ANSIColorName.allCases, [
            .black, .red, .green, .yellow, .blue, .magenta, .cyan, .white,
            .boldBlack, .boldRed, .boldGreen, .boldYellow, .boldBlue, .boldMagenta, .boldCyan, .boldWhite,
        ])
        XCTAssertTrue(settings.preventInvisible)
        XCTAssertFalse(settings.resetOnNewLine)
        XCTAssertFalse(settings.fontBold)
        XCTAssertTrue(settings.parseBlinking)
        XCTAssertTrue(settings.beep)
        XCTAssertTrue(settings.beepSystem)
        XCTAssertTrue(settings.parse)
        XCTAssertEqual(settings.flashSpeed, 500)
        XCTAssertEqual(settings.colors, ANSIPalettePreset.xTerm.colors)
        XCTAssertTrue(settings.colors.allSatisfy { $0.alpha == 255 })
    }

    func testParseBlinkingPreservesLegacyIntervalUntilItsLogicalValueChanges() {
        var settings = ANSISettings(flashSpeed: 250)
        XCTAssertTrue(settings.parseBlinking)
        XCTAssertEqual(settings.flashSpeed, 250)

        settings.parseBlinking = true
        XCTAssertEqual(settings.flashSpeed, 250)

        settings.parseBlinking = false
        XCTAssertEqual(settings.flashSpeed, 0)
        settings.parseBlinking = true
        XCTAssertEqual(settings.flashSpeed, 500)
    }

    func testDecodesLegacyBooleanOnlyBlinkingSetting() throws {
        let settings = try JSONDecoder().decode(
            ANSISettings.self,
            from: Data(#"{"parseBlinking":false}"#.utf8)
        )

        XCTAssertFalse(settings.parseBlinking)
        XCTAssertEqual(settings.flashSpeed, 0)
    }

    func testEveryOriginalPresetHasExactValues() {
        let expected: [ANSIPalettePreset: [[Int]]] = [
            .xTerm: [[0,0,0],[205,0,0],[0,205,0],[205,205,0],[0,0,238],[205,0,205],[0,205,205],[229,229,229],[127,127,127],[255,0,0],[0,255,0],[255,255,0],[92,92,255],[255,0,255],[0,255,255],[255,255,255]],
            .cmd: [[0,0,0],[128,0,0],[0,128,0],[128,128,0],[0,0,128],[128,0,128],[0,128,128],[192,192,192],[128,128,128],[255,0,0],[0,255,0],[255,255,0],[0,0,255],[255,0,255],[0,255,255],[255,255,255]],
            .vga: [[0,0,0],[170,0,0],[0,170,0],[170,85,0],[0,0,170],[170,0,170],[0,170,170],[170,170,170],[85,85,85],[255,85,85],[85,255,85],[255,255,85],[85,85,255],[255,85,255],[85,255,255],[255,255,255]],
            .old: [[0,0,0],[255,0,0],[0,255,0],[192,192,0],[0,0,255],[192,0,192],[0,192,192],[192,192,192],[128,128,128],[255,128,128],[128,255,128],[255,255,0],[128,128,255],[255,0,255],[0,255,255],[255,255,255]],
            .bright: [[0,0,0],[255,0,0],[0,255,0],[255,255,0],[0,0,255],[255,0,255],[0,255,255],[255,255,255],[128,128,128],[255,128,128],[128,255,128],[255,255,128],[128,128,255],[255,128,255],[128,255,255],[255,255,255]],
        ]
        for preset in ANSIPalettePreset.allCases {
            for (actual, expected) in zip(preset.colors, expected[preset] ?? []) {
                XCTAssertEqual([Int(actual.red), Int(actual.green), Int(actual.blue)], expected, preset.rawValue)
            }
        }
    }
}
