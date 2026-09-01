//
//  NagiTabBarView.swift
//  Nagi
//
//  RootTabBar 的持久化 UIKit 实现。Root 只提供整体 frame；本 view
//  负责 Main/Search/Lens 的一次性状态提交，所有 surface 都复用。
//

import UIKit

struct NagiTabBarParams: Equatable {
    var layout: NagiTabBarLayout
    var mode: NagiRootTabMode
    var reduceTransparency: Bool
    var selectionGestureIndex: Int?
}

private enum NagiSelectionGestureState: Equatable {
    case pressing(index: Int)

    var index: Int {
        switch self {
        case let .pressing(index):
            return index
        }
    }
}

final class NagiTabBarView: UIView {
    private let glassContainer: NagiGlassContainerView
    private let itemViews: [NagiTabBarItemView]
    private let selectedItemViews: [NagiTabBarItemView]
    private let searchView: NagiNavigationSearchView
    private let liquidLensView: NagiLiquidLensView
    private var previousParams: NagiTabBarParams?
    private var currentLayout: NagiTabBarLayout?
    private var currentMode: NagiRootTabMode?
    private var selectionGestureState: NagiSelectionGestureState?
    private let isLiftedStateEnabled = true
    private var searchTransitionGeneration = 0
    private var lastTraitStyle: UIUserInterfaceStyle

    var onTabSelected: ((AppTab) -> Void)?
    var onSearchActivated: (() -> Void)?
    var onSearchCancelled: (() -> Void)?
    var onSearchQueryChanged: ((String) -> Void)?

