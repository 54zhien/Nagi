import XCTest
@testable import Nagi

/// Pins the one-time migration from the legacy `reader.epub.*` keys onto the
/// shared store, so existing installs keep their settings exactly.
final class ReaderPreferencesMigrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "NagiTests.preferences.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - 无旧值时保持默认

    func testFreshInstallDoesNotCreateAPayload() {
        XCTAssertNil(LegacyReaderPreferences.migrate(defaults: defaults))
        XCTAssertNil(ReaderPreferencesStore.load(defaults: defaults))
    }

    func testMigrationStillMarksItselfAsPerformedOnAFreshInstall() {
        _ = ReaderPreferencesStore.load(defaults: defaults)
        XCTAssertEqual(
            defaults.integer(forKey: ReaderPreferencesStore.migrationVersionKey),
            ReaderPreferencesStore.currentMigrationVersion
        )
    }

    // MARK: - 旧值迁移

    func testLegacyValuesAreMigratedIntoTheSharedPayload() throws {
        defaults.set(1.5, forKey: "reader.epub.fontScale")
        defaults.set("kai", forKey: "reader.epub.fontFamily")
        defaults.set(true, forKey: "reader.epub.boldText")
        defaults.set(1.8, forKey: "reader.epub.lineHeight")
        defaults.set(30.0, forKey: "reader.epub.pageMarginPoints")
        defaults.set(4.0, forKey: "reader.epub.characterSpacing")
        defaults.set(-6.0, forKey: "reader.epub.wordSpacing")
        defaults.set(true, forKey: "reader.epub.publisherStyles")
        // The legacy key stores a ReaderTheme raw value, not a preset one.
        defaults.set("sepia", forKey: "reader.epub.theme")
        defaults.set("dark", forKey: "reader.epub.appearanceMode")
        defaults.set("pageCurl", forKey: "reader.epub.pageTransition")
        defaults.set(true, forKey: "reader.epub.showBookTitleInPageHeader")

        let migrated = try XCTUnwrap(ReaderPreferencesStore.load(defaults: defaults))
        // A legacy scale of 1.5 lands on the nearest discrete level (1.54).
        XCTAssertEqual(migrated.fontSizeLevel, 3)
        XCTAssertEqual(migrated.fontFamily, .kai)
        XCTAssertTrue(migrated.boldText)
        XCTAssertEqual(migrated.lineHeight, 1.8, accuracy: 0.0001)
        XCTAssertEqual(migrated.pageMargins, 30, accuracy: 0.0001)
        XCTAssertEqual(migrated.characterSpacing, 4, accuracy: 0.0001)
        XCTAssertEqual(migrated.wordSpacing, -6, accuracy: 0.0001)
        XCTAssertTrue(migrated.publisherStyles)
        XCTAssertEqual(migrated.themePreset, .paper)
        XCTAssertEqual(migrated.appearanceMode, .dark)
        XCTAssertEqual(migrated.pageTransition, .pageCurl)
        XCTAssertTrue(migrated.showBookTitleInPageHeader)
    }

    func testFontScaleIsClampedWhenMigrating() throws {
        defaults.set(99.0, forKey: "reader.epub.fontScale")
        let migrated = try XCTUnwrap(LegacyReaderPreferences.migrate(defaults: defaults))
        XCTAssertEqual(migrated.fontSizeLevel, ReaderFontSize.maximumLevel)
    }

    func testLegacyFontSizeLevelWinsOverTheOlderScale() throws {
        defaults.set(7, forKey: "reader.epub.fontSizeLevel")
        defaults.set(1.5, forKey: "reader.epub.fontScale")
        let migrated = try XCTUnwrap(LegacyReaderPreferences.migrate(defaults: defaults))
        XCTAssertEqual(migrated.fontSizeLevel, 7)
    }

    func testLegacyFontSizeLevelIsClamped() throws {
        defaults.set(99, forKey: "reader.epub.fontSizeLevel")
        let migrated = try XCTUnwrap(LegacyReaderPreferences.migrate(defaults: defaults))
        XCTAssertEqual(migrated.fontSizeLevel, ReaderFontSize.maximumLevel)
    }

    func testPageMarginPointsWinOverTheOtherLegacyFormats() throws {
        defaults.set(40.0, forKey: "reader.epub.pageMarginPoints")
        defaults.set(100.0, forKey: "reader.epub.pageMarginAdjustment")
        defaults.set(3.0, forKey: "reader.epub.pageMargins")
        let migrated = try XCTUnwrap(LegacyReaderPreferences.migrate(defaults: defaults))
        XCTAssertEqual(migrated.pageMargins, 40, accuracy: 0.0001)
    }

    func testPageMarginAdjustmentIsUsedWhenPointsAreMissing() throws {
        defaults.set(50.0, forKey: "reader.epub.pageMarginAdjustment")
        let migrated = try XCTUnwrap(LegacyReaderPreferences.migrate(defaults: defaults))
        XCTAssertEqual(migrated.pageMargins, 36, accuracy: 0.0001)
    }

    func testPageMarginMultiplierIsUsedWhenEverythingElseIsMissing() throws {
        defaults.set(1.5, forKey: "reader.epub.pageMargins")
        let migrated = try XCTUnwrap(LegacyReaderPreferences.migrate(defaults: defaults))
        XCTAssertEqual(migrated.pageMargins, 36, accuracy: 0.0001)
    }

    func testLegacyThemeMapsToTheStoredPreset() throws {
        let cases: [(String, ReaderThemePreset)] = [
            ("light", .original),
            ("dark", .original),
            ("quiet", .quiet),
            ("sepia", .paper),
        ]
        for (raw, expected) in cases {
            defaults.set(raw, forKey: "reader.epub.theme")
            let migrated = try XCTUnwrap(LegacyReaderPreferences.migrate(defaults: defaults))
            XCTAssertEqual(migrated.themePreset, expected, "theme=\(raw)")
            defaults.removeObject(forKey: "reader.epub.theme")
        }
    }

    func testLegacyThemeKeyOnlyAcceptsReaderThemeRawValues() throws {
        // "paper" is a ReaderThemePreset raw value, not a ReaderTheme one, so
        // the legacy key treats it as unknown and falls back.
        defaults.set("paper", forKey: "reader.epub.theme")
        let migrated = try XCTUnwrap(LegacyReaderPreferences.migrate(defaults: defaults))
        XCTAssertEqual(migrated.themePreset, .original)
    }

    // MARK: - 只迁移一次

    func testMigrationRunsOnlyOnce() throws {
        defaults.set(1.5, forKey: "reader.epub.fontScale")
        let first = try XCTUnwrap(ReaderPreferencesStore.load(defaults: defaults))
        XCTAssertEqual(first.fontSizeLevel, 3)

        // A later legacy change must not overwrite the shared payload.
        defaults.set(2.0, forKey: "reader.epub.fontScale")
        let second = try XCTUnwrap(ReaderPreferencesStore.load(defaults: defaults))
        XCTAssertEqual(second.fontSizeLevel, 3)
    }

    func testLegacyKeysAreLeftInPlaceForRollback() throws {
        defaults.set("kai", forKey: "reader.epub.fontFamily")
        _ = ReaderPreferencesStore.load(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "reader.epub.fontFamily"), "kai")
    }

    // MARK: - 共享负载优先

    func testExistingPayloadWinsOverLegacyKeys() throws {
        let existing = ReaderPreferences(fontFamily: .yuan, pageMargins: 20)
        ReaderPreferencesStore.save(existing, defaults: defaults)

        defaults.set(1.9, forKey: "reader.epub.fontScale")
        defaults.set("song", forKey: "reader.epub.fontFamily")

        XCTAssertEqual(try XCTUnwrap(ReaderPreferencesStore.load(defaults: defaults)), existing)
    }

    func testSavingMarksTheMigrationAsPerformed() throws {
        ReaderPreferencesStore.save(ReaderPreferences(fontFamily: .song), defaults: defaults)
        defaults.set("kai", forKey: "reader.epub.fontFamily")
        let loaded = try XCTUnwrap(ReaderPreferencesStore.load(defaults: defaults))
        XCTAssertEqual(loaded.fontFamily, .song)
    }

    // MARK: - 健壮性

    func testSavedPreferencesRoundTripThroughTheStore() throws {
        let preferences = ReaderPreferences(fontSizeLevel: 5, fontFamily: .song, pageMargins: 28)
        ReaderPreferencesStore.save(preferences, defaults: defaults)
        XCTAssertEqual(ReaderPreferencesStore.load(defaults: defaults), preferences)
    }

    func testCorruptPayloadIsIgnoredRatherThanCrashing() {
        defaults.set(Data("not json".utf8), forKey: ReaderPreferencesStore.key)
        XCTAssertNil(ReaderPreferencesStore.load(defaults: defaults))
    }
}
