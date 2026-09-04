
import UIKit

struct NagiTabBarLayout: Equatable {
    var tabBarFrame: CGRect
    var mainTabsFrame: CGRect
}

enum NagiTabBarMetrics {
    static let innerInset: CGFloat = 4
    static let itemHeight: CGFloat = 56
    static let barHeight: CGFloat = itemHeight + innerInset * 2
    static let searchDiameter: CGFloat = 64
    static let searchCloseDiameter: CGFloat = 48
    static let collapsedLensDiameter: CGFloat = 48
    static let standaloneGap: CGFloat = 8
    static let activeSearchHeight: CGFloat = 48

    static func calculateLayout(
        bounds: CGRect,
        safeAreaInsets: UIEdgeInsets,
        keyboardFrame: CGRect?,
        searchState: NagiTabBarSearchState
    ) -> NagiTabBarLayout {
        guard !bounds.isEmpty else {
            return NagiTabBarLayout(
                tabBarFrame: .zero,
                mainTabsFrame: .zero
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

        guard searchState.isActive else {
            return NagiTabBarLayout(
                tabBarFrame: barFrame,
                mainTabsFrame: mainFrame
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
        return NagiTabBarLayout(
            tabBarFrame: barFrame,
            mainTabsFrame: collapsedFrame
        )
    }
}
