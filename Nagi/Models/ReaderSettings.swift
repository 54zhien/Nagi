//
//  ReaderSettings.swift
//  Nagi
//
//  所有阅读格式共用的排版选项和值域。
//

import SwiftUI
import UIKit

/// Reader surface colors sampled from the approved reading references.
/// Keeping these values in one palette prevents the TXT and EPUB renderers
/// from drifting apart as the settings UI evolves.
enum ReaderThemePalette {
    static let originalLightBackground = UIColor.white
    static let originalLightContent = UIColor(red: 18 / 255, green: 18 / 255, blue: 18 / 255, alpha: 1)
    static let originalDarkBackground = UIColor.black
    static let originalDarkContent = UIColor(red: 242 / 255, green: 242 / 255, blue: 247 / 255, alpha: 1)

    // Light quiet palette retained from the existing reader theme.
    static let quietBackground = UIColor(red: 0x4A / 255, green: 0x49 / 255, blue: 0x4E / 255, alpha: 1)
    // Dark quiet reference: #1C1C1E.
    static let quietDarkBackground = UIColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)
    static let quietContent = UIColor(red: 242 / 255, green: 242 / 255, blue: 247 / 255, alpha: 1)

    // Reference image 2: light paper theme.
    static let paperLightBackground = UIColor(red: 0xEE / 255, green: 0xE2 / 255, blue: 0xCA / 255, alpha: 1)
    static let paperLightContent = UIColor(red: 76 / 255, green: 64 / 255, blue: 46 / 255, alpha: 1)

    // Reference image 3: dark paper theme.
    static let paperDarkBackground = UIColor(red: 0x42 / 255, green: 0x3C / 255, blue: 0x30 / 255, alpha: 1)
    static let paperDarkContent = UIColor(red: 242 / 255, green: 238 / 255, blue: 229 / 255, alpha: 1)
}

enum ReaderTheme: String, CaseIterable, Identifiable, Hashable {
    case light
    case quiet
    case sepia
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "白色"
        case .quiet: return "安静"
        case .sepia: return "米黄"
        case .dark: return "深色"
        }
    }

    var background: Color {
        switch self {
        case .light: return Color(uiColor: ReaderThemePalette.originalLightBackground)
        case .quiet: return Color(uiColor: ReaderThemePalette.quietBackground)
        case .sepia: return Color(uiColor: ReaderThemePalette.paperLightBackground)
        case .dark: return Color(uiColor: ReaderThemePalette.originalDarkBackground)
        }
    }

    var foreground: Color {
        switch self {
        case .light: return Color(uiColor: ReaderThemePalette.originalLightContent)
        case .quiet: return Color(uiColor: ReaderThemePalette.quietContent)
        case .sepia: return Color(uiColor: ReaderThemePalette.paperLightContent)
        case .dark: return Color(uiColor: ReaderThemePalette.originalDarkContent)
        }
    }

    var foregroundUIColor: UIColor {
        UIColor(foreground)
    }

    var contentUIColor: UIColor {
        foregroundUIColor
    }

    func readerBackgroundUIColor(isDarkAppearance: Bool) -> UIColor {
        switch self {
        case .light:
            return isDarkAppearance
                ? ReaderThemePalette.originalDarkBackground
                : ReaderThemePalette.originalLightBackground
        case .quiet:
            return isDarkAppearance
                ? ReaderThemePalette.quietDarkBackground
                : ReaderThemePalette.quietBackground
        case .sepia:
            return isDarkAppearance
                ? ReaderThemePalette.paperDarkBackground
                : ReaderThemePalette.paperLightBackground
        case .dark:
            return ReaderThemePalette.originalDarkBackground
        }
    }

    func readerContentUIColor(isDarkAppearance: Bool) -> UIColor {
        switch self {
        case .light:
            return isDarkAppearance
                ? ReaderThemePalette.originalDarkContent
                : ReaderThemePalette.originalLightContent
        case .quiet:
            return ReaderThemePalette.quietContent
        case .sepia:
            return isDarkAppearance
                ? ReaderThemePalette.paperDarkContent
                : ReaderThemePalette.paperLightContent
        case .dark:
            return ReaderThemePalette.originalDarkContent
        }
    }

    /// Compatibility entry points for older renderer code. Brightness is now
    /// controlled by the device and never changes these reader colors.
    func adjustedBackgroundUIColor(brightness _: Double) -> UIColor {
        readerBackgroundUIColor(isDarkAppearance: false)
    }

    func adjustedForegroundUIColor(brightness _: Double) -> UIColor {
        readerContentUIColor(isDarkAppearance: false)
    }
}

enum ReaderFlowMode: String, CaseIterable, Identifiable, Hashable {
    case paged
    case scroll

    var id: String { rawValue }
    var label: String { self == .paged ? "横向分页" : "上下滚动" }
}

