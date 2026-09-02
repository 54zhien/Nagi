//
//  NagiRootState.swift
//  Nagi
//
//  UIKit Root 的唯一状态模型。Search 是当前选中页面上方的独立 overlay，
//  不再作为第四个 AppTab 参与页面选择。
//

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
