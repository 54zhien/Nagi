//
//  RootContainerViewController.swift
//  Nagi
//
//  Persistent UIKit root for Home, Library, Settings, and Search.
//

import SwiftUI
import SwiftData
import UIKit

@MainActor
final class RootContainerViewController: UIViewController {
    private let contentContainerView = UIView()
    private let bottomBar = NagiBottomBarView()
    private let rootState = RootTabState()
    private let searchState = SearchState()

    private var hostingControllers: [AppTab: UIHostingController<AnyView>] = [:]
    private var keyboardTransitionCoordinator: KeyboardTransitionCoordinator?
    private var keyboardFrameInScreen: CGRect?
    private var reduceMotion: Bool
    private var reduceTransparency: Bool

    init(reduceMotion: Bool, reduceTransparency: Bool) {
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        view.isOpaque = true

        contentContainerView.backgroundColor = .clear
        contentContainerView.isOpaque = false
        view.addSubview(contentContainerView)

        bottomBar.onSelectTab = { [weak self] tab in
            self?.select(tab: tab)
        }
        bottomBar.onSearchActivate = { [weak self] in
            self?.activateSearch()
        }
        bottomBar.onSearchCancel = { [weak self] in
            self?.cancelSearch()
        }
        bottomBar.searchContainer.onQueryChanged = { [weak self] query in
            // SearchState is the only data path here. This callback never
            // invalidates or relays bottom-bar geometry.
            self?.searchState.query = query
        }
        bottomBar.searchContainer.onEditingDidEnd = { [weak self] in
            self?.searchEditingDidEnd()
        }
        view.addSubview(bottomBar)

        _ = makeHostingController(for: .home)
        showContent(for: .home)
        keyboardTransitionCoordinator = KeyboardTransitionCoordinator(owner: self)
        updateBottomBarConfiguration()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutRoot(animated: false)
    }

    func updateAccessibility(reduceMotion: Bool, reduceTransparency: Bool) {
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        updateBottomBarConfiguration()
        view.setNeedsLayout()
    }

    func applyKeyboardFrame(
        _ screenFrame: CGRect,
        duration: TimeInterval,
        options: UIView.AnimationOptions
    ) {
        guard isViewLoaded else { return }
        keyboardFrameInScreen = screenFrame.isNull ? nil : screenFrame

        let animations = { [weak self] in
            self?.layoutRoot(animated: false, suppressAnimation: false)
            self?.view.layoutIfNeeded()
        }

        if reduceMotion || duration <= 0 {
            UIView.performWithoutAnimation(animations)
        } else {
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: options,
                animations: animations
            )
        }
    }

    func dismantle() {
        keyboardTransitionCoordinator = nil
        bottomBar.onSelectTab = nil
        bottomBar.onSearchActivate = nil
        bottomBar.onSearchCancel = nil
        bottomBar.searchContainer.onQueryChanged = nil
        bottomBar.searchContainer.onEditingDidEnd = nil

        for controller in hostingControllers.values {
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        hostingControllers.removeAll()
    }

    private func makeHostingController(for tab: AppTab) -> UIHostingController<AnyView> {
        if let existing = hostingControllers[tab] {
            return existing
        }

        let rootView: AnyView
        switch tab {
        case .home:
            rootView = AnyView(HomeView().modelContainer(Persistence.container))
        case .library:
            rootView = AnyView(LibraryView().modelContainer(Persistence.container))
        case .settings:
            rootView = AnyView(SettingsView().modelContainer(Persistence.container))
        case .search:
            rootView = AnyView(
                SearchView(state: searchState)
                    .modelContainer(Persistence.container)
            )
        }

        let controller = UIHostingController(rootView: rootView)
        controller.view.backgroundColor = .clear
        controller.view.isOpaque = false
        addChild(controller)
        contentContainerView.addSubview(controller.view)
        controller.didMove(toParent: self)
        hostingControllers[tab] = controller
        return controller
    }

    private func select(tab: AppTab) {
        guard tab != .search else {
            activateSearch()
            return
        }

        if rootState.mode != .tabs {
            searchState.isPresented = false
            bottomBar.searchContainer.resignFirstResponder()
        }
        rootState.selectedTab = tab
        rootState.mode = .tabs
        showContent(for: tab)
        updateBottomBarConfiguration()
        layoutRoot(animated: !reduceMotion)
    }

    private func activateSearch() {
        if rootState.mode == .tabs {
            rootState.tabBeforeSearch = rootState.selectedTab
            rootState.selectedTab = .search
            showContent(for: .search)
        }

        rootState.selectedTab = .search
        rootState.mode = .searchActive
        searchState.isPresented = true
        updateBottomBarConfiguration()
        layoutRoot(animated: !reduceMotion)

        // The field already exists and is now in its expanded frame. No
        // delayed focus or hierarchy rebuild is needed for keyboard handoff.
        bottomBar.searchContainer.becomeFirstResponder()
    }

    private func cancelSearch() {
        searchState.query = ""
        searchState.isPresented = false
        bottomBar.searchContainer.setQuery("")
        bottomBar.searchContainer.resignFirstResponder()

        let tab = rootState.tabBeforeSearch
        rootState.selectedTab = tab
        rootState.mode = .tabs
        showContent(for: tab)
        updateBottomBarConfiguration()
        layoutRoot(animated: !reduceMotion)
    }

    private func searchEditingDidEnd() {
        guard searchState.isPresented,
              rootState.mode == .searchActive else { return }
        rootState.mode = .searchInactive
        updateBottomBarConfiguration()
        layoutRoot(animated: !reduceMotion)
    }

    private func showContent(for tab: AppTab) {
        _ = makeHostingController(for: tab)
        for (candidate, controller) in hostingControllers {
            controller.view.isHidden = candidate != tab
        }
    }

    private func updateBottomBarConfiguration() {
        bottomBar.configure(
            selectedTab: rootState.selectedTab,
            mode: rootState.mode,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency
        )
    }

    private func layoutRoot(animated: Bool, suppressAnimation: Bool = true) {
        guard isViewLoaded else { return }

        let bounds = view.bounds
        let systemSafeAreaInsets = view.window?.safeAreaInsets ?? view.safeAreaInsets
        let keyboardFrameInView = keyboardFrameInScreen.map {
            view.convert($0, from: nil)
        }
        let barFrame = NagiBottomBarLayout.barFrame(
            bounds: bounds,
            safeAreaInsets: systemSafeAreaInsets,
            keyboardFrame: keyboardFrameInView
        )
        let additionalBottom = NagiBottomBarLayout.additionalBottomSafeArea(
            barFrame: barFrame,
            systemSafeAreaInsets: systemSafeAreaInsets,
            bounds: bounds
        )

        let changes = { [weak self] in
            guard let self else { return }
            contentContainerView.frame = bounds
            for controller in hostingControllers.values {
                controller.view.frame = contentContainerView.bounds
                controller.additionalSafeAreaInsets = UIEdgeInsets(
                    top: 0,
                    left: 0,
                    bottom: additionalBottom,
                    right: 0
                )
            }
            bottomBar.frame = barFrame
            bottomBar.layoutContents(for: rootState.mode)
        }

        if animated && !reduceMotion {
            UIView.animate(
                withDuration: 0.24,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
                animations: changes
            )
        } else if suppressAnimation {
            UIView.performWithoutAnimation(changes)
        } else {
            changes()
        }
    }
}
