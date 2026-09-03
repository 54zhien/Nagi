
import Combine
import CoreGraphics
import UIKit

enum AppTab: Hashable {
    case home
    case library
    case settings
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
