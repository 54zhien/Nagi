//
//  NagiRootState.swift
//  Nagi
//
//  UIKit Root 的唯一状态模型。Root 与底栏共享这份状态，避免 SwiftUI
//  通过重建 TabView 来驱动导航和搜索转场。
//

import CoreGraphics
import Combine
import UIKit

enum AppTab: Hashable {
    case home
    case library
    case settings
    case search
}

enum NagiRootTabMode: Equatable {
    case tabs(selected: AppTab)
    case searchActivating
    case searchActive
    case searchDeactivating(previous: AppTab)

    var selectedTab: AppTab {
        switch self {
        case let .tabs(selected):
            return selected
        case .searchActivating, .searchActive:
            return .search
        case let .searchDeactivating(previous):
            return previous
        }
    }

    var isSearchVisible: Bool {
        switch self {
        case .searchActivating, .searchActive, .searchDeactivating:
            return true
        case .tabs:
            return false
        }
    }

    var isSearchInteractionActive: Bool {
        switch self {
        case .searchActivating, .searchActive, .searchDeactivating:
            return true
        case .tabs:
            return false
        }
    }

    var isSearchExpanded: Bool {
        switch self {
        case .searchActivating, .searchActive:
            return true
        case .tabs, .searchDeactivating:
            return false
        }
    }
}

struct NagiRootLayoutState: Equatable {
    var bounds: CGRect
    var safeAreaInsets: UIEdgeInsets
    var keyboardFrame: CGRect?
    var mode: NagiRootTabMode

    static let initial = NagiRootLayoutState(
        bounds: .zero,
        safeAreaInsets: .zero,
        keyboardFrame: nil,
        mode: .tabs(selected: .home)
    )
}

final class NagiRootState: ObservableObject {
    var mode: NagiRootTabMode = .tabs(selected: .home)
    @Published var searchText = ""
    var tabBeforeSearch: AppTab = .home
}
