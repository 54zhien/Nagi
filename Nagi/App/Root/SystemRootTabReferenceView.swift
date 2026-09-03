
#if DEBUG
import SwiftUI

struct SystemRootTabReferenceView: View {
    private enum SystemRootTab: Hashable {
        case home
        case library
        case settings
        case search
    }

    @State private var selection: SystemRootTab = .home
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
