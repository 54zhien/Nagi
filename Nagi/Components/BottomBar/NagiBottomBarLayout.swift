//
//  NagiBottomBarLayout.swift
//  Nagi
//
//  One geometry source for the persistent root bottom bar.
//

import UIKit

enum NagiBottomBarLayout {
    static let barHeight: CGFloat = 64
    static let controlSize: CGFloat = 48
    static let barHorizontalInset: CGFloat = 12
    static let innerInset: CGFloat = 8
    static let bottomSpacing: CGFloat = 8
    static let itemSpacing: CGFloat = 8

    static func barFrame(
        bounds: CGRect,
        safeAreaInsets: UIEdgeInsets,
        keyboardFrame: CGRect?
    ) -> CGRect {
        let keyboardOverlap = keyboardOverlap(
            in: bounds,
            safeAreaInsets: safeAreaInsets,
            keyboardFrame: keyboardFrame
        )
        let bottomClearance = keyboardOverlap > 0
            ? bottomSpacing
            : max(safeAreaInsets.bottom, bottomSpacing)
        let width = max(bounds.width - (barHorizontalInset * 2), controlSize)
        let height = min(barHeight, max(bounds.height - bottomClearance, controlSize))
        return CGRect(
            x: bounds.midX - (width / 2),
            y: bounds.maxY - bottomClearance - height,
            width: width,
            height: height
        )
    }

    static func keyboardOverlap(
        in bounds: CGRect,
        safeAreaInsets: UIEdgeInsets,
        keyboardFrame: CGRect?
    ) -> CGFloat {
        guard let keyboardFrame,
              !keyboardFrame.isNull,
              keyboardFrame.intersects(bounds) else {
            return 0
        }

        // The keyboard frame is already converted to the root view's
        // coordinate space by KeyboardTransitionCoordinator. The safe area is
        // intentionally not added here: the end frame is the exact moving
        // edge during presentation, dismissal, and interactive dismissal.
        _ = safeAreaInsets
        return max(0, bounds.maxY - keyboardFrame.minY)
    }

    static func normalItemFrames(in barBounds: CGRect) -> [CGRect] {
        let totalWidth = (controlSize * 4) + (itemSpacing * 3)
        let startX = max(innerInset, (barBounds.width - totalWidth) / 2)
        let y = barBounds.midY - (controlSize / 2)
        return (0 ..< 4).map { index in
            CGRect(
                x: startX + CGFloat(index) * (controlSize + itemSpacing),
                y: y,
                width: controlSize,
                height: controlSize
            )
        }
    }

    static func activeSearchFrame(in barBounds: CGRect) -> CGRect {
        barBounds.insetBy(dx: innerInset, dy: (barBounds.height - controlSize) / 2)
    }

    static func additionalBottomSafeArea(
        barFrame: CGRect,
        systemSafeAreaInsets: UIEdgeInsets,
        bounds: CGRect
    ) -> CGFloat {
        let occupiedBottom = max(0, bounds.maxY - barFrame.minY)
        return max(0, occupiedBottom - systemSafeAreaInsets.bottom)
    }
}
