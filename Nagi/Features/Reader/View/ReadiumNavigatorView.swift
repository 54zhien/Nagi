//
//  ReadiumNavigatorView.swift
//  Nagi
//
//  将 Readium 的 UIKit Navigator 嵌入 SwiftUI。
//

import ReadiumNavigator
import SwiftUI
import UIKit
import WebKit

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

    /// Applies an app-owned document override to every spread WebView that
    /// Readium has already created. `evaluateJavaScript(_:)` on the navigator
    /// itself only targets the current spread, while preloaded spreads keep
    /// their own document and need the same update before they become visible.
    @MainActor
    func applyNagiReaderOverrides(_ script: String) async {
        let webViews = makeNagiReaderWebViews(in: view)
        guard !webViews.isEmpty else {
            _ = await evaluateJavaScript(script)
            return
        }

        for webView in webViews {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                webView.evaluateJavaScript(script) { _, _ in
                    continuation.resume()
                }
            }
        }

        // Keep Readium's spread-loaded path for the current resource. Direct
        // WKWebView evaluation is useful for preloads, but can otherwise run
        // before the current spread has finished loading its document.
        _ = await evaluateJavaScript(script)
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

@MainActor
private func makeNagiReaderWebViews(in view: UIView) -> [WKWebView] {
    var webViews: [WKWebView] = []
    if let webView = view as? WKWebView {
        webViews.append(webView)
    }
    for subview in view.subviews {
        webViews.append(contentsOf: makeNagiReaderWebViews(in: subview))
    }
    return webViews
}
