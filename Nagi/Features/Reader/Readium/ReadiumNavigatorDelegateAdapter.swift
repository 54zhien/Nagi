import ReadiumNavigator
import ReadiumShared
import UIKit
import WebKit

/// What the navigator delegate needs from the reader.
///
/// Keeping this narrow lets the delegate conformance live outside the reader
/// model, and keeps the direction of the dependency explicit.
@MainActor
protocol ReadiumNavigatorDelegateHost: AnyObject {
    /// True when the publication is fixed layout, in which case the document
    /// overrides must not be injected.
    var isFixedLayout: Bool { get }
    /// The style snapshot injected into every document.
    var styleSnapshot: ReadiumStyleSnapshot { get }
    /// The generation stamped into the document override.
    var overrideGeneration: UInt64 { get }
    /// Width of the navigator view, used to split tap regions.
    var navigatorViewWidth: CGFloat { get }

    func beginOverrideGenerationIfNeeded()
    func navigatorPresentationDidChange()
    func navigatorLocationDidChange(_ locator: Locator)
    func navigatorDidFail(_ error: NavigatorError)
    /// The tap x position in the navigator's coordinate space.
    func navigatorDidTap(atX x: CGFloat)
}

/// Translates Readium's navigator callbacks into reader-level events.
@MainActor
final class ReadiumNavigatorDelegateAdapter: EPUBNavigatorDelegate {
    weak var host: ReadiumNavigatorDelegateHost?

    func navigator(
        _ navigator: VisualNavigator,
        presentationDidChange presentation: VisualNavigatorPresentation
    ) {
        host?.navigatorPresentationDidChange()
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        host?.navigatorLocationDidChange(locator)
    }

    func navigator(_ navigator: Navigator, didJumpTo locator: Locator) {
        host?.navigatorLocationDidChange(locator)
    }

    func navigator(
        _ navigator: EPUBNavigatorViewController,
        setupUserScripts userContentController: WKUserContentController
    ) {
        guard let host, !host.isFixedLayout else { return }
        host.beginOverrideGenerationIfNeeded()
        let snapshot = host.styleSnapshot

        userContentController.addUserScript(
            WKUserScript(
                source: ReadiumJavaScriptBuilder.bootstrap(snapshot: snapshot),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        userContentController.addUserScript(
            WKUserScript(
                source: ReadiumJavaScriptBuilder.override(
                    snapshot: snapshot,
                    requestGeneration: host.overrideGeneration
                ),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        host?.navigatorDidFail(error)
    }

    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        host?.navigatorDidTap(atX: point.x)
    }
}
