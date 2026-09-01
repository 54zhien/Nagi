//
//  SystemRootTabReferenceView.swift
//  Nagi
//
//  只用于开发阶段和截图对照的原生系统视觉参考。它不在 NagiApp 的
//  正式 hierarchy 中，正式 Root 始终是 NagiRootRepresentable。
//

#if DEBUG
import SwiftUI

struct SystemRootTabReferenceView: View {
    @State private var selection: AppTab = .home
    @State private var searchText = ""
    @State private var isSearchPresented = false

    var body: some View {
        TabView(selection: $selection) {
            Tab("主页", image: "homeIcon", value: .home) {
                HomeView()
            }
            Tab("书库", systemImage: "books.vertical", value: .library) {
                LibraryView()
            }
            Tab("设置", systemImage: "gearshape", value: .settings) {
                SettingsView()
            }
            Tab("搜索", systemImage: "magnifyingglass", value: .search, role: .search) {
                SearchView(searchText: $searchText)
            }
        }
        .searchable(
            text: $searchText,
            isPresented: $isSearchPresented,
            prompt: "搜索书名"
        )
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSearchActivation(.automatic)
    }
}
#endif
