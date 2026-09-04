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

struct RootTabView: View {
    @State private var selection: AppTab = .home
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var importState = AppImportState.shared

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
        .alert("导入", isPresented: Binding(
            get: { importState.message != nil },
            set: { if !$0 { importState.message = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importState.message ?? "")
        }
    }
}

enum AppTab: Hashable {
    case home
    case library
    case settings
    case search
}
