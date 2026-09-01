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

    let state = NagiRootState()
    private var hostingControllers: [AppTab: UIHostingController<AnyView>] = [:]
    private var keyboardCoordinator: NagiKeyboardLayoutCoordinator?
    private var currentLayoutState = NagiRootLayoutState.initial
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

        view.backgroundColor = .systemBackground
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
        reconcileLayout(transition: .immediate)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        reconcileLayout(transition: .immediate)
    }

    func updateAccessibility(reduceMotion: Bool, reduceTransparency: Bool) {
        let changed = self.reduceMotion != reduceMotion || self.reduceTransparency != reduceTransparency
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        guard changed else { return }
        reconcileLayout(transition: .immediate)
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
            controller.view.backgroundColor = .clear
            controller.view.frame = contentContainerView.bounds
            contentContainerView.addSubview(controller.view)
            controller.didMove(toParent: self)
            controller.view.alpha = tab == .home ? 1 : 0
            controller.view.isHidden = tab != .home
            controller.view.isUserInteractionEnabled = tab == .home
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
            let transition = effectiveTransition(.spring(duration: 0.28, damping: 0.86, velocity: 0.2))
            showChild(for: tab, transition: transition)
            reconcileLayout(transition: transition)
        case .searchActivating, .searchActive, .searchDeactivating:
            cancelSearch(to: tab)
        }
    }

    private func activateSearch() {
        guard case let .tabs(selected) = state.mode else { return }

        state.tabBeforeSearch = selected
        state.searchText = ""
        tabBarView.setSearchQuery("")
        state.mode = .searchActivating

        let transition = effectiveTransition(.easeInOut(duration: 0.26))
        showChild(for: .search, transition: transition)
        reconcileLayout(transition: transition)
        tabBarView.becomeSearchFirstResponder()

        state.mode = .searchActive
        reconcileLayout(transition: .immediate)
    }

    private func cancelSearch(to targetTab: AppTab? = nil) {
        let target = targetTab ?? state.tabBeforeSearch
        guard target != .search else { return }
        guard state.mode.isSearchVisible || state.mode.isSearchExpanded else {
            state.mode = .tabs(selected: target)
            showChild(for: target, transition: .immediate)
            reconcileLayout(transition: .immediate)
            return
        }

        state.searchText = ""
        tabBarView.setSearchQuery("")
        tabBarView.resignSearchFirstResponder()
        state.mode = .searchDeactivating(previous: target)

        let transition = effectiveTransition(.easeInOut(duration: 0.24))
        showChild(for: target, transition: transition)
        reconcileLayout(transition: transition)

        if currentLayoutState.keyboardFrame == nil {
            transition.animate({}) { [weak self] _ in
                guard let self else { return }
                self.finishSearchDeactivation(target: target)
            }
        }
    }

    private func finishSearchDeactivation(target: AppTab) {
        guard case .searchDeactivating = state.mode else { return }
        state.mode = .tabs(selected: target)
        reconcileLayout(transition: .immediate)
    }

    private func showChild(for tab: AppTab, transition: NagiTabTransition) {
        let visibleTab = tab
        for (childTab, controller) in hostingControllers {
            let isVisible = childTab == visibleTab
            controller.view.isHidden = false
            controller.view.isUserInteractionEnabled = isVisible
        }
        transition.animate { [weak self] in
            guard let self else { return }
            for (childTab, controller) in self.hostingControllers {
                controller.view.alpha = childTab == visibleTab ? 1 : 0
            }
        } completion: { [weak self] completed in
            guard let self, completed else { return }
            for (childTab, controller) in self.hostingControllers where childTab != visibleTab {
                controller.view.isHidden = true
            }
        }
    }

    private func applyKeyboardFrame(_ frame: CGRect?, transition: NagiTabTransition) {
        currentLayoutState.keyboardFrame = frame
        guard state.mode.isSearchInteractionActive else {
            reconcileLayout(transition: .immediate)
            return
        }
        reconcileLayout(transition: effectiveTransition(transition))
        if frame == nil, case let .searchDeactivating(previous) = state.mode {
            finishSearchDeactivation(target: previous)
        }
    }

    private func reconcileLayout(transition: NagiTabTransition) {
        let nextState = NagiRootLayoutState(
            bounds: view.bounds,
            safeAreaInsets: view.safeAreaInsets,
            keyboardFrame: currentLayoutState.keyboardFrame,
            mode: state.mode
        )
        guard nextState != currentLayoutState || tabBarView.frame != .zero else {
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
        resolvedTransition.animate { [weak self] in
            guard let self else { return }
            NagiTabTransition.setFrame(self.contentContainerView, self.view.bounds)
            NagiTabTransition.setFrame(self.tabBarView, layout.tabBarFrame)
            for controller in self.hostingControllers.values {
                NagiTabTransition.setFrame(controller.view, self.contentContainerView.bounds)
                controller.additionalSafeAreaInsets = UIEdgeInsets(
                    top: 0,
                    left: 0,
                    bottom: layout.contentBottomInset,
                    right: 0
                )
            }
        }

        tabBarView.update(
            layout: layout,
            mode: nextState.mode,
            reduceTransparency: reduceTransparency,
            transition: resolvedTransition
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
