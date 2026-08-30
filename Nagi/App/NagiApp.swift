//
//  NagiApp.swift
//  Nagi
//
//  App 入口 + 根 Tab 视图（底部 tab 栏，搜索分离式）
//

import SwiftUI
import SwiftData

@main
struct NagiApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
                .onOpenURL { url in
                    handleIncomingFile(url)
                }
        }
        .modelContainer(Persistence.container)
    }

    /// 处理通过「用 Nagi 打开」传入的文件。
    @MainActor
    private func handleIncomingFile(_ url: URL) {
        Task {
            var results: [BookImportResult] = []
            do {
                let files = try FileImportService().importFiles([url])
                results = try await LibraryViewModel.parseBooksInBackground(files)
                let context = Persistence.container.mainContext
                try LibraryViewModel.upsert(results, into: context)
                try context.save()
                AppImportState.shared.message = "已导入「\(results.first?.title ?? "书")」"
            } catch {
                for result in results {
                    TXTReaderAssetStore.removeAsset(atPath: result.readerAssetURL)
                }
                AppImportState.shared.message = "导入失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 根 Tab 视图

/// 底部 tab 栏：主页 / 书库 / 设置 / 搜索
/// - 搜索 tab 通过 `role: .search` 与其它 tab 分离，独立分隔显示
struct RootTabView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var selection: AppTab = .home
    @State private var searchText = ""
    @State private var importState = AppImportState.shared

    var body: some View {
        tabView
            .alert("导入", isPresented: Binding(
                get: { importState.message != nil },
                set: { if !$0 { importState.message = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importState.message ?? "")
            }
    }

    private var tabView: some View {
        TabView(selection: $selection.animation(tabBarTransitionAnimation)) {
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
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSearchActivation(.automatic)
    }

    private var tabBarTransitionAnimation: Animation? {
        accessibilityReduceMotion
            ? nil
            : .smooth(duration: 0.35, extraBounce: 0)
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
