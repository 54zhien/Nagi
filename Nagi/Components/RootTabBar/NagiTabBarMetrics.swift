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
    var searchFrame: CGRect
    var closeFrame: CGRect
    var itemFrames: [CGRect]
    var lensFrame: CGRect
    var contentBottomInset: CGFloat
    var isSearchExpanded: Bool
}

enum NagiTabBarMetrics {
    static let innerInset: CGFloat = 4
    static let itemHeight: CGFloat = 56
    static let barHeight: CGFloat = 64
    static let standaloneGap: CGFloat = 8
    static let mainItemCount = 3
    static let activeSearchHeight: CGFloat = 48
    static let horizontalMargin: CGFloat = 16
    static let keyboardLift: CGFloat = 8

    static var mainTabsWidth: CGFloat {
        innerInset * 2 + itemHeight * CGFloat(mainItemCount)
    }

    static var normalBarWidth: CGFloat {
        mainTabsWidth + standaloneGap + barHeight
    }

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
                searchFrame: .zero,
                closeFrame: .zero,
                itemFrames: Array(repeating: .zero, count: mainItemCount),
                lensFrame: .zero,
                contentBottomInset: 0,
                isSearchExpanded: state.isSearchExpanded
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
            bottomY = keyboardTop - keyboardLift
        } else {
            bottomY = bounds.maxY - max(safeAreaInsets.bottom + keyboardLift, keyboardLift)
        }

        let isExpanded = state.isSearchExpanded
        if isExpanded {
            let width = max(0, bounds.width - horizontalMargin * 2)
            let barFrame = CGRect(
                x: bounds.midX - width * 0.5,
                y: bottomY - barHeight,
                width: width,
                height: barHeight
            )
            let searchFrame = CGRect(
                x: barFrame.minX,
                y: barFrame.minY + (barHeight - activeSearchHeight) * 0.5,
                width: barFrame.width,
                height: activeSearchHeight
            )
            let insetFromVisibleBottom = keyboardOverlap > 0
                ? keyboardOverlap + keyboardLift
                : max(0, bounds.maxY - barFrame.minY - safeAreaInsets.bottom)

            return NagiTabBarLayout(
                tabBarFrame: barFrame,
                mainTabsFrame: .zero,
                searchFrame: searchFrame,
                closeFrame: searchFrame,
                itemFrames: Array(repeating: .zero, count: mainItemCount),
                lensFrame: .zero,
                contentBottomInset: insetFromVisibleBottom,
                isSearchExpanded: true
            )
        }

        let width = min(normalBarWidth, max(0, bounds.width - horizontalMargin * 2))
        let barFrame = CGRect(
            x: bounds.midX - width * 0.5,
            y: bottomY - barHeight,
            width: width,
            height: barHeight
        )
        let actualMainWidth = max(0, min(mainTabsWidth, width - barHeight - standaloneGap))
        let mainFrame = CGRect(x: barFrame.minX, y: barFrame.minY, width: actualMainWidth, height: barHeight)
        let searchX = min(barFrame.maxX - barHeight, mainFrame.maxX + standaloneGap)
        let searchFrame = CGRect(x: searchX, y: barFrame.minY, width: barHeight, height: barHeight)
        let itemWidth = actualMainWidth > innerInset * 2
            ? (actualMainWidth - innerInset * 2) / CGFloat(mainItemCount)
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
        let contentBottomInset = max(0, bounds.maxY - barFrame.minY - safeAreaInsets.bottom)

        return NagiTabBarLayout(
            tabBarFrame: barFrame,
            mainTabsFrame: mainFrame,
            searchFrame: searchFrame,
            closeFrame: .zero,
            itemFrames: itemFrames,
            lensFrame: selectedFrame,
            contentBottomInset: contentBottomInset,
            isSearchExpanded: false
        )
    }
}
