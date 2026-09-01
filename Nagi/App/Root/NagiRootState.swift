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

struct NagiSearchPresentationState: Equatable {
    var isActive: Bool
    var isExpandedStandaloneBar: Bool

    static let inactive = NagiSearchPresentationState(
        isActive: false,
        isExpandedStandaloneBar: false
    )
}

enum NagiRootTabMode: Equatable {
    case tabs(selected: AppTab)
    case searchEntering(previous: AppTab)
    case searchActive(previous: AppTab)
    case searchExiting(previous: AppTab)

    var selectedTab: AppTab {
        switch self {
        case let .tabs(selected):
            return selected
        case .searchEntering, .searchActive:
            return .search
        case let .searchExiting(previous):
            return previous
        }
    }

    var previousTab: AppTab? {
        switch self {
        case let .tabs(selected):
            return selected
        case let .searchEntering(previous), let .searchActive(previous), let .searchExiting(previous):
            return previous
        }
    }

    var searchPresentation: NagiSearchPresentationState {
        switch self {
        case .tabs:
            return .inactive
        case .searchEntering, .searchActive:
            return NagiSearchPresentationState(isActive: true, isExpandedStandaloneBar: false)
        case .searchExiting:
            return NagiSearchPresentationState(isActive: false, isExpandedStandaloneBar: false)
        }
    }

    var isSearchActive: Bool {
        searchPresentation.isActive
    }

    var isSearchVisible: Bool {
        switch self {
        case .searchEntering, .searchActive, .searchExiting:
            return true
        case .tabs:
            return false
        }
    }

    var isSearchInteractionActive: Bool {
        switch self {
        case .searchEntering, .searchActive, .searchExiting:
            return true
        case .tabs:
            return false
        }
    }

    var layoutIdentity: NagiRootLayoutIdentity {
        switch self {
        case let .tabs(selected):
            return .normal(selected: selected)
        case .searchEntering, .searchActive:
            return .searchActive
        case let .searchExiting(previous):
            return .normal(selected: previous)
        }
    }
}

enum NagiRootLayoutIdentity: Equatable {
    case normal(selected: AppTab)
    case searchActive
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

    static func == (lhs: NagiRootLayoutState, rhs: NagiRootLayoutState) -> Bool {
        lhs.bounds == rhs.bounds &&
        lhs.safeAreaInsets == rhs.safeAreaInsets &&
        lhs.keyboardFrame == rhs.keyboardFrame &&
        lhs.mode.layoutIdentity == rhs.mode.layoutIdentity
    }
}

final class NagiRootState: ObservableObject {
    var mode: NagiRootTabMode = .tabs(selected: .home)
    @Published var searchText = ""
    var tabBeforeSearch: AppTab = .home
}
