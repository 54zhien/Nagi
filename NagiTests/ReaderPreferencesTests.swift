import XCTest
@testable import Nagi

/// Pins the stored format and migration behaviour of `ReaderPreferences`.
///
/// These tests exist so the "single source of truth" work can be verified as
/// behaviour preserving: the same stored JSON must keep decoding to the same
/// values, and the same defaults must keep applying.
final class ReaderPreferencesTests: XCTestCase {
    private func decode(_ json: String) throws -> ReaderPreferences {
        try JSONDecoder().decode(ReaderPreferences.self, from: Data(json.utf8))
    }

    // MARK: - 旧存储版本迁移

    func testLegacyMultiplierPageMarginsMigrateToPoints() throws {
        // Version 1 stored a multiplier of the base margin.
        XCTAssertEqual(try decode(#"{"pageMargins":1.0}"#).pageMargins, 24, accuracy: 0.0001)
        XCTAssertEqual(try decode(#"{"pageMargins":1.5}"#).pageMargins, 36, accuracy: 0.0001)
    }

    func testLegacyMultiplierIsClampedToTheCurrentRange() throws {
        let migrated = try decode(#"{"pageMargins":9.0}"#)
        XCTAssertEqual(
            migrated.pageMargins,
            ReaderLayoutMetrics.pageMarginsRange.upperBound,
            accuracy: 0.0001
        )
    }

    func testVersionTwoPercentageAdjustmentMigratesToPoints() throws {
        XCTAssertEqual(try decode(#"{"storageVersion":2,"pageMargins":0}"#).pageMargins, 24, accuracy: 0.0001)
        XCTAssertEqual(try decode(#"{"storageVersion":2,"pageMargins":50}"#).pageMargins, 36, accuracy: 0.0001)
        XCTAssertEqual(try decode(#"{"storageVersion":2,"pageMargins":100}"#).pageMargins, 48, accuracy: 0.0001)
    }

    func testVersionThreeAndLaterTreatPageMarginsAsPoints() throws {
        XCTAssertEqual(try decode(#"{"storageVersion":3,"pageMargins":30}"#).pageMargins, 30, accuracy: 0.0001)
        XCTAssertEqual(try decode(#"{"storageVersion":4,"pageMargins":40}"#).pageMargins, 40, accuracy: 0.0001)
    }

    func testAbsolutePointsAreClamped() throws {
        XCTAssertEqual(
            try decode(#"{"storageVersion":4,"pageMargins":999}"#).pageMargins,
            ReaderLayoutMetrics.pageMarginsRange.upperBound,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try decode(#"{"storageVersion":4,"pageMargins":1}"#).pageMargins,
            ReaderLayoutMetrics.pageMarginsRange.lowerBound,
            accuracy: 0.0001
        )
    }

    // MARK: - 缺省值

    func testMissingKeysDecodeToDocumentedDefaults() throws {
        let preferences = try decode("{}")
        XCTAssertEqual(preferences.fontSize, ReaderFontSize.defaultValue, accuracy: 0.0001)
        XCTAssertEqual(preferences.fontFamily, .original)
        XCTAssertFalse(preferences.boldText)
        XCTAssertEqual(preferences.lineHeight, ReaderLayoutMetrics.defaultLineHeight, accuracy: 0.0001)
        XCTAssertEqual(preferences.paragraphSpacing, 10, accuracy: 0.0001)
        XCTAssertEqual(preferences.pageMargins, ReaderLayoutMetrics.defaultPageMargins, accuracy: 0.0001)
        XCTAssertEqual(preferences.paragraphIndent, ReaderLayoutMetrics.fixedParagraphIndent, accuracy: 0.0001)
        XCTAssertEqual(preferences.characterSpacing, ReaderLayoutMetrics.defaultCharacterSpacing, accuracy: 0.0001)
        XCTAssertEqual(preferences.wordSpacing, ReaderLayoutMetrics.defaultWordSpacing, accuracy: 0.0001)
        XCTAssertFalse(preferences.publisherStyles)
        XCTAssertEqual(preferences.themePreset, .original)
        XCTAssertEqual(preferences.appearanceMode, .system)
        XCTAssertEqual(preferences.pageTransition, .slide)
        XCTAssertFalse(preferences.showBookTitleInPageHeader)
    }

    // MARK: - 往返

    func testEncodingRoundTripsEveryActivePreference() throws {
        let original = ReaderPreferences(
            fontSize: 23,
            fontFamily: .kai,
            boldText: true,
            lineHeight: 1.8,
            paragraphSpacing: 12,
            pageMargins: 32,
            characterSpacing: 4,
            wordSpacing: -6,
            publisherStyles: true,
            themePreset: .paper,
            appearanceMode: .dark,
            pageTransition: .pageCurl,
            showBookTitleInPageHeader: true
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ReaderPreferences.self, from: data), original)
    }

    func testEncodedPayloadCarriesTheCurrentStorageVersion() throws {
        let data = try JSONEncoder().encode(ReaderPreferences())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["storageVersion"] as? Int, 4)
    }

    func testDecodingClampsOutOfRangeTypography() throws {
        let preferences = try decode(#"{"storageVersion":4,"lineHeight":9,"characterSpacing":500,"wordSpacing":-500}"#)
        XCTAssertEqual(preferences.lineHeight, ReaderLayoutMetrics.lineHeightRange.upperBound, accuracy: 0.0001)
        XCTAssertEqual(
            preferences.characterSpacing,
            ReaderLayoutMetrics.characterSpacingRange.upperBound,
            accuracy: 0.0001
        )
        XCTAssertEqual(preferences.wordSpacing, ReaderLayoutMetrics.wordSpacingRange.lowerBound, accuracy: 0.0001)
    }
}
