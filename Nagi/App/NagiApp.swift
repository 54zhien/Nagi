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
        let context = Persistence.container.mainContext
        LibraryViewModel().importAndParse([url], into: context) { titles, failures in
            if let title = titles.first, failures.isEmpty {
                AppImportState.shared.message = "已导入「\(title)」"
            } else if !failures.isEmpty {
                AppImportState.shared.message = "导入失败：\(failures.joined(separator: "\n"))"
            }
        }
    }
}

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var selection: AppTab = .home
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var importState = AppImportState.shared

    var body: some View {
        TabView(selection: $selection) {
            Tab("主页", systemImage: "book", value: .home) {
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
        .onSubmit(of: .search) {
            SearchHistoryStorage.record(searchText)
        }
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
        .task {
            FileImportService.removeAbandonedCopyFiles()
            LibraryViewModel.migrateStoredFileLocations(in: modelContext)
            LibraryViewModel.resumeInterruptedImports(in: modelContext)
        }
    }
}

enum AppTab: Hashable {
    case home
    case library
    case settings
    case search
}
