
import UIKit

enum ReaderThemePalette {
    static let originalLightBackground = UIColor.white
    static let originalLightContent = UIColor(red: 18 / 255, green: 18 / 255, blue: 18 / 255, alpha: 1)
    static let originalDarkBackground = UIColor.black
    static let originalDarkContent = UIColor(red: 242 / 255, green: 242 / 255, blue: 247 / 255, alpha: 1)

    static let quietBackground = UIColor(red: 0x4A / 255, green: 0x49 / 255, blue: 0x4E / 255, alpha: 1)
    static let quietDarkBackground = UIColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)
    static let quietContent = UIColor(red: 242 / 255, green: 242 / 255, blue: 247 / 255, alpha: 1)

    static let paperLightBackground = UIColor(red: 0xEE / 255, green: 0xE2 / 255, blue: 0xCA / 255, alpha: 1)
    static let paperLightContent = UIColor(red: 76 / 255, green: 64 / 255, blue: 46 / 255, alpha: 1)

    static let paperDarkBackground = UIColor(red: 0x42 / 255, green: 0x3C / 255, blue: 0x30 / 255, alpha: 1)
    static let paperDarkContent = UIColor(red: 242 / 255, green: 238 / 255, blue: 229 / 255, alpha: 1)
}

enum ReaderTheme: String, Equatable {
    case light
    case quiet
    case sepia
    case dark

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

}

enum ReaderFontFamily: String, CaseIterable, Hashable, Identifiable, Codable, Sendable {
    case original
    case pingFang
    case song
    case kai
    case yuan

    static var options: [ReaderFontFamily] { allCases }

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

    private var uiFontFamilyName: String? {
        switch self {
        case .original, .pingFang: return nil
        case .song: return "Songti SC"
        case .kai: return "Kaiti SC"
        case .yuan: return "Yuanti SC"
        }
    }

    var systemFontWeight: UIFont.Weight {
        self == .pingFang ? .light : .regular
    }

    var readiumFamilyName: String {
        switch self {
        case .original: return "-apple-system"
        case .pingFang: return "-apple-system"
        case .song: return "Nagi Song"
        case .kai: return "Nagi Kai"
        case .yuan: return "Nagi Rounded"
        }
    }

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
