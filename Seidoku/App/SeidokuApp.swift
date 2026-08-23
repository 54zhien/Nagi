//
//  SeidokuApp.swift
//  Seidoku
//
//  App 入口 + 根 Tab 视图（底部 tab 栏，搜索分离式）
//

import SwiftUI

@main
struct SeidokuApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}

// MARK: - 根 Tab 视图

/// 底部 tab 栏：主页 / 书库 / 设置 / 搜索
/// - 搜索 tab 通过 `role: .search` 与其它 tab 分离，独立分隔显示
struct RootTabView: View {
    @State private var selection: AppTab = .home

    var body: some View {
        TabView(selection: $selection) {
            Tab("主页", image: "homeIcon", value: .home) {
                HomeView()
            }

            Tab("书库", systemImage: "books.vertical", value: .library) {
                LibraryView()
            }

            Tab("设置", systemImage: "gear", value: .settings) {
                SettingsView()
            }

            Tab("搜索", systemImage: "magnifyingglass", value: .search, role: .search) {
                SearchView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

// MARK: - Tab 标识

/// 底部 tab 栏的四个 tab，作为 TabView 的 selection 值类型。
enum AppTab: Hashable {
    case home
    case library
    case settings
    case search
}
