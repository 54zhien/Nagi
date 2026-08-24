//
//  ReaderSettings.swift
//  Seidoku
//
//  阅读排版设置（轻量偏好，用 @AppStorage 持久化）。
//

import SwiftUI

enum ReaderTheme: String, CaseIterable, Identifiable {
    case white, sepia, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .white: return "白色"
        case .sepia: return "米黄"
        case .dark: return "深色"
        }
    }

    var background: Color {
        switch self {
        case .white: return Color(red: 1.0, green: 1.0, blue: 1.0)
        case .sepia: return Color(red: 0.97, green: 0.94, blue: 0.86)
        case .dark: return Color(red: 0.12, green: 0.12, blue: 0.13)
        }
    }

    var foreground: Color {
        switch self {
        case .white: return Color(red: 0.1, green: 0.1, blue: 0.1)
        case .sepia: return Color(red: 0.3, green: 0.25, blue: 0.18)
        case .dark: return Color(red: 0.85, green: 0.85, blue: 0.85)
        }
    }

    var foregroundUIColor: UIColor {
        UIColor(foreground)
    }
}

enum PageTransitionMode: String, CaseIterable, Identifiable {
    case pageCurl, horizontal, vertical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pageCurl: return "仿真翻页"
        case .horizontal: return "覆盖翻页"
        case .vertical: return "上下滚动"
        }
    }
}

struct ReaderSettings {
    var fontSize: Double = 17
    var lineSpacing: Double = 6
    var paragraphSpacing: Double = 10
    var horizontalInset: Double = 16
    var theme: ReaderTheme = .white
    var transition: PageTransitionMode = .pageCurl
}
