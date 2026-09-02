//
//  NagiRootViewController.swift
//  Nagi
//
//  Nagi 的正式 App Root。四个 SwiftUI 页面在这里一次性创建并完成
//  UIKit containment，之后只做 alpha/frame/state 更新。
//

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
        return recognizer
    }()

    let state = NagiRootState()
    private var hostingControllers: [AppTab: UIHostingController<AnyView>] = [:]
    private var keyboardCoordinator: NagiKeyboardLayoutCoordinator?
    private var currentLayoutState = NagiRootLayoutState.initial
    private var activeLayoutTransition: NagiTabTransition?
    private var keyboardTransitionGeneration = 0
    private var searchExitLayoutCompleted = false
    private var searchOverlayExitCompleted = false
    private var reduceMotion: Bool
    private var reduceTransparency: Bool

    init(reduceMotion: Bool, reduceTransparency: Bool) {
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // This is only the transition fallback. Each persistent hosting view
        // owns the same semantic page background while it is visible.
        view.backgroundColor = pageBackgroundColor(for: .home)
        view.isOpaque = true
        contentContainerView.backgroundColor = .clear
        contentContainerView.clipsToBounds = false
        view.addSubview(contentContainerView)
        view.addSubview(tabBarView)

        installPersistentChildren()
        wireTabBar()
        keyboardCoordinator = NagiKeyboardLayoutCoordinator(view: view) { [weak self] frame, transition in
            self?.applyKeyboardFrame(frame, transition: transition)
        }

        showChild(for: .home, transition: .immediate)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        reconcileLayout(transition: activeLayoutTransition ?? .immediate)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        reconcileLayout(transition: activeLayoutTransition ?? .immediate)
    }

    func updateAccessibility(reduceMotion: Bool, reduceTransparency: Bool) {
        let changed = self.reduceMotion != reduceMotion || self.reduceTransparency != reduceTransparency
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        guard changed else { return }
        reconcileLayout(transition: .immediate, force: true)
    }

    func stopKeyboardObservation() {
        keyboardCoordinator?.stop()
        keyboardCoordinator = nil
    }

    private func installPersistentChildren() {
        let tabs: [AppTab] = [.home, .library, .settings, .search]
        for tab in tabs {
            let controller = makeHostingController(for: tab)
            hostingControllers[tab] = controller
            addChild(controller)

            if tab == .search {
                controller.view.backgroundColor = .clear
                controller.view.isOpaque = false
                continue
            }

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

        if let searchController = hostingControllers[.search] {
            searchController.view.backgroundColor = .clear
            searchController.view.isOpaque = false
            searchController.view.frame = searchOverlayView.bounds
            searchController.view.alpha = 1
            searchController.view.isHidden = false
            searchController.view.isUserInteractionEnabled = true
            searchOverlayView.addSubview(searchController.view)
            searchController.didMove(toParent: self)
        }
    }

    private func pageBackgroundColor(for tab: AppTab) -> UIColor {
        switch tab {
        case .settings:
            return .systemGroupedBackground
        case .home, .library, .search:
            return .systemBackground
        }
    }

    private func makeHostingController(for tab: AppTab) -> UIHostingController<AnyView> {
        let rootView: AnyView
        switch tab {
        case .home:
            rootView = AnyView(HomeView().modelContainer(Persistence.container))
        case .library:
            rootView = AnyView(LibraryView().modelContainer(Persistence.container))
        case .settings:
            rootView = AnyView(SettingsView().modelContainer(Persistence.container))
        case .search:
            rootView = AnyView(NagiSearchHostView(state: state).modelContainer(Persistence.container))
        }
        return UIHostingController(rootView: rootView)
    }

    private func wireTabBar() {
        tabBarView.onTabSelected = { [weak self] tab in
            self?.select(tab: tab)
        }
        tabBarView.onSearchActivated = { [weak self] in
            self?.activateSearch()
        }
        tabBarView.onSearchCancelled = { [weak self] in
            self?.cancelSearch()
        }
        tabBarView.onSearchQueryChanged = { [weak self] query in
            self?.state.searchText = query
        }
    }

    private func select(tab: AppTab) {
        switch state.mode {
        case .tabs:
            guard state.mode.selectedTab != tab else { return }
            state.mode = .tabs(selected: tab)
            let transition = effectiveTransition(.spring(duration: 0.4))
            showChild(for: tab, transition: transition)
            reconcileLayout(transition: transition)
        case .searchEntering, .searchActive, .searchExiting:
            cancelSearch(to: tab)
        }
    }

    private func activateSearch() {
        guard case let .tabs(selected) = state.mode else { return }

        state.tabBeforeSearch = selected
        state.searchText = ""
        tabBarView.setSearchQuery("")
        state.mode = .searchEntering(previous: selected)

        let transition = effectiveTransition(.spring(duration: 0.5))
        presentSearchOverlay()
        reconcileLayout(transition: transition)
        tabBarView.becomeSearchFirstResponder()

        state.mode = .searchActive(previous: selected)
    }

    private func cancelSearch(to targetTab: AppTab? = nil) {
        let target = targetTab ?? state.mode.previousTab ?? state.tabBeforeSearch
        guard target != .search else { return }
        guard state.mode.isSearchVisible else {
            state.mode = .tabs(selected: target)
            showChild(for: target, transition: .immediate)
            reconcileLayout(transition: .immediate, force: true)
            return
        }

        state.searchText = ""
        tabBarView.setSearchQuery("")
        tabBarView.resignSearchFirstResponder()
        searchExitLayoutCompleted = false
        searchOverlayExitCompleted = false
        state.mode = .searchExiting(previous: target)

        let transition = effectiveTransition(.spring(duration: 0.5))
        // Reveal the destination under the Search overlay. The overlay still
        // covers it, so this does not produce a visible page snap.
        showChild(for: target, transition: .immediate)
        dismissSearchOverlay { [weak self] in
            guard let self else { return }
            self.searchOverlayExitCompleted = true
            self.finishSearchDeactivationIfReady(target: target)
        }
        reconcileLayout(transition: transition) { [weak self] completed in
            guard let self, completed else { return }
            self.searchExitLayoutCompleted = true
            self.finishSearchDeactivationIfReady(target: target)
        }
    }

    private func finishSearchDeactivationIfReady(target: AppTab) {
        guard case let .searchExiting(previous) = state.mode,
              previous == target,
              searchExitLayoutCompleted,
              searchOverlayExitCompleted,
              currentLayoutState.keyboardFrame == nil else {
            return
        }
        state.mode = .tabs(selected: target)
        reconcileLayout(transition: .immediate, force: true)
    }

    private func showChild(for tab: AppTab, transition: NagiTabTransition) {
        guard tab != .search else { return }

        _ = transition
        view.backgroundColor = pageBackgroundColor(for: tab)
        for (childTab, controller) in hostingControllers {
            guard childTab != .search else { continue }

            let isVisible = childTab == tab
            controller.view.alpha = 1
            controller.view.isHidden = !isVisible
            controller.view.isUserInteractionEnabled = isVisible
        }
    }

    private func presentSearchOverlay() {
        guard let searchController = hostingControllers[.search] else {
            return
        }

        searchOverlayView.layer.removeAllAnimations()
        searchController.view.layer.removeAllAnimations()

        searchOverlayView.isHidden = false
        searchOverlayView.isUserInteractionEnabled = true
        // The overlay itself stays transparent and fully active. Nagram's
        // Bottom Contacts Search does not perform an opaque background fade.
        searchOverlayView.alpha = 1
        searchController.view.alpha = 0

        if reduceMotion {
            searchController.view.alpha = 1
            return
        }

        // Match SearchDisplayController content activation: 0 -> 1, 0.3s.
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
    private func handleSearchOverlayDismissTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else {
            return
        }

        guard state.mode.isSearchVisible else {
            return
        }

        // A background tap cancels only while the search query is empty.
        // Once results are visible, taps belong to the result content.
        guard state.searchText.isEmpty else {
            return
        }

        cancelSearch()
    }

    private func dismissSearchOverlay(completion: @escaping () -> Void) {
        searchOverlayView.isUserInteractionEnabled = false

        guard !reduceMotion else {
            searchOverlayView.alpha = 1
            searchOverlayView.isHidden = true
            completion()
            return
        }

        searchOverlayView.layer.removeAllAnimations()

        // Fade the complete overlay so its background and content leave
        // together, matching Nagram SearchDisplayController.
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
                guard let self, finished else { return }

                self.searchOverlayView.isHidden = true
                self.searchOverlayView.alpha = 1

                if let searchController = self.hostingControllers[.search] {
                    searchController.view.alpha = 1
                }

                completion()
            }
        )
    }

    private func applyKeyboardFrame(_ frame: CGRect?, transition: NagiTabTransition) {
        currentLayoutState.keyboardFrame = frame
        guard state.mode.isSearchInteractionActive else {
            reconcileLayout(transition: .immediate)
            return
        }
        keyboardTransitionGeneration += 1
        let generation = keyboardTransitionGeneration
        let resolvedTransition = effectiveTransition(transition)
        activeLayoutTransition = resolvedTransition
        reconcileLayout(transition: resolvedTransition) { [weak self] _ in
            guard let self, generation == self.keyboardTransitionGeneration else { return }
            self.activeLayoutTransition = nil
        }
        if frame == nil, case let .searchExiting(previous) = state.mode {
            finishSearchDeactivationIfReady(target: previous)
        }
    }

    private func reconcileLayout(
        transition: NagiTabTransition,
        force: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        let nextState = NagiRootLayoutState(
            bounds: view.bounds,
            safeAreaInsets: view.safeAreaInsets,
            keyboardFrame: currentLayoutState.keyboardFrame,
            mode: state.mode
        )
        guard force || nextState != currentLayoutState || tabBarView.frame == .zero else {
            completion?(true)
            return
        }

        let layout = NagiTabBarMetrics.calculateLayout(
            bounds: nextState.bounds,
            safeAreaInsets: nextState.safeAreaInsets,
            keyboardFrame: nextState.keyboardFrame,
            state: nextState.mode
        )
        currentLayoutState = nextState
        let resolvedTransition = effectiveTransition(transition)
        var completedParts = 0
        var allPartsCompleted = true
        func completePart(_ completed: Bool) {
            completedParts += 1
            allPartsCompleted = allPartsCompleted && completed
            guard completedParts == 2 else { return }
            completion?(allPartsCompleted)
        }

        resolvedTransition.perform { [weak self] in
            guard let self else { return }
            resolvedTransition.setFrame(
                view: self.contentContainerView,
                frame: self.view.bounds
            )
            resolvedTransition.setFrame(
                view: self.searchOverlayView,
                frame: self.contentContainerView.bounds
            )
            resolvedTransition.setFrame(
                view: self.tabBarView,
                frame: layout.tabBarFrame
            )

            if let searchController = self.hostingControllers[.search] {
                resolvedTransition.setFrame(
                    view: searchController.view,
                    frame: self.searchOverlayView.bounds
                )
            }

            for (tab, controller) in self.hostingControllers {
                guard tab != .search else { continue }

                resolvedTransition.setFrame(
                    view: controller.view,
                    frame: self.contentContainerView.bounds
                )
            }
        } completion: { completed in
            completePart(completed)
        }

        tabBarView.update(
            layout: layout,
            mode: nextState.mode,
            reduceTransparency: reduceTransparency,
            transition: resolvedTransition,
            completion: { completed in
                completePart(completed)
            }
        )
    }

    private func effectiveTransition(_ transition: NagiTabTransition) -> NagiTabTransition {
        reduceMotion ? .immediate : transition
    }
}

private struct NagiSearchHostView: View {
    @ObservedObject var state: NagiRootState

    var body: some View {
        SearchView(searchText: $state.searchText)
    }
}
