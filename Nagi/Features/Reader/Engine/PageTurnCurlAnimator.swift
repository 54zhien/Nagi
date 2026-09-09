import ReadiumNavigator
import UIKit

/// Immutable page pixels used by the reader's persistent system page-curl
/// controller. Keeping snapshots detached prevents WebKit layout or locator
/// updates from entering the interactive animation hierarchy.

@MainActor
final class PageTurnSnapshotViewController: UIViewController {
    private let snapshotView: UIView
    let pageDirection: PageDirection?
    let surfaceIdentity: NavigatorPageSurfaceIdentity?

    init(
        view: UIView,
        pageDirection: PageDirection? = nil,
        surfaceIdentity: NavigatorPageSurfaceIdentity? = nil
    ) {
        snapshotView = view
        self.pageDirection = pageDirection
        self.surfaceIdentity = surfaceIdentity
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = snapshotView
    }

}