    init() {
        self.glassContainer = NagiGlassContainerView(spacing: 7)
        let mainTabs: [AppTab] = [.home, .library, .settings]
        self.itemViews = mainTabs.map { NagiTabBarItemView(tab: $0) }
        self.selectedItemViews = mainTabs.map { NagiTabBarItemView(tab: $0, isInteractive: false) }
        self.searchView = NagiNavigationSearchView(frame: .zero)
        self.liquidLensView = NagiLiquidLensView(frame: .zero)
        self.lastTraitStyle = .unspecified
        super.init(frame: .zero)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: NagiTabBarView, previousTraitCollection) in
            view.handleTraitCollectionChange(previousTraitCollection)
        }

        clipsToBounds = false
        isUserInteractionEnabled = true

        addSubview(glassContainer)
        glassContainer.contentView.addSubview(liquidLensView)
        glassContainer.contentView.addSubview(searchView)

        for (index, itemView) in itemViews.enumerated() {
            liquidLensView.contentView.addSubview(itemView)
            itemView.onActivate = { [weak self] in
                let tabs: [AppTab] = [.home, .library, .settings]
                guard index < tabs.count else { return }
                self?.onTabSelected?(tabs[index])
            }
            itemView.onPressChanged = { [weak self] isPressed in
                self?.updateSelectionGesture(isPressed: isPressed, index: index)
            }
        }

        for selectedItemView in selectedItemViews {
            liquidLensView.selectedContentView.addSubview(selectedItemView)
        }

        searchView.onActivate = { [weak self] in
            self?.onSearchActivated?()
        }
        searchView.onCancel = { [weak self] in
            self?.onSearchCancelled?()
        }
        searchView.onQueryChanged = { [weak self] query in
            self?.onSearchQueryChanged?(query)
        }

        liquidLensView.configure(
            liftedContainerView: liquidLensView.dedicatedMainGlassContainer,
            liftedContentView: liquidLensView.selectedContentView,
            punchoutView: liquidLensView.contentView
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // These two hosts always fill RootTabBar. Main/Search/item geometry is
        // intentionally written only by update(... transition:).
        glassContainer.frame = bounds
        liquidLensView.frame = bounds
    }

    private func handleTraitCollectionChange(_ previousTraitCollection: UITraitCollection) {
        let style = traitCollection.userInterfaceStyle
        guard style != lastTraitStyle else { return }
        lastTraitStyle = style
        if let previousParams {
            self.previousParams = nil
            update(
                layout: previousParams.layout,
                mode: previousParams.mode,
                reduceTransparency: previousParams.reduceTransparency,
                transition: .immediate
            )
        }
    }

    func update(
        layout: NagiTabBarLayout,
        mode: NagiRootTabMode,
        reduceTransparency: Bool,
        transition: NagiTabTransition
    ) {
        currentLayout = layout
        currentMode = mode

        let nextParams = NagiTabBarParams(
            layout: layout,
            mode: mode,
            reduceTransparency: reduceTransparency,
            selectionGestureIndex: selectionGestureState?.index
        )
        guard nextParams != previousParams else {
            return
        }
        let oldParams = previousParams
        previousParams = nextParams

        let isDark = traitCollection.userInterfaceStyle == .dark
        let localLensContainerFrame = localFrame(layout.lensContainerFrame, in: layout.tabBarFrame)
        let localSearchContainerFrame = localFrame(layout.searchContainerFrame, in: layout.tabBarFrame)
        let localItemFrames = layout.itemFrames.map { localFrame($0, in: layout.lensContainerFrame) }
        let selectedIndex = mainIndex(for: mode.previousTab ?? mode.selectedTab)
        let displayedIndex = selectionGestureState?.index ?? selectedIndex
        let lensSelectionFrame = displayedIndex.flatMap { index in
            guard layout.itemFrames.indices.contains(index) else { return nil }
            return layout.itemFrames[index]
        } ?? layout.lensSelectionFrame
        let localSelectionFrame = localFrame(
            lensSelectionFrame,
            in: layout.lensContainerFrame
        )
        let searchParams = NagiSearchParams(
            containerSize: localSearchContainerFrame.size,
            backgroundFrame: localFrame(
                layout.searchBackgroundFrame,
                in: layout.searchContainerFrame
            ),
            closeFrame: localFrame(
                layout.searchCloseFrame,
                in: layout.searchContainerFrame
            ),
            isActive: layout.isSearchActive,
            isExpandedStandaloneBar: mode.searchPresentation.isExpandedStandaloneBar,
            isDark: isDark,
            reduceTransparency: reduceTransparency
        )

        searchView.prepare(params: searchParams)
        searchTransitionGeneration += 1
        let generation = searchTransitionGeneration
        let shouldClipSearchContent = !transition.isImmediate && searchGeometryChanged(
            from: oldParams?.layout,
            to: layout
        )
        searchView.setContentClipping(shouldClipSearchContent)

        transition.animate { [weak self] in
            guard let self else { return }
            NagiTabTransition.setFrame(self.searchView, localSearchContainerFrame)
            self.searchView.applyInternalGeometry(params: searchParams)
            self.liquidLensView.contentView.isUserInteractionEnabled = !layout.isSearchActive

            for ((itemView, selectedItemView), itemFrame) in zip(
                zip(self.itemViews, self.selectedItemViews),
                localItemFrames
            ) {
                itemView.frame = itemFrame
                let isSelected = displayedIndex == self.mainIndex(for: itemView.tab)
                itemView.update(
                    isSelected: isSelected,
                    showsSelectedAppearance: !self.liquidLensView.usesPrivateLens && isSelected
                )
                selectedItemView.frame = itemFrame
                selectedItemView.update(isSelected: isSelected)
                selectedItemView.alpha = isSelected ? 1 : 0
            }
        } completion: { [weak self] _ in
            guard let self, generation == self.searchTransitionGeneration else { return }
            self.searchView.setContentClipping(false)
        }

        liquidLensView.apply(
            params: NagiLensParams(
                size: localLensContainerFrame.size,
                containerOrigin: localLensContainerFrame.origin,
                selectionOrigin: localSelectionFrame.origin,
                selectionSize: localSelectionFrame.size,
                isDark: isDark,
                inset: NagiTabBarMetrics.innerInset,
                liftedInset: NagiTabBarMetrics.innerInset,
                isLifted: selectionGestureState != nil && isLiftedStateEnabled,
                isCollapsed: layout.isLensCollapsed,
                reduceTransparency: reduceTransparency
            ),
            transition: transition
        )
    }

    func setSearchQuery(_ query: String) {
        searchView.setQuery(query)
    }

    func resignSearchFirstResponder() {
        searchView.resignSearchFirstResponder()
    }

    @discardableResult
    func becomeSearchFirstResponder() -> Bool {
        searchView.becomeSearchFirstResponder()
    }

    private func searchGeometryChanged(
        from oldLayout: NagiTabBarLayout?,
        to newLayout: NagiTabBarLayout
    ) -> Bool {
        guard let oldLayout else { return true }
        return oldLayout.isSearchActive != newLayout.isSearchActive ||
            oldLayout.searchContainerFrame != newLayout.searchContainerFrame ||
            oldLayout.searchBackgroundFrame != newLayout.searchBackgroundFrame ||
            oldLayout.searchCloseFrame != newLayout.searchCloseFrame
    }

    private func updateSelectionGesture(isPressed: Bool, index: Int) {
        let nextState: NagiSelectionGestureState? = isPressed ? .pressing(index: index) : nil
        guard nextState != selectionGestureState else { return }
        selectionGestureState = nextState

        guard let currentLayout, let currentMode else { return }
        let transition: NagiTabTransition = isPressed
            ? .spring(duration: 0.2, damping: 0.86, velocity: 0.1)
            : .spring(duration: 0.22, damping: 0.88, velocity: 0.1)
        update(
            layout: currentLayout,
            mode: currentMode,
            reduceTransparency: previousParams?.reduceTransparency ?? false,
            transition: transition
        )
    }

    private func localFrame(_ frame: CGRect, in parentFrame: CGRect) -> CGRect {
        guard !frame.isEmpty else { return .zero }
        return frame.offsetBy(dx: -parentFrame.minX, dy: -parentFrame.minY)
    }

    private func mainIndex(for tab: AppTab) -> Int? {
        switch tab {
        case .home: return 0
        case .library: return 1
        case .settings: return 2
        case .search: return nil
        }
    }
}
