
import SwiftUI
import UIKit

@MainActor
final class NagiRootViewController: UIViewController {
    let contentContainerView = UIView(frame: .zero)
    let tabBarView = NagiTabBarView()
    private let searchOverlayView = UIView(frame: .zero)

    private lazy var searchOverlayDismissTapGesture: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleSearchOverlayDismissTap(_:))
        )
        recognizer.cancelsTouchesInView = false
        recognizer.isEnabled = false
        return recognizer
    }()

    let state = NagiRootState()
    private var hostingControllers: [AppTab: UIHostingController<AnyView>] = [:]
    private var searchHostingController: UIHostingController<AnyView>?
    private var keyboardCoordinator: NagiKeyboardLayoutCoordinator?
    private var currentLayoutState = NagiRootLayoutState.initial
    private var observedKeyboardFrame: CGRect?
    private var reduceMotion: Bool
    private var reduceTransparency: Bool
    private var showTabBarLabels: Bool
    private var liquidGlassEnabled: Bool
    private var displayedTab: AppTab?
    private var pageTransitionGeneration = 0
    private var searchOverlayGeneration = 0

    init(
        reduceMotion: Bool,
        reduceTransparency: Bool,
        showTabBarLabels: Bool = true,
        liquidGlassEnabled: Bool = true
    ) {
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.showTabBarLabels = showTabBarLabels
        self.liquidGlassEnabled = liquidGlassEnabled
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = pageBackgroundColor(for: .home)
        view.isOpaque = true
        contentContainerView.backgroundColor = .clear
        contentContainerView.clipsToBounds = false
        view.addSubview(contentContainerView)
        view.addSubview(tabBarView)

        installPersistentChildren()
        wireTabBar()

        keyboardCoordinator = NagiKeyboardLayoutCoordinator(view: view) {
            [weak self] frame, transition in
            self?.applyKeyboardFrame(frame, transition: transition)
        }

        showChild(for: .home, transition: .immediate)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        reconcileLayout(transition: .immediate)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        reconcileLayout(transition: .immediate)
    }

    func updatePreferences(
        reduceMotion: Bool,
        reduceTransparency: Bool,
        showTabBarLabels: Bool,
        liquidGlassEnabled: Bool
    ) {
        let changed =
            self.reduceMotion != reduceMotion ||
            self.reduceTransparency != reduceTransparency ||
            self.showTabBarLabels != showTabBarLabels ||
            self.liquidGlassEnabled != liquidGlassEnabled

        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.showTabBarLabels = showTabBarLabels
        self.liquidGlassEnabled = liquidGlassEnabled

        guard changed else { return }
        reconcileLayout(transition: .immediate, force: true)
    }

    func stopKeyboardObservation() {
        keyboardCoordinator?.stop()
        keyboardCoordinator = nil
    }

    private func installPersistentChildren() {
        let tabs: [AppTab] = [.home, .library, .settings]

        for tab in tabs {
            let controller = makeHostingController(for: tab)
            hostingControllers[tab] = controller
            addChild(controller)

            controller.view.backgroundColor = pageBackgroundColor(for: tab)
            controller.view.isOpaque = true
            controller.view.frame = contentContainerView.bounds
            contentContainerView.addSubview(controller.view)
            controller.didMove(toParent: self)

            let isHome = tab == .home
            controller.view.alpha = 1
            controller.view.isHidden = !isHome
            controller.view.isUserInteractionEnabled = isHome
        }

        searchOverlayView.frame = contentContainerView.bounds
        searchOverlayView.backgroundColor = .clear
        searchOverlayView.isOpaque = false
        searchOverlayView.alpha = 1
        searchOverlayView.isHidden = true
        searchOverlayView.isUserInteractionEnabled = false
        contentContainerView.addSubview(searchOverlayView)
        searchOverlayView.addGestureRecognizer(searchOverlayDismissTapGesture)

        let searchController = makeSearchHostingController()
        searchHostingController = searchController
        addChild(searchController)
        searchController.view.backgroundColor = .clear
        searchController.view.isOpaque = false
        searchController.view.frame = searchOverlayView.bounds
        searchController.view.alpha = 1
        searchController.view.isHidden = false
        searchController.view.isUserInteractionEnabled = true
        searchOverlayView.addSubview(searchController.view)
        searchController.didMove(toParent: self)
    }

    private func pageBackgroundColor(for tab: AppTab) -> UIColor {
        switch tab {
        case .settings:
            return .systemGroupedBackground
        case .home, .library:
            return .systemBackground
        }
    }

    private func makeHostingController(
        for tab: AppTab
    ) -> UIHostingController<AnyView> {
        let rootView: AnyView

        switch tab {
        case .home:
            rootView = AnyView(
                HomeView().modelContainer(Persistence.container)
            )
        case .library:
            rootView = AnyView(
                LibraryView().modelContainer(Persistence.container)
            )
        case .settings:
            rootView = AnyView(
                SettingsView().modelContainer(Persistence.container)
            )
        }

        return UIHostingController(rootView: rootView)
    }

    private func makeSearchHostingController() -> UIHostingController<AnyView> {
        UIHostingController(
            rootView: AnyView(
                NagiSearchHostView(state: state)
                    .modelContainer(Persistence.container)
            )
        )
    }

    private func wireTabBar() {
        tabBarView.onTabSelected = { [weak self] tab in
            self?.select(tab: tab)
        }
        tabBarView.onSearchActivated = { [weak self] in
            self?.activateSearch()
        }
        tabBarView.onSearchCancelled = { [weak self] in
            self?.deactivateSearch()
        }
        tabBarView.onSearchQueryChanged = { [weak self] query in
            guard let self else { return }

            state.searchText = query
            searchOverlayDismissTapGesture.isEnabled =
                query.isEmpty && state.tabBarSearchState.isActive
        }
    }

    private func select(tab: AppTab) {
        guard !state.tabBarSearchState.isActive,
              state.selectedTab != tab else {
            return
        }

        state.selectedTab = tab
        let transition = effectiveTransition(.spring(duration: 0.4))
        showChild(for: tab, transition: transition)
        reconcileLayout(transition: transition)
    }

    private func activateSearch() {
        guard !state.tabBarSearchState.isActive else { return }

        state.searchText = ""
        tabBarView.setSearchQuery("")

        presentSearchOverlay()
        state.tabBarSearchState = NagiTabBarSearchState(isActive: true)
        searchOverlayDismissTapGesture.isEnabled = true

        reconcileLayout(
            transition: effectiveTransition(.spring(duration: 0.5))
        )
        tabBarView.becomeSearchFirstResponder()
    }

    private func deactivateSearch() {
        guard state.tabBarSearchState.isActive else { return }

        tabBarView.resignSearchFirstResponder()
        state.searchText = ""
        tabBarView.setSearchQuery("")
        searchOverlayDismissTapGesture.isEnabled = false
        state.tabBarSearchState = .inactive

        let transition = effectiveTransition(.spring(duration: 0.5))
        reconcileLayout(transition: transition)
        dismissSearchOverlay()
    }

    private func showChild(
        for tab: AppTab,
        transition: NagiTabTransition
    ) {
        view.backgroundColor = pageBackgroundColor(for: tab)

        guard !transition.isImmediate,
              let oldTab = displayedTab,
              oldTab != tab,
              let oldView = hostingControllers[oldTab]?.view,
              let newView = hostingControllers[tab]?.view else {
            pageTransitionGeneration += 1

            for (childTab, controller) in hostingControllers {
                let isVisible = childTab == tab
                controller.view.layer.removeAnimation(
                    forKey: "transform.scale"
                )
                NagiTabTransition.immediate.setAlpha(
                    view: controller.view,
                    alpha: 1
                )
                NagiTabTransition.immediate.setScale(
                    view: controller.view,
                    scale: 1
                )
                controller.view.layer.allowsGroupOpacity = false
                controller.view.isHidden = !isVisible
                controller.view.isUserInteractionEnabled = isVisible
            }

            displayedTab = tab
            return
        }

        pageTransitionGeneration += 1
        let generation = pageTransitionGeneration

        let transitionScale: CGFloat
        if oldView.frame.height > 0 {
            transitionScale =
                (oldView.frame.height - 3.0) / oldView.frame.height
        } else {
            transitionScale = 0.998
        }

        oldView.layer.removeAnimation(forKey: "transform.scale")
        newView.layer.removeAnimation(forKey: "transform.scale")
        NagiTabTransition.immediate.setScale(view: oldView, scale: 1)
        NagiTabTransition.immediate.setScale(view: newView, scale: 1)

        oldView.isHidden = false
        oldView.isUserInteractionEnabled = false
        oldView.layer.allowsGroupOpacity = false

        newView.isHidden = false
        newView.isUserInteractionEnabled = false
        newView.layer.allowsGroupOpacity = true
        NagiTabTransition.immediate.setAlpha(view: newView, alpha: 0)

        animatePageScale(
            layer: oldView.layer,
            from: 1.0,
            to: transitionScale,
            duration: 0.12,
            removeOnCompletion: false,
            completion: { [weak self, weak oldView] completed in
                guard completed, let self else { return }

                guard generation == pageTransitionGeneration ||
                        displayedTab != oldTab else {
                    return
                }

                oldView?.layer.removeAnimation(forKey: "transform.scale")
                oldView?.alpha = 1
                oldView?.isHidden = true
                oldView?.isUserInteractionEnabled = false
            }
        )

        animatePageScale(
            layer: newView.layer,
            from: transitionScale,
            to: 1.0,
            duration: 0.15,
            delay: 0.1,
            removeOnCompletion: true
        )

        NagiTabTransition.easeInOut(duration: 0.1).setAlpha(
            view: newView,
            alpha: 1,
            completion: { [weak self, weak newView] completed in
                guard completed,
                      let self,
                      generation == pageTransitionGeneration else {
                    return
                }

                newView?.layer.allowsGroupOpacity = false
                newView?.isUserInteractionEnabled = true
            }
        )

        displayedTab = tab
    }

    private func animatePageScale(
        layer: CALayer,
        from: CGFloat,
        to: CGFloat,
        duration: TimeInterval,
        delay: TimeInterval = 0,
        removeOnCompletion: Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        NagiTabTransition.spring(duration: duration).animateScale(
            layer: layer,
            from: from,
            to: to,
            delay: delay,
            removeOnCompletion: removeOnCompletion,
            completion: completion
        )
    }

    private func presentSearchOverlay() {
        guard let searchController = searchHostingController else {
            return
        }

        searchOverlayGeneration += 1
        searchOverlayView.layer.removeAllAnimations()
        searchController.view.layer.removeAllAnimations()

        searchOverlayView.isHidden = false
        searchOverlayView.isUserInteractionEnabled = true
        searchOverlayDismissTapGesture.isEnabled = false
        searchOverlayView.alpha = 1
        searchController.view.alpha = 0

        if reduceMotion {
            searchController.view.alpha = 1
            return
        }

        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            options: [
                .curveEaseOut,
                .allowUserInteraction,
                .beginFromCurrentState
            ],
            animations: {
                searchController.view.alpha = 1
            }
        )
    }

    @objc
    private func handleSearchOverlayDismissTap(
        _ recognizer: UITapGestureRecognizer
    ) {
        guard recognizer.state == .ended,
              state.tabBarSearchState.isActive,
              state.searchText.isEmpty else {
            return
        }

        deactivateSearch()
    }

    private func dismissSearchOverlay() {
        searchOverlayGeneration += 1
        let generation = searchOverlayGeneration

        searchOverlayDismissTapGesture.isEnabled = false
        searchOverlayView.isUserInteractionEnabled = false

        guard !reduceMotion else {
            searchOverlayView.alpha = 1
            searchOverlayView.isHidden = true
            return
        }

        searchOverlayView.layer.removeAllAnimations()

        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            options: [
                .curveEaseInOut,
                .allowUserInteraction,
                .beginFromCurrentState
            ],
            animations: {
                self.searchOverlayView.alpha = 0
            },
            completion: { [weak self] finished in
                guard let self,
                      finished,
                      searchOverlayGeneration == generation else {
                    return
                }

                searchOverlayView.isHidden = true
                searchOverlayView.alpha = 1
                searchHostingController?.view.alpha = 1
            }
        )
    }

    private func applyKeyboardFrame(
        _ frame: CGRect?,
        transition: NagiTabTransition
    ) {
        observedKeyboardFrame = frame
        reconcileLayout(transition: effectiveTransition(transition))
    }

    private func reconcileLayout(
        transition: NagiTabTransition,
        force: Bool = false
    ) {
        let nextState = NagiRootLayoutState(
            bounds: view.bounds,
            safeAreaInsets: view.safeAreaInsets,
            keyboardFrame: observedKeyboardFrame,
            selectedTab: state.selectedTab,
            searchState: state.tabBarSearchState
        )

        guard force ||
                nextState != currentLayoutState ||
                tabBarView.frame == .zero else {
            return
        }

        let layout = NagiTabBarMetrics.calculateLayout(
            bounds: nextState.bounds,
            safeAreaInsets: nextState.safeAreaInsets,
            keyboardFrame: nextState.keyboardFrame,
            searchState: nextState.searchState
        )
        let resolvedTransition = effectiveTransition(transition)
        currentLayoutState = nextState

        resolvedTransition.perform { [weak self] in
            guard let self else { return }

            resolvedTransition.setFrame(
                view: contentContainerView,
                frame: view.bounds
            )
            resolvedTransition.setFrame(
                view: searchOverlayView,
                frame: contentContainerView.bounds
            )
            resolvedTransition.setFrame(
                view: tabBarView,
                frame: layout.tabBarFrame
            )

            if let searchController = searchHostingController {
                resolvedTransition.setFrame(
                    view: searchController.view,
                    frame: searchOverlayView.bounds
                )
            }

            for controller in hostingControllers.values {
                resolvedTransition.setFrame(
                    view: controller.view,
                    frame: contentContainerView.bounds
                )
            }

            tabBarView.update(
                layout: layout,
                selectedTab: nextState.selectedTab,
                searchState: nextState.searchState,
                reduceTransparency: reduceTransparency,
                showItemTitles: showTabBarLabels,
                liquidGlassEnabled: liquidGlassEnabled,
                transition: resolvedTransition
            )
        }
    }

    private func effectiveTransition(
        _ transition: NagiTabTransition
    ) -> NagiTabTransition {
        reduceMotion ? .immediate : transition
    }
}

private struct NagiSearchHostView: View {
    @ObservedObject var state: NagiRootState

    var body: some View {
        SearchView(searchText: $state.searchText)
    }
}
