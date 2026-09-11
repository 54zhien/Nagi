import ReadiumNavigator
import UIKit

/// The appearance the reader renders with, resolved once from the reader
/// theme, the appearance mode and the system colour scheme.
///
/// The SwiftUI chrome, the UIKit host, Readium's own preferences and the
/// injected CSS all read this same value, so they cannot disagree about what
/// "dark" means - which is what used to make the reader surface and the web
/// view fall out of sync.
struct ResolvedReaderAppearance {
    let theme: ReaderTheme
    let isDark: Bool
    let backgroundColor: UIColor
    let contentColor: UIColor
    let readiumTheme: ReadiumNavigator.Theme
    /// Readium CSS class applied to the document, if any.
    let readiumThemeMarker: String?
}

enum ReaderAppearanceResolver {
    static func resolve(
        theme: ReaderTheme,
        appearanceMode: ReaderAppearanceMode,
        systemIsDark: Bool
    ) -> ResolvedReaderAppearance {
        let resolvedTheme = resolvedTheme(
            theme: theme,
            appearanceMode: appearanceMode,
            systemIsDark: systemIsDark
        )
        let isDark = isDarkAppearance(
            appearanceMode: appearanceMode,
            systemIsDark: systemIsDark
        )
        let readiumTheme = resolvedTheme.readiumTheme(isDarkAppearance: isDark)

        return ResolvedReaderAppearance(
            theme: resolvedTheme,
            isDark: isDark,
            backgroundColor: resolvedTheme.readerBackgroundUIColor(isDarkAppearance: isDark),
            contentColor: resolvedTheme.readerContentUIColor(isDarkAppearance: isDark),
            readiumTheme: readiumTheme,
            readiumThemeMarker: marker(for: readiumTheme)
        )
    }

    /// Applies the user's appearance mode on top of the reader theme.  The
    /// light and dark palettes are both neutral, so they map onto each other
    /// rather than stacking.
    private static func resolvedTheme(
        theme: ReaderTheme,
        appearanceMode: ReaderAppearanceMode,
        systemIsDark: Bool
    ) -> ReaderTheme {
        switch appearanceMode {
        case .light:
            return theme == .dark ? .light : theme
        case .dark:
            return theme == .light ? .dark : theme
        case .system:
            return systemIsDark
                ? (theme == .light ? .dark : theme)
                : (theme == .dark ? .light : theme)
        }
    }

    private static func isDarkAppearance(
        appearanceMode: ReaderAppearanceMode,
        systemIsDark: Bool
    ) -> Bool {
        switch appearanceMode {
        case .light:
            return false
        case .dark:
            return true
        case .system:
            return systemIsDark
        }
    }

    private static func marker(for theme: ReadiumNavigator.Theme) -> String? {
        switch theme {
        case .light:
            return nil
        case .dark:
            return "readium-night-on"
        case .sepia:
            return "readium-sepia-on"
        }
    }
}

extension ReaderTheme {
    func readiumTheme(isDarkAppearance: Bool) -> ReadiumNavigator.Theme {
        switch self {
        case .light:
            return .light
        case .quiet:
            return .dark
        case .sepia:
            return isDarkAppearance ? .dark : .sepia
        case .dark:
            return .dark
        }
    }
}
