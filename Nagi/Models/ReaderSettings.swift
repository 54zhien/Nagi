//
//  ReaderSettings.swift
//  Nagi
//
//  所有阅读格式共用的排版选项和值域。
//

import SwiftUI
import UIKit

enum ReaderTheme: String, CaseIterable, Identifiable, Hashable {
    case light
    case sepia
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "白色"
        case .sepia: return "米黄"
        case .dark: return "深色"
        }
    }

    var background: Color {
        switch self {
        case .light: return Color(red: 1.0, green: 1.0, blue: 1.0)
        case .sepia: return Color(red: 0.97, green: 0.94, blue: 0.86)
        case .dark: return Color(red: 0.12, green: 0.12, blue: 0.13)
        }
    }

    var foreground: Color {
        switch self {
        case .light: return Color(red: 0.1, green: 0.1, blue: 0.1)
        case .sepia: return Color(red: 0.3, green: 0.25, blue: 0.18)
        case .dark: return Color(red: 0.85, green: 0.85, blue: 0.85)
        }
    }

    var foregroundUIColor: UIColor {
        UIColor(foreground)
    }

    var contentUIColor: UIColor {
        foregroundUIColor
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

/// A built-in or user-installed system font available to both reader engines.
///
/// The built-in cases keep the existing reader defaults stable, while the
/// `installed` case stores the family name returned by UIKit.  Keeping the
/// family name (instead of a font face name) lets each renderer choose the
/// appropriate regular/bold face for the selected family.
enum ReaderFontFamily: Hashable, Identifiable {
    case systemSerif
    case systemSansSerif
    case palatino
    case athelas
    case openDyslexic
    case installed(String)

    static let builtInCases: [ReaderFontFamily] = [
        .systemSerif,
        .systemSansSerif,
        .palatino,
        .athelas,
        .openDyslexic,
    ]

    /// Kept as a compatibility alias for any callers that previously used
    /// `CaseIterable.allCases`; the picker now renders the grouped options.
    static var allCases: [ReaderFontFamily] { allOptions }

    /// All fonts currently registered with UIKit, excluding families already
    /// represented by a built-in option.  This is evaluated when the settings
    /// view renders so fonts downloaded while the app is installed can appear
    /// without shipping another app update.
    static var installedFontFamilies: [ReaderFontFamily] {
        let builtInNames = Set([
            "new york",
            "palatino",
            "athelas",
            "opendyslexic",
        ])

        return UIFont.familyNames
            .filter { family in
                !family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !builtInNames.contains(family.lowercased())
                    && !UIFont.fontNames(forFamilyName: family).isEmpty
            }
            .sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            .map { .installed($0) }
    }

    static var allOptions: [ReaderFontFamily] {
        builtInCases + installedFontFamilies
    }

    var id: String { rawValue }

    /// Stable UserDefaults representation. Legacy built-in values remain
    /// unchanged so existing reader preferences migrate automatically.
    var rawValue: String {
        switch self {
        case .systemSerif: return "systemSerif"
        case .systemSansSerif: return "systemSansSerif"
        case .palatino: return "palatino"
        case .athelas: return "athelas"
        case .openDyslexic: return "openDyslexic"
        case .installed(let family): return "installed:\(family)"
        }
    }

    init?(_ rawValue: String) {
        switch rawValue {
        case "systemSerif": self = .systemSerif
        case "systemSansSerif": self = .systemSansSerif
        case "palatino": self = .palatino
        case "athelas": self = .athelas
        case "openDyslexic": self = .openDyslexic
        default:
            let prefix = "installed:"
            guard rawValue.hasPrefix(prefix) else { return nil }
            let family = String(rawValue.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !family.isEmpty else { return nil }
            self = .installed(family)
        }
    }

    var label: String {
        switch self {
        case .systemSerif: return "系统衬线"
        case .systemSansSerif: return "系统无衬线"
        case .palatino: return "Palatino"
        case .athelas: return "Athelas"
        case .openDyslexic: return "OpenDyslexic"
        case .installed(let family): return family
        }
    }

    func uiFont(ofSize size: CGFloat) -> UIFont {
        let baseFont: UIFont
        switch self {
        case .systemSerif:
            baseFont = UIFont(name: "New York", size: size)
                ?? UIFont.systemFont(ofSize: size)
        case .systemSansSerif:
            baseFont = UIFont.systemFont(ofSize: size)
        case .palatino:
            baseFont = UIFont(name: "Palatino", size: size)
                ?? UIFont.systemFont(ofSize: size)
        case .athelas:
            baseFont = UIFont(name: "Athelas", size: size)
                ?? UIFont.systemFont(ofSize: size)
        case .openDyslexic:
            baseFont = UIFont(name: "OpenDyslexic", size: size)
                ?? UIFont.systemFont(ofSize: size)
        case .installed(let family):
            let face = UIFont.fontNames(forFamilyName: family)
                .compactMap { UIFont(name: $0, size: size) }
                .first
            baseFont = face ?? UIFont.systemFont(ofSize: size)
        }

        return UIFontMetrics(forTextStyle: .body).scaledFont(for: baseFont)
    }
}
