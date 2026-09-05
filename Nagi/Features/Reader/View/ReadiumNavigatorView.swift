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
        guard !isReflowable else { return }
        uiViewController.view.backgroundColor = UIColor(background)
    }
}

extension EPUBNavigatorViewController {
    /// The UIKit ReaderViewController owns the full reflowable background.
    /// Readium's hierarchy must therefore stay transparent, including the
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

    /// Applies an app-owned document override to the visible spread only.
    /// `evaluateJavaScript(_:)` on the navigator targets the current spread;
    /// direct WebView evaluation is preferred when the spread is available so
    /// a newly visible page is never held behind an off-screen preload.
    @MainActor
    func applyNagiReaderOverridesToVisible(_ script: String) async {
        let webViews = makeNagiReaderWebViews(in: view)
            .filter { isNagiReaderWebViewVisible($0, in: view) }
        guard !webViews.isEmpty else {
            guard !Task.isCancelled else { return }
            _ = await evaluateJavaScript(script)
            return
        }

        for webView in webViews {
            guard !Task.isCancelled else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                webView.evaluateJavaScript(script) { _, _ in
                    continuation.resume()
                }
            }
        }

    }

    /// Updates off-screen/preloaded spread WebViews after the visible spread
    /// has received its mutation. This path yields between documents so it
    /// cannot serialize an all-preload pass into the user-visible transition.
    @MainActor
    func applyNagiReaderOverridesToPreloaded(_ script: String) async {
        let webViews = makeNagiReaderWebViews(in: view)
        let visibleIDs = Set(
            webViews
                .filter { isNagiReaderWebViewVisible($0, in: view) }
                .map(ObjectIdentifier.init)
        )

        for webView in webViews where !visibleIDs.contains(ObjectIdentifier(webView)) {
            guard !Task.isCancelled else { return }
            await evaluateNagiReaderJavaScript(script, in: webView)
            await Task.yield()
        }
    }

    /// Waits for the current spread to paint two animation frames after a
    /// mutation. The caller can retry while the first spread is attaching.
    @MainActor
    @discardableResult
    func waitForNagiReaderReadiness(_ script: String) async -> Bool {
        let visibleWebViews = makeNagiReaderWebViews(in: view)
            .filter { isNagiReaderWebViewVisible($0, in: view) }
        let firstPass: Bool
        if visibleWebViews.isEmpty {
            let result = await evaluateJavaScript(script)
            if case let .success(value) = result {
                firstPass = (value as? String) == "ready"
            } else {
                firstPass = false
            }
        } else {
            firstPass = await evaluateNagiReaderReadiness(script, in: view)
        }
        guard !firstPass else { return true }
        guard !Task.isCancelled else { return false }

        do {
            try await Task.sleep(nanoseconds: 60_000_000)
        } catch {
            return false
        }

        guard !Task.isCancelled else { return false }
        let currentWebViews = makeNagiReaderWebViews(in: view)
            .filter { isNagiReaderWebViewVisible($0, in: view) }
        if currentWebViews.isEmpty {
            let result = await evaluateJavaScript(script)
            if case let .success(value) = result {
                return (value as? String) == "ready"
            }
            return false
        } else {
            return await evaluateNagiReaderReadiness(script, in: view)
        }
    }
}

@MainActor
private func evaluateNagiReaderReadiness(_ script: String, in navigatorView: UIView) async -> Bool {
    let webViews = makeNagiReaderWebViews(in: navigatorView)
        .filter { isNagiReaderWebViewVisible($0, in: navigatorView) }

    guard !webViews.isEmpty else { return false }

    let asyncScript = """
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    return \(script);
    """

    for webView in webViews {
        guard !Task.isCancelled else { return false }
        let result: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            webView.callAsyncJavaScript(
                asyncScript,
                arguments: [:],
                in: nil,
                in: WKContentWorld.page
            ) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: (value as? String) == "ready")
                case .failure:
                    continuation.resume(returning: false)
                }
            }
        }
        if result { return true }
    }

    return false
}

@MainActor
private func evaluateNagiReaderJavaScript(_ script: String, in webView: WKWebView) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        webView.evaluateJavaScript(script) { _, _ in
            continuation.resume()
        }
    }
}

private func makeNagiReaderHierarchyTransparent(_ view: UIView) {
    view.backgroundColor = .clear
    view.isOpaque = false

    if let webView = view as? WKWebView {
        webView.underPageBackgroundColor = .clear
    }

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

@MainActor
private func isNagiReaderWebViewVisible(_ webView: WKWebView, in navigatorView: UIView) -> Bool {
    var current: UIView? = webView
    while let view = current {
        guard !view.isHidden, view.alpha > 0.01 else { return false }
        current = view.superview
    }

    let frame = webView.convert(webView.bounds, to: navigatorView)
    guard frame.width > 1, frame.height > 1 else { return false }
    return frame.intersects(navigatorView.bounds)
}
