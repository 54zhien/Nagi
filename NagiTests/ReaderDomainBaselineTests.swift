import XCTest
@testable import Nagi

/// Pins domain-level behaviour that the reader refactor must keep intact:
/// layout clamping, mutation merging, legacy font names and theme mapping.
final class ReaderDomainBaselineTests: XCTestCase {

    // MARK: - ReaderLayoutMetrics

    func testClampsStayInsideTheirDocumentedRanges() {
        XCTAssertEqual(ReaderLayoutMetrics.clampPageMargins(0), 16, accuracy: 0.0001)
        XCTAssertEqual(ReaderLayoutMetrics.clampPageMargins(100), 48, accuracy: 0.0001)
        XCTAssertEqual(ReaderLayoutMetrics.clampLineHeight(0.1), 0.80, accuracy: 0.0001)
        XCTAssertEqual(ReaderLayoutMetrics.clampLineHeight(9), 2.50, accuracy: 0.0001)
        XCTAssertEqual(ReaderLayoutMetrics.clampCharacterSpacing(-99), -10, accuracy: 0.0001)
        XCTAssertEqual(ReaderLayoutMetrics.clampWordSpacing(99), 20, accuracy: 0.0001)
    }

    func testValuesWithinRangeAreUnchanged() {
        XCTAssertEqual(ReaderLayoutMetrics.clampPageMargins(30), 30, accuracy: 0.0001)
        XCTAssertEqual(ReaderLayoutMetrics.clampLineHeight(1.5), 1.5, accuracy: 0.0001)
        XCTAssertEqual(ReaderLayoutMetrics.clampCharacterSpacing(0), 0, accuracy: 0.0001)
        XCTAssertEqual(ReaderLayoutMetrics.clampWordSpacing(0), 0, accuracy: 0.0001)
    }

    func testPageMarginFactorIsRelativeToTheBaseMargin() {
        XCTAssertEqual(ReaderLayoutMetrics.pageMarginFactor(for: 24), 1, accuracy: 0.0001)
        XCTAssertEqual(ReaderLayoutMetrics.pageMarginFactor(for: 48), 2, accuracy: 0.0001)
        XCTAssertEqual(ReaderLayoutMetrics.pageMarginFactor(for: 0), 16.0 / 24.0, accuracy: 0.0001)
    }

    func testLegacyMarginMigratorsMatchTheirStoredFormats() {
        XCTAssertEqual(ReaderLayoutMetrics.migrateLegacyPageMargins(nil), 24, accuracy: 0.0001)
        XCTAssertEqual(ReaderLayoutMetrics.migrateLegacyPageMargins(2), 48, accuracy: 0.0001)
        XCTAssertEqual(ReaderLayoutMetrics.migrateLegacyPageMarginAdjustment(nil), 24, accuracy: 0.0001)
        XCTAssertEqual(ReaderLayoutMetrics.migrateLegacyPageMarginAdjustment(-100), 16, accuracy: 0.0001)
    }

    // MARK: - ReaderVisualMutationKind

    func testMergingTheSameMutationKeepsIt() {
        XCTAssertEqual(ReaderVisualMutationKind.font.merged(with: .font), .font)
        XCTAssertEqual(ReaderVisualMutationKind.theme.merged(with: .theme), .theme)
        XCTAssertEqual(ReaderVisualMutationKind.geometry.merged(with: .geometry), .geometry)
    }

    func testMergingDifferentMutationsCollapsesToFull() {
        XCTAssertEqual(ReaderVisualMutationKind.font.merged(with: .typography), .full)
        XCTAssertEqual(ReaderVisualMutationKind.geometry.merged(with: .font), .full)
        XCTAssertEqual(ReaderVisualMutationKind.theme.merged(with: .full), .full)
    }

    // MARK: - ReaderFontFamily 旧值兼容

    func testLegacyFontFamilyNamesDecodeToOriginal() throws {
        let legacyNames = [
            "systemSerif",
            "systemSansSerif",
            "palatino",
            "athelas",
            "openDyslexic",
            "installed:SomeFont",
        ]
        for name in legacyNames {
            let decoded = try JSONDecoder().decode(ReaderFontFamily.self, from: Data("\"\(name)\"".utf8))
            XCTAssertEqual(decoded, .original, "旧字体名 \(name) 应回退到 original")
        }
    }

