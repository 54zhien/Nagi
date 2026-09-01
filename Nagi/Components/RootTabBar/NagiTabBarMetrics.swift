//
//  NagiTabBarMetrics.swift
//  Nagi
//
//  Root 底栏的唯一几何计算入口。参数沿用当前原生 TabBar 视觉基线，
//  搜索展开和键盘移动也只改变这份 layout 结果。
//

import UIKit

struct NagiTabBarLayout: Equatable {
    var tabBarFrame: CGRect
    var mainTabsFrame: CGRect
    var searchContainerFrame: CGRect
    var searchBackgroundFrame: CGRect
    var searchCloseFrame: CGRect
    var itemFrames: [CGRect]
    var lensSelectionFrame: CGRect
    var lensContainerFrame: CGRect
    var isSearchActive: Bool
    var isLensCollapsed: Bool
}

enum NagiTabBarMetrics {
    static let innerInset: CGFloat = 4
    static let itemHeight: CGFloat = 56
    static let barHeight: CGFloat = 64
    static let searchDiameter: CGFloat = 64
    static let searchCloseDiameter: CGFloat = 48
    static let collapsedLensDiameter: CGFloat = 48
    static let collapsedOffscreenClearance: CGFloat = 24
    static let standaloneGap: CGFloat = 8
    static let mainItemCount = 3
    static let activeSearchHeight: CGFloat = 48
    static let horizontalMargin: CGFloat = 16
    static let normalBottomSpacing: CGFloat = 4
    static let keyboardSpacing: CGFloat = 8

    static func calculateLayout(
        bounds: CGRect,
        safeAreaInsets: UIEdgeInsets,
        keyboardFrame: CGRect?,
        state: NagiRootTabMode
    ) -> NagiTabBarLayout {
        guard !bounds.isEmpty else {
            return NagiTabBarLayout(
                tabBarFrame: .zero,
                mainTabsFrame: .zero,
                searchContainerFrame: .zero,
                searchBackgroundFrame: .zero,
                searchCloseFrame: .zero,
                itemFrames: Array(repeating: .zero, count: mainItemCount),
                lensSelectionFrame: .zero,
                lensContainerFrame: .zero,
                isSearchActive: state.isSearchActive,
                isLensCollapsed: state.isSearchActive
            )
        }

        let keyboardOverlap: CGFloat
        let keyboardTop: CGFloat?
        if let keyboardFrame, !keyboardFrame.isNull, keyboardFrame.intersects(bounds) {
            keyboardTop = max(bounds.minY, min(bounds.maxY, keyboardFrame.minY))
            keyboardOverlap = max(0, bounds.maxY - (keyboardTop ?? bounds.maxY))
        } else {
            keyboardTop = nil
            keyboardOverlap = 0
        }

        let bottomY: CGFloat
        if let keyboardTop, state.isSearchVisible, keyboardOverlap > 0 {
            bottomY = keyboardTop - keyboardSpacing
        } else {
            bottomY = bounds.maxY - safeAreaInsets.bottom - normalBottomSpacing
        }

        let normalBarWidth = max(0, bounds.width - horizontalMargin * 2)
        let width = normalBarWidth
        let barFrame = CGRect(
            x: bounds.midX - width * 0.5,
            y: bottomY - barHeight,
            width: width,
            height: barHeight
        )

        if state.isSearchActive {
            let collapsedFrame = CGRect(
                x: bounds.minX - collapsedLensDiameter - collapsedOffscreenClearance,
                y: barFrame.minY + (barHeight - collapsedLensDiameter) * 0.5,
                width: collapsedLensDiameter,
                height: collapsedLensDiameter
            )
            let searchBackgroundFrame = CGRect(
                x: barFrame.minX,
                y: barFrame.minY + (barHeight - activeSearchHeight) * 0.5,
                width: max(0, barFrame.width - searchCloseDiameter - standaloneGap),
                height: activeSearchHeight
            )
            let searchCloseFrame = CGRect(
                x: searchBackgroundFrame.maxX + standaloneGap,
                y: searchBackgroundFrame.minY,
                width: searchCloseDiameter,
                height: searchCloseDiameter
            )

            return NagiTabBarLayout(
                tabBarFrame: barFrame,
                mainTabsFrame: collapsedFrame,
                searchContainerFrame: barFrame,
                searchBackgroundFrame: searchBackgroundFrame,
                searchCloseFrame: searchCloseFrame,
                itemFrames: Array(repeating: collapsedFrame, count: mainItemCount),
                lensSelectionFrame: collapsedFrame,
                lensContainerFrame: collapsedFrame,
                isSearchActive: true,
                isLensCollapsed: true
            )
        }

        // The original Nagi system TabView uses the available width for the
        // complete floating bar. Keep the search surface independent, then
        // distribute the remaining main capsule width across the three tabs.
        let mainTabsWidth = max(0, normalBarWidth - standaloneGap - searchDiameter)
        let mainFrame = CGRect(x: barFrame.minX, y: barFrame.minY, width: mainTabsWidth, height: barHeight)
        let searchContainerFrame = CGRect(
            x: mainFrame.maxX + standaloneGap,
            y: barFrame.minY,
            width: searchDiameter,
            height: searchDiameter
        )
        let itemWidth = mainTabsWidth > innerInset * 2
            ? (mainTabsWidth - innerInset * 2) / CGFloat(mainItemCount)
            : 0
        let itemFrames = (0..<mainItemCount).map { index in
            CGRect(
                x: mainFrame.minX + innerInset + CGFloat(index) * itemWidth,
                y: mainFrame.minY + innerInset,
                width: itemWidth,
                height: itemHeight
            )
        }
        let selectedIndex: Int
        switch state.selectedTab {
        case .home: selectedIndex = 0
        case .library: selectedIndex = 1
        case .settings: selectedIndex = 2
        case .search: selectedIndex = 0
        }
        let selectedFrame = itemFrames.indices.contains(selectedIndex) ? itemFrames[selectedIndex] : .zero
        let searchCloseFrame = CGRect(
            x: searchContainerFrame.midX - searchCloseDiameter * 0.5,
            y: searchContainerFrame.midY - searchCloseDiameter * 0.5,
            width: searchCloseDiameter,
            height: searchCloseDiameter
        )

        return NagiTabBarLayout(
            tabBarFrame: barFrame,
            mainTabsFrame: mainFrame,
            searchContainerFrame: searchContainerFrame,
            searchBackgroundFrame: searchContainerFrame,
            searchCloseFrame: searchCloseFrame,
            itemFrames: itemFrames,
            lensSelectionFrame: selectedFrame,
            lensContainerFrame: mainFrame,
            isSearchActive: false,
            isLensCollapsed: false
        )
    }
}
