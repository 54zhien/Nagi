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
    static let originalDarkBackground = UIColor(white: 0.12, alpha: 1)
    static let originalDarkContent = UIColor(red: 242 / 255, green: 242 / 255, blue: 247 / 255, alpha: 1)

    // Reference image 1: quiet theme.
    static let quietBackground = UIColor(red: 0x4A / 255, green: 0x49 / 255, blue: 0x4E / 255, alpha: 1)
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
            return ReaderThemePalette.quietBackground
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

    /// PostScript names used by UIKit and SwiftUI for the bundled/system
    /// regular faces.  These are not the user-facing labels.
    var uiFontName: String? {
        switch self {
        case .original: return nil
        case .pingFang: return "PingFangSC-Regular"
        case .song: return "STSong"
        case .kai: return "STKaiti"
        case .yuan: return "STYuanti-SC-Regular"
        }
    }

    /// The resource name used by Readium's HTML font declarations.  The
    /// extension is intentionally omitted for `Bundle.url` lookup.
    var bundledFontResourceName: String? {
        switch self {
        case .original, .pingFang: return nil
        case .song: return "NagiSong-Regular"
        case .kai: return "NagiKaiti-Regular"
        case .yuan: return "NagiYuanti-Regular"
        }
    }

    /// The CSS family aliases used inside the EPUB Navigator.  Aliases keep
    /// the web renderer independent from the internal names in the TTF files.
    var readiumFamilyName: String? {
        switch self {
        case .original: return nil
        case .pingFang: return "PingFang SC"
        case .song: return "Nagi Song"
        case .kai: return "Nagi Kaiti"
        case .yuan: return "Nagi Yuanti"
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

    func uiFont(ofSize size: CGFloat) -> UIFont {
        let baseFont = uiFontName.flatMap { UIFont(name: $0, size: size) }
            ?? UIFont.systemFont(ofSize: size)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: baseFont)
    }

    /// Font used by the SwiftUI settings preview and each menu item.
    func swiftUIFont(ofSize size: CGFloat) -> Font {
        guard let uiFontName else {
            return .system(size: size)
        }
        return .custom(uiFontName, size: size)
    }
}