    func testUnknownFontFamilyNameFallsBackToOriginal() throws {
        let decoded = try JSONDecoder().decode(ReaderFontFamily.self, from: Data("\"not-a-font\"".utf8))
        XCTAssertEqual(decoded, .original)
    }

    func testCurrentFontFamilyNamesRoundTrip() throws {
        for family in ReaderFontFamily.allCases {
            let data = try JSONEncoder().encode(family)
            XCTAssertEqual(try JSONDecoder().decode(ReaderFontFamily.self, from: data), family)
        }
    }

    // MARK: - 主题预设映射

    func testThemePresetPaletteMapping() {
        XCTAssertEqual(ReaderThemePreset.original.paletteTheme, .light)
        XCTAssertEqual(ReaderThemePreset.quiet.paletteTheme, .quiet)
        XCTAssertEqual(ReaderThemePreset.paper.paletteTheme, .sepia)
    }

    func testThemePresetRawValuesAreStable() {
        // Raw values are persisted, so they must not be renamed casually.
        XCTAssertEqual(ReaderThemePreset.original.rawValue, "original")
        XCTAssertEqual(ReaderThemePreset.quiet.rawValue, "quiet")
        XCTAssertEqual(ReaderThemePreset.paper.rawValue, "paper")
        XCTAssertEqual(ReaderPageTransition.pageCurl.rawValue, "pageCurl")
        XCTAssertEqual(ReaderAppearanceMode.system.rawValue, "system")
    }

    // MARK: - 偏好差异（全项目唯一实现）

    func testDiffOfIdenticalPreferencesKeepsTheConservativeResult() {
        let preferences = ReaderPreferences()
        XCTAssertEqual(
            ReaderVisualMutationKind.diff(from: preferences, to: preferences),
            .full
        )
    }

    func testDiffDetectsThemeChange() {
        var preset = ReaderPreferences()
        preset.themePreset = .paper
        XCTAssertEqual(ReaderVisualMutationKind.diff(from: ReaderPreferences(), to: preset), .theme)

        var mode = ReaderPreferences()
        mode.appearanceMode = .dark
        XCTAssertEqual(ReaderVisualMutationKind.diff(from: ReaderPreferences(), to: mode), .theme)
    }

    func testDiffDetectsFontChange() {
        var size = ReaderPreferences()
        size.fontSize = 23
        XCTAssertEqual(ReaderVisualMutationKind.diff(from: ReaderPreferences(), to: size), .font)

        var family = ReaderPreferences()
        family.fontFamily = .kai
        XCTAssertEqual(ReaderVisualMutationKind.diff(from: ReaderPreferences(), to: family), .font)

        var bold = ReaderPreferences()
        bold.boldText = true
        XCTAssertEqual(ReaderVisualMutationKind.diff(from: ReaderPreferences(), to: bold), .font)
    }

    func testDiffDetectsTypographyChange() {
        var height = ReaderPreferences()
        height.lineHeight = 2.0
        XCTAssertEqual(ReaderVisualMutationKind.diff(from: ReaderPreferences(), to: height), .typography)

        var spacing = ReaderPreferences()
        spacing.characterSpacing = 4
        XCTAssertEqual(ReaderVisualMutationKind.diff(from: ReaderPreferences(), to: spacing), .typography)

        var styles = ReaderPreferences()
        styles.publisherStyles = true
        XCTAssertEqual(ReaderVisualMutationKind.diff(from: ReaderPreferences(), to: styles), .typography)
    }

    func testDiffDetectsGeometryChange() {
        var margins = ReaderPreferences()
        margins.pageMargins = 40
        XCTAssertEqual(ReaderVisualMutationKind.diff(from: ReaderPreferences(), to: margins), .geometry)

        var transition = ReaderPreferences()
        transition.pageTransition = .pageCurl
        XCTAssertEqual(ReaderVisualMutationKind.diff(from: ReaderPreferences(), to: transition), .geometry)

        var header = ReaderPreferences()
        header.showBookTitleInPageHeader = true
        XCTAssertEqual(ReaderVisualMutationKind.diff(from: ReaderPreferences(), to: header), .geometry)
    }

    func testDiffOfTwoCategoriesCollapsesToFull() {
        var next = ReaderPreferences()
        next.fontSize = 23
        next.lineHeight = 2.0
        XCTAssertEqual(ReaderVisualMutationKind.diff(from: ReaderPreferences(), to: next), .full)
    }
}
