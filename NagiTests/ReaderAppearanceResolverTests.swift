import ReadiumNavigator
import XCTest
@testable import Nagi

/// Pins how a reader theme, an appearance mode and the system colour scheme
/// combine into the single appearance the whole reader renders with.
final class ReaderAppearanceResolverTests: XCTestCase {
    private func appearance(
        theme: ReaderTheme,
        mode: ReaderAppearanceMode,
        systemIsDark: Bool = false
    ) -> ResolvedReaderAppearance {
        ReaderAppearanceResolver.resolve(
            theme: theme,
            appearanceMode: mode,
            systemIsDark: systemIsDark
        )
    }

    // MARK: - 主题解析

    func testLightAndDarkPalettesAreInterchangeable() {
        // Both neutral palettes resolve identically in every mode, which is
        // why the reader can store either one without changing the rendering.
        for mode in ReaderAppearanceMode.allCases {
            for systemIsDark in [false, true] {
                let light = appearance(theme: .light, mode: mode, systemIsDark: systemIsDark)
                let dark = appearance(theme: .dark, mode: mode, systemIsDark: systemIsDark)
                XCTAssertEqual(light.theme, dark.theme, "mode=\(mode) systemDark=\(systemIsDark)")
                XCTAssertEqual(light.isDark, dark.isDark, "mode=\(mode) systemDark=\(systemIsDark)")
                XCTAssertEqual(
                    light.readiumThemeMarker,
                    dark.readiumThemeMarker,
                    "mode=\(mode) systemDark=\(systemIsDark)"
                )
            }
        }
    }

    func testAppearanceModeOverridesThePalette() {
        XCTAssertEqual(appearance(theme: .light, mode: .dark).theme, .dark)
        XCTAssertEqual(appearance(theme: .dark, mode: .light).theme, .light)
        XCTAssertEqual(appearance(theme: .sepia, mode: .dark).theme, .sepia)
        XCTAssertEqual(appearance(theme: .quiet, mode: .light).theme, .quiet)
    }

    func testSystemModeFollowsTheSystemScheme() {
        XCTAssertEqual(appearance(theme: .light, mode: .system, systemIsDark: true).theme, .dark)
        XCTAssertEqual(appearance(theme: .light, mode: .system, systemIsDark: false).theme, .light)
        XCTAssertEqual(appearance(theme: .sepia, mode: .system, systemIsDark: true).theme, .sepia)
        XCTAssertEqual(appearance(theme: .sepia, mode: .system, systemIsDark: false).theme, .sepia)
    }

    func testIsDarkFollowsTheAppearanceMode() {
        XCTAssertFalse(appearance(theme: .light, mode: .light).isDark)
        XCTAssertTrue(appearance(theme: .light, mode: .dark).isDark)
        XCTAssertTrue(appearance(theme: .light, mode: .system, systemIsDark: true).isDark)
        XCTAssertFalse(appearance(theme: .light, mode: .system, systemIsDark: false).isDark)
    }

    // MARK: - Readium 主题标记

    func testReadiumThemeMarkerMatchesTheResolvedTheme() {
        XCTAssertNil(appearance(theme: .light, mode: .light).readiumThemeMarker)
        XCTAssertEqual(appearance(theme: .light, mode: .dark).readiumThemeMarker, "readium-night-on")
        XCTAssertEqual(appearance(theme: .sepia, mode: .light).readiumThemeMarker, "readium-sepia-on")
    }

    func testSepiaKeepsItsPaletteButRendersDarkUnderADarkAppearance() {
        let result = appearance(theme: .sepia, mode: .dark)
        XCTAssertEqual(result.theme, .sepia)
        XCTAssertTrue(result.isDark)
        XCTAssertEqual(result.readiumThemeMarker, "readium-night-on")
    }

    // MARK: - 颜色

    func testBackgroundAndContentComeFromTheResolvedPalette() {
        let light = appearance(theme: .light, mode: .light)
        XCTAssertEqual(
            light.backgroundColor,
            ReaderTheme.light.readerBackgroundUIColor(isDarkAppearance: false)
        )
        XCTAssertEqual(
            light.contentColor,
            ReaderTheme.light.readerContentUIColor(isDarkAppearance: false)
        )

        let dark = appearance(theme: .light, mode: .dark)
        XCTAssertEqual(
            dark.backgroundColor,
            ReaderTheme.dark.readerBackgroundUIColor(isDarkAppearance: true)
        )
        XCTAssertEqual(
            dark.contentColor,
            ReaderTheme.dark.readerContentUIColor(isDarkAppearance: true)
        )
    }

    func testQuietPaletteHasItsOwnBackground() {
        let quiet = appearance(theme: .quiet, mode: .light)
        XCTAssertEqual(
            quiet.backgroundColor,
            ReaderTheme.quiet.readerBackgroundUIColor(isDarkAppearance: false)
        )
        XCTAssertNotEqual(quiet.backgroundColor, appearance(theme: .light, mode: .light).backgroundColor)
    }
}
