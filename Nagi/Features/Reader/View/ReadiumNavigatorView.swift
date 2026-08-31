//
//  ReadiumNavigatorView.swift
//  Nagi
//
//  将 Readium 的 UIKit Navigator 嵌入 SwiftUI。
//

import ReadiumNavigator
import SwiftUI
import UIKit

struct ReadiumNavigatorView: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    let background: SwiftUI.Color
    let isReflowable: Bool

    func makeUIViewController(context: Context) -> EPUBNavigatorViewController {
        navigator.applyNagiReaderBaseAppearance(
            isReflowable: isReflowable,
            fallbackBackground: UIColor(background)
        )
        return navigator
    }

    func updateUIViewController(
        _ uiViewController: EPUBNavigatorViewController,
        context: Context
    ) {
        uiViewController.applyNagiReaderBaseAppearance(
            isReflowable: isReflowable,
            fallbackBackground: UIColor(background)
        )
    }
}

extension EPUBNavigatorViewController {
    /// The SwiftUI ReaderChrome owns the full reflowable background. Readium's
    /// UIKit hierarchy must therefore stay transparent, including the
    /// scroll-view and WKWebView containers created after the navigator is
    /// initialized.
    func applyNagiReaderBaseAppearance(
        isReflowable: Bool,
        fallbackBackground: UIColor
    ) {
        guard isReflowable else {
            view.backgroundColor = fallbackBackground
            return
        }

        makeNagiReaderHierarchyTransparent(view)
    }
}

private func makeNagiReaderHierarchyTransparent(_ view: UIView) {
    view.backgroundColor = .clear
    view.isOpaque = false

    if let scrollView = view as? UIScrollView {
        scrollView.backgroundColor = .clear
    }

    for subview in view.subviews {
        makeNagiReaderHierarchyTransparent(subview)
    }
}