enum ReaderPageTransitionMode: String, CaseIterable, Identifiable, Hashable {
    case pageCurl
    case cover

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pageCurl: return "仿真翻页"
        case .cover: return "覆盖翻页"
        }
    }
}

/// The only font choices exposed by the reader.
///
/// This is deliberately a fixed catalogue.  In particular, it must not be
/// populated from the system-wide font enumeration, because an unrelated font
/// installed by the user can be unavailable to Readium or can change the
/// settings UI between launches.
enum ReaderFontFamily: String, CaseIterable, Hashable, Identifiable, Codable, Sendable {
    case original
    case pingFang
    case song
    case kai
    case yuan

    /// Kept as a named catalogue so every reader settings surface uses the
    /// same order instead of rebuilding its own list.
    static var options: [ReaderFontFamily] { allCases }

    /// Compatibility aliases for the legacy settings surface.  Neither alias
    /// performs system-font discovery.
    static var allOptions: [ReaderFontFamily] { options }
    static var builtInCases: [ReaderFontFamily] { options }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "原始"
        case .pingFang: return "苹方"
        case .song: return "宋体"
        case .kai: return "楷体"
        case .yuan: return "圆体"
        }
    }

    /// Known system face names used by the native/TXT renderer and the
    /// SwiftUI settings preview. The first name in each list is the current
    /// face name; the remaining names keep older supported OS releases on a
    /// safe system-font fallback path.
    var uiFontNames: [String] {
        switch self {
        case .original, .pingFang:
            return []
        case .song:
            return [
                "STSongti-SC-Regular",
                "STSongtiSC-Regular",
                "STSong"
            ]
        case .kai:
            return [
                "STKaiti-SC-Regular",
                "STKaitiSC-Regular",
                "STKaiti"
            ]
        case .yuan:
            return [
                "STYuanti-SC-Regular",
                "STYuantiSC-Regular"
            ]
        }
    }

    /// The system family names used only as a targeted fallback when a
    /// particular OS exposes a different regular-face alias.
    private var uiFontFamilyName: String? {
        switch self {
        case .original, .pingFang: return nil
        case .song: return "Songti SC"
        case .kai: return "Kaiti SC"
        case .yuan: return "Yuanti SC"
        }
    }

    /// The system font used for the light-weight PingFang choice.  The
    /// remaining cases use a named system face above and regular is only the
    /// final fallback when that face is unavailable on an older OS.
    var systemFontWeight: UIFont.Weight {
        self == .pingFang ? .light : .regular
    }

    /// CSS family names used inside the EPUB Navigator.  The bundled Chinese
    /// fonts use app-owned aliases so Readium can register their resources
    /// independently from UIKit's PostScript face names.
    var readiumFamilyName: String {
        switch self {
        case .original: return "-apple-system"
        case .pingFang: return "-apple-system"
        case .song: return "Nagi Song"
        case .kai: return "Nagi Kai"
        case .yuan: return "Nagi Rounded"
        }
    }

    /// Migrates values written by the previous font picker.  Removed fonts
    /// intentionally fall back to the first supported option instead of
    /// leaving a selection that no longer exists in the fixed catalogue.
    init?(rawValue: String) {
        switch rawValue {
        case "original": self = .original
        case "pingFang": self = .pingFang
        case "song": self = .song
        case "kai": self = .kai
        case "yuan": self = .yuan
        case "systemSerif", "systemSansSerif", "palatino", "athelas", "openDyslexic":
            self = .original
        default:
            if rawValue.hasPrefix("installed:") {
                self = .original
            } else {
                return nil
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = Self(rawValue: value) ?? .original
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private func resolvedUIFont(at size: CGFloat) -> UIFont? {
        for name in uiFontNames {
            if let font = UIFont(name: name, size: size) {
                return font
            }
        }

        guard let familyName = uiFontFamilyName else { return nil }
        let regularName = UIFont.fontNames(forFamilyName: familyName)
            .first { $0.localizedCaseInsensitiveContains("regular") }
        return regularName.flatMap { UIFont(name: $0, size: size) }
    }

    private func resolvedUIFontName(at size: CGFloat) -> String? {
        resolvedUIFont(at: size)?.fontName
    }

    func uiFont(ofSize size: CGFloat) -> UIFont {
        let baseFont = resolvedUIFont(at: size)
            ?? UIFont.systemFont(ofSize: size, weight: systemFontWeight)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: baseFont)
    }

    /// Font used by the SwiftUI settings preview and each menu item.
    func swiftUIFont(ofSize size: CGFloat) -> Font {
        if self == .pingFang {
            return .system(size: size, weight: .light)
        }
        guard let uiFontName = resolvedUIFontName(at: size) else {
            return .system(size: size, weight: .regular)
        }
        return .custom(uiFontName, size: size)
    }
}
