import Combine
import CoreGraphics
import UIKit

enum AppTab: Hashable {
    case home
    case library
    case settings

    var title: String {
        switch self {
        case .home:
            return "主页"
        case .library:
            return "书库"
        case .settings:
            return "设置"
        }
    }

    var symbolName: String {
        switch self {
        case .home:
            return "book.closed"
        case .library:
            return "books.vertical"
        case .settings:
            return "gearshape"
        }
    }
}

struct NagiTabBarSearchState: Equatable {
    var isActive: Bool

    static let inactive = NagiTabBarSearchState(isActive: false)
}

struct NagiRootLayoutState: Equatable {
    var bounds: CGRect
    var safeAreaInsets: UIEdgeInsets
    var keyboardFrame: CGRect?
    var selectedTab: AppTab
    var searchState: NagiTabBarSearchState

    static let initial = NagiRootLayoutState(
        bounds: .zero,
        safeAreaInsets: .zero,
        keyboardFrame: nil,
        selectedTab: .home,
        searchState: .inactive
    )
}

final class NagiRootState: ObservableObject {
    var selectedTab: AppTab = .home
    var tabBarSearchState = NagiTabBarSearchState.inactive
    @Published var searchText = ""
}
