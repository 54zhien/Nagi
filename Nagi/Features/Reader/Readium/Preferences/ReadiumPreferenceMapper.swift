import ReadiumNavigator
import ReadiumShared

/// Converts the reader's own preferences into Readium's preference payload.
///
/// Stateless and free of side effects, so the conversion can be reasoned about
/// (and tested) on its own.
enum ReadiumPreferenceMapper {
    static func makePreferences(
        from preferences: ReaderPreferences,
        appearance: ResolvedReaderAppearance,
        isReflowable: Bool
    ) -> EPUBPreferences {
        EPUBPreferences(
            // Keep Readium's first paint in sync with the reader chrome. The
            // document override makes reflowable pages transparent once it is
            // installed, but the fallback must never use WebKit white.
            backgroundColor: ReadiumNavigator.Color(uiColor: appearance.backgroundColor),
            // Publisher styles only disable the app-owned typography rules.
            fontFamily: preferences.fontFamily.readiumFontFamily,
            fontSize: preferences.fontSizeScale,
            fontWeight: preferences.boldText ? 1.75 : preferences.fontFamily.readiumFontWeight,
            letterSpacing: nil,
            lineHeight: nil,
            pageMargins: ReaderLayoutMetrics.pageMarginFactor(for: preferences.pageMargins),
            paragraphIndent: ReaderLayoutMetrics.fixedParagraphIndent,
            publisherStyles: preferences.publisherStyles,
            // Fixed-layout EPUBs cannot participate in the outer continuous
            // document scroll. Leave them paginated instead of disabling both
            // their inner and outer page-turn gestures.
            scroll: preferences.pageTransition == .scroll && isReflowable,
            spread: .auto,
            textColor: ReadiumNavigator.Color(uiColor: appearance.contentColor),
            textNormalization: !preferences.publisherStyles,
            theme: appearance.readiumTheme,
            wordSpacing: nil
        )
    }
}

extension ReaderFontFamily {
    var readiumFontFamily: FontFamily {
        FontFamily(rawValue: readiumFamilyName)
    }

    /// Readium's weight scale for the lighter system font.
    var readiumFontWeight: Double {
        self == .pingFang ? 0.75 : 1.0
    }
}
