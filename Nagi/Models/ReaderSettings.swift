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

enum ReaderFontFamily: String, CaseIterable, Identifiable, Hashable {
    case systemSerif
    case systemSansSerif
    case palatino
    case athelas
    case openDyslexic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .systemSerif: return "系统衬线"
        case .systemSansSerif: return "系统无衬线"
        case .palatino: return "Palatino"
        case .athelas: return "Athelas"
        case .openDyslexic: return "OpenDyslexic"
        }
    }

    func uiFont(ofSize size: CGFloat) -> UIFont {
        let name: String?
        switch self {
        case .systemSerif:
            name = "New York"
        case .systemSansSerif:
            name = nil
        case .palatino:
            name = "Palatino"
        case .athelas:
            name = "Athelas"
        case .openDyslexic:
            name = "OpenDyslexic"
        }

        let baseFont = name.flatMap { UIFont(name: $0, size: size) }
            ?? UIFont.systemFont(ofSize: size)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: baseFont)
    }
}
