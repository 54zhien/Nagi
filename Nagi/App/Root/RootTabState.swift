//
//  RootTabState.swift
//  Nagi
//
//  State vocabulary for the persistent UIKit root container.
//

import Foundation

enum AppTab: Hashable, CaseIterable {
    case home
    case library
    case settings
    case search
}

enum BottomBarMode: Equatable {
    case tabs
    case searchInactive
    case searchActive
}

@MainActor
final class RootTabState {
    var selectedTab: AppTab = .home
    var mode: BottomBarMode = .tabs
    var tabBeforeSearch: AppTab = .home
}
