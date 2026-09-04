
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
    static let standaloneGap: CGFloat = 8
    static let mainItemCount = 3
    static let activeSearchHeight: CGFloat = 48

    static func calculateLayout(
        bounds: CGRect,
        safeAreaInsets: UIEdgeInsets,
        keyboardFrame: CGRect?,
        selectedTab: AppTab,
        searchState: NagiTabBarSearchState
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
                isSearchActive: searchState.isActive,
                isLensCollapsed: searchState.isActive
            )
        }

        let inputHeight: CGFloat
        if let keyboardFrame, !keyboardFrame.isNull, keyboardFrame.minY < bounds.maxY {
            inputHeight = max(0, bounds.maxY - keyboardFrame.minY)
        } else {
            inputHeight = 0
        }

        let systemPanelsBottomInset: CGFloat
        if safeAreaInsets.bottom == 0 {
            systemPanelsBottomInset = 8
        } else {
            systemPanelsBottomInset = max(safeAreaInsets.bottom, 8)
        }

        var tabBarBottomInset = systemPanelsBottomInset
        if searchState.isActive, inputHeight > 0 {
            tabBarBottomInset = max(tabBarBottomInset, inputHeight + 8)
        }

        let sideInsetReference = searchState.isActive && inputHeight > 0
            ? tabBarBottomInset
            : systemPanelsBottomInset
        let sideInset: CGFloat = sideInsetReference <= 28 ? 20 : 12
        let rawAvailableWidth = max(0, bounds.width - sideInset * 2)
        let componentWidth = min(500, rawAvailableWidth)
        let componentX = floorToScreenPixels(
            (bounds.width - componentWidth) * 0.5
        )
        let barFrame = CGRect(
            x: componentX,
            y: floorToScreenPixels(
                bounds.maxY - tabBarBottomInset - barHeight
            ),
            width: componentWidth,
            height: barHeight
        )

        let mainTabsWidth = max(
            0,
            componentWidth - standaloneGap - searchDiameter
        )
        let mainFrame = CGRect(
            x: floorToScreenPixels(barFrame.minX),
            y: floorToScreenPixels(barFrame.minY),
            width: mainTabsWidth,
            height: barHeight
        )
        let searchContainerFrame = CGRect(
            x: floorToScreenPixels(barFrame.maxX - searchDiameter),
            y: floorToScreenPixels(barFrame.minY),
            width: searchDiameter,
            height: searchDiameter
        )
        let itemWidth = mainTabsWidth > innerInset * 2
            ? floorToScreenPixels(
                (mainTabsWidth - innerInset * 2) / CGFloat(mainItemCount)
            )
            : 0
        let itemFrames = (0..<mainItemCount).map { index in
            CGRect(
                x: floorToScreenPixels(
                    innerInset + CGFloat(index) * itemWidth
                ),
                y: floorToScreenPixels(innerInset),
                width: itemWidth,
                height: itemHeight
            )
        }
        let selectedIndex: Int
        switch selectedTab {
        case .home: selectedIndex = 0
        case .library: selectedIndex = 1
        case .settings: selectedIndex = 2
        }
        let selectedFrame = itemFrames.indices.contains(selectedIndex) ? itemFrames[selectedIndex] : .zero

        guard searchState.isActive else {
            return NagiTabBarLayout(
                tabBarFrame: barFrame,
                mainTabsFrame: mainFrame,
                searchContainerFrame: searchContainerFrame,
                searchBackgroundFrame: searchContainerFrame,
                searchCloseFrame: .zero,
                itemFrames: itemFrames,
                lensSelectionFrame: selectedFrame,
                lensContainerFrame: mainFrame,
                isSearchActive: false,
                isLensCollapsed: false
            )
        }

        let collapsedFrame = CGRect(
            x: floorToScreenPixels(
                barFrame.minX - sideInset - collapsedLensDiameter
            ),
            y: floorToScreenPixels(
                barFrame.maxY - collapsedLensDiameter
            ),
            width: collapsedLensDiameter,
            height: collapsedLensDiameter
        )
        let activeSearchContainerFrame = CGRect(
            x: floorToScreenPixels(barFrame.minX),
            y: floorToScreenPixels(barFrame.maxY - activeSearchHeight),
            width: barFrame.width,
            height: activeSearchHeight
        )
        let activeSearchBackgroundFrame = CGRect(
            x: floorToScreenPixels(activeSearchContainerFrame.minX),
            y: floorToScreenPixels(activeSearchContainerFrame.minY),
            width: max(
                0,
                activeSearchContainerFrame.width -
                    searchCloseDiameter -
                    standaloneGap
            ),
            height: activeSearchHeight
        )
        let activeSearchCloseFrame = CGRect(
            x: floorToScreenPixels(
                activeSearchBackgroundFrame.maxX + standaloneGap
            ),
            y: floorToScreenPixels(activeSearchContainerFrame.minY),
            width: searchCloseDiameter,
            height: searchCloseDiameter
        )
        var activeLocalItemFrames = itemFrames
        if activeLocalItemFrames.indices.contains(selectedIndex) {
            activeLocalItemFrames[selectedIndex].origin.x = floorToScreenPixels(
                (collapsedLensDiameter -
                    activeLocalItemFrames[selectedIndex].width) * 0.5
            )
        }
        return NagiTabBarLayout(
            tabBarFrame: barFrame,
            mainTabsFrame: collapsedFrame,
            searchContainerFrame: activeSearchContainerFrame,
            searchBackgroundFrame: activeSearchBackgroundFrame,
            searchCloseFrame: activeSearchCloseFrame,
            itemFrames: activeLocalItemFrames,
            lensSelectionFrame: collapsedFrame,
            lensContainerFrame: collapsedFrame,
            isSearchActive: true,
            isLensCollapsed: true
        )
    }
}
