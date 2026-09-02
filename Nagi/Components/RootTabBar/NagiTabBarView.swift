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
    var selectedTab: AppTab
    var searchState: NagiTabBarSearchState
    var reduceTransparency: Bool
    var selectionGestureIndex: Int?
    var overrideSelectedIndex: Int?
}

private struct NagiSelectionGestureState: Equatable {
    let originalIndex: Int
    var hoveredIndex: Int
    let startSelectionX: CGFloat
    var currentSelectionX: CGFloat
    let itemWidth: CGFloat
}

final class NagiTabBarView: UIView {
    private let glassContainer: NagiGlassContainerView
    private let itemViews: [NagiTabBarItemView]
    private let selectedItemViews: [NagiTabBarItemView]
    private let searchView: NagiNavigationSearchView
    private let liquidLensView: NagiLiquidLensView
    private let tabSelectionRecognizer: NagiTabSelectionRecognizer
    private var previousParams: NagiTabBarParams?
    private var currentLayout: NagiTabBarLayout?
    private var currentSelectedTab: AppTab = .home
    private var currentSearchState = NagiTabBarSearchState.inactive
    private var selectionGestureState: NagiSelectionGestureState?
    private var overrideSelectedIndex: Int?
    private let isLiftedStateEnabled = true
    private var lastTraitStyle: UIUserInterfaceStyle

    var onTabSelected: ((AppTab) -> Void)?
    var onSearchActivated: (() -> Void)?
    var onSearchCancelled: (() -> Void)?
    var onSearchQueryChanged: ((String) -> Void)?

    init() {
        self.glassContainer = NagiGlassContainerView(spacing: 7)
        let mainTabs: [AppTab] = [.home, .library, .settings]
        self.itemViews = mainTabs.map {
            NagiTabBarItemView(
                tab: $0,
                visualRole: .normal,
                isInteractive: false
            )
        }
        self.selectedItemViews = mainTabs.map {
            NagiTabBarItemView(tab: $0, visualRole: .selected, isInteractive: false)
        }
        self.searchView = NagiNavigationSearchView(frame: .zero)
        self.liquidLensView = NagiLiquidLensView(frame: .zero)
        self.tabSelectionRecognizer = NagiTabSelectionRecognizer(target: nil, action: nil)
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
        tabSelectionRecognizer.addTarget(self, action: #selector(handleTabSelectionGesture(_:)))
        tabSelectionRecognizer.shouldBeginAtLocation = { [weak self] location in
            self?.mainIndex(at: location, requiresMainFrameHit: true) != nil
        }
        liquidLensView.addGestureRecognizer(tabSelectionRecognizer)

        for itemView in itemViews {
            itemView.isUserInteractionEnabled = false
            liquidLensView.contentView.addSubview(itemView)
        }

        for selectedItemView in selectedItemViews {
            selectedItemView.isUserInteractionEnabled = false
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
                selectedTab: previousParams.selectedTab,
                searchState: previousParams.searchState,
                reduceTransparency: previousParams.reduceTransparency,
                transition: .immediate
            )
        }
    }

    func update(
        layout: NagiTabBarLayout,
        selectedTab: AppTab,
        searchState: NagiTabBarSearchState,
        reduceTransparency: Bool,
        transition: NagiTabTransition,
        completion: ((Bool) -> Void)? = nil
    ) {
        currentLayout = layout
        currentSelectedTab = selectedTab
        currentSearchState = searchState

        let nextParams = NagiTabBarParams(
            layout: layout,
            selectedTab: selectedTab,
            searchState: searchState,
            reduceTransparency: reduceTransparency,
            selectionGestureIndex: selectionGestureState?.hoveredIndex,
            overrideSelectedIndex: overrideSelectedIndex
        )
        guard nextParams != previousParams else {
            completion?(true)
            return
        }
        let oldParams = previousParams
        previousParams = nextParams

        let isDark = traitCollection.userInterfaceStyle == .dark
        glassContainer.update(
            size: layout.tabBarFrame.size,
            isDark: isDark,
            transition: transition
        )
        let localSearchContainerFrame = localFrame(layout.searchContainerFrame, in: layout.tabBarFrame)
        let searchContainerFrameChanged: Bool
        if let oldParams {
            let previousLocalSearchContainerFrame = localFrame(
                oldParams.layout.searchContainerFrame,
                in: oldParams.layout.tabBarFrame
            )
            searchContainerFrameChanged =
                previousLocalSearchContainerFrame != localSearchContainerFrame
        } else {
            searchContainerFrameChanged = true
        }
        let localItemFrames = layout.itemFrames.map { localFrame($0, in: layout.lensContainerFrame) }
        let selectedIndex = mainIndex(for: selectedTab)
        let displayedIndex = selectionGestureState?.hoveredIndex ?? overrideSelectedIndex ?? selectedIndex
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
            isActive: searchState.isActive,
            isExpandedStandaloneBar: false,
            isDark: isDark,
            reduceTransparency: reduceTransparency
        )

        let searchParamsChanged = searchView.prepare(params: searchParams)

        let itemBlurTransition: NagiTabTransition = transition.isImmediate
            ? .immediate
            : .easeInOut(duration: 0.25)
        transition.perform { [weak self] in
            guard let self else { return }
            if searchContainerFrameChanged {
                transition.setFrame(view: self.searchView, frame: localSearchContainerFrame)
            }
            if searchParamsChanged || oldParams == nil {
                self.searchView.applyInternalGeometry(
                    params: searchParams,
                    transition: transition
                )
            }
            self.liquidLensView.contentView.isUserInteractionEnabled = !layout.isSearchActive

            for ((itemView, selectedItemView), itemFrame) in zip(
                zip(self.itemViews, self.selectedItemViews),
                localItemFrames
            ) {
                transition.setFrame(view: itemView, frame: itemFrame)
                transition.setFrame(view: selectedItemView, frame: itemFrame)
            }
            self.updateItemSelectionPresentation(
                displayedIndex: displayedIndex,
                transition: transition,
                blurTransition: itemBlurTransition,
                scaleTransition: transition,
                isSearchActive: layout.isSearchActive
            )
        } completion: { completed in
            completion?(completed)
        }

        liquidLensView.apply(
            params: makeLensParams(
                layout: layout,
                displayedIndex: displayedIndex,
                isLifted: selectionGestureState != nil && isLiftedStateEnabled,
                isDark: isDark,
                reduceTransparency: reduceTransparency
            ),
            transition: transition
        )

        // The Root commits a tab selection synchronously from the touch-end
        // callback. Once that state has reached this view, the override has
        // served its purpose and the real Root selection becomes authoritative.
        if selectionGestureState == nil, overrideSelectedIndex == selectedIndex {
            overrideSelectedIndex = nil
        }
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

    @objc private func handleTabSelectionGesture(_ recognizer: NagiTabSelectionRecognizer) {
        switch recognizer.state {
        case .began:
            beginTabSelection(at: recognizer.initialLocation)
        case .changed:
            updateTabSelection(using: recognizer)
        case .ended:
            finishTabSelection()
        case .cancelled:
            cancelTabSelection()
        case .failed:
            if selectionGestureState != nil {
                cancelTabSelection()
            }
        default:
            break
        }
    }

    private func beginTabSelection(at location: CGPoint) {
        guard selectionGestureState == nil,
              let currentLayout,
              !currentLayout.isSearchActive,
              let hoveredIndex = mainIndex(at: location, requiresMainFrameHit: true),
              let originalIndex = mainIndex(for: currentSelectedTab) else {
            return
        }

        let localItemFrames = currentLayout.itemFrames.map {
            localFrame($0, in: currentLayout.lensContainerFrame)
        }
        guard localItemFrames.indices.contains(hoveredIndex) else {
            return
        }

        let touchedItemFrame = localItemFrames[hoveredIndex]
        let startSelectionX = touchedItemFrame.minX - NagiTabBarMetrics.innerInset
        let itemWidth = touchedItemFrame.width
        guard itemWidth > 0 else { return }

        selectionGestureState = NagiSelectionGestureState(
            originalIndex: originalIndex,
            hoveredIndex: hoveredIndex,
            startSelectionX: startSelectionX,
            currentSelectionX: startSelectionX,
            itemWidth: itemWidth
        )
        renderCurrentLayout(transition: .spring(duration: 0.4))
    }

    private func updateTabSelection(using recognizer: NagiTabSelectionRecognizer) {
        guard var gestureState = selectionGestureState else {
            return
        }

        let translation = recognizer.translation(in: liquidLensView)
        let currentSelectionX = gestureState.startSelectionX + translation.x
        let hoveredIndex = mainIndex(
            at: recognizer.currentTouchLocation,
            requiresMainFrameHit: false
        ) ?? gestureState.hoveredIndex

        gestureState.currentSelectionX = currentSelectionX
        gestureState.hoveredIndex = hoveredIndex
        selectionGestureState = gestureState

        renderCurrentLayout(transition: .immediate)
    }

    private func finishTabSelection() {
        guard let gestureState = selectionGestureState,
              let actualIndex = mainIndex(for: currentSelectedTab) else {
            cancelTabSelection()
            return
        }

        let finalIndex = max(0, min(NagiTabBarMetrics.mainItemCount - 1, gestureState.hoveredIndex))
        let finalTab = tab(forMainIndex: finalIndex)
        let actualTab = tab(forMainIndex: actualIndex)
        selectionGestureState = nil

        if finalTab != actualTab {
            // Keep the lens's final visual selection ahead of the Root's mode
            // update. Root.select(tab:) immediately reconciles one continuous
            // spring using this override, instead of waiting for a second
            // completion callback from the lens.
            overrideSelectedIndex = finalIndex
            self.onTabSelected?(finalTab)
            return
        }

        overrideSelectedIndex = nil
        renderCurrentLayout(transition: .spring(duration: 0.4))
    }

    private func cancelTabSelection() {
        guard currentLayout != nil,
              mainIndex(for: currentSelectedTab) != nil else {
            selectionGestureState = nil
            overrideSelectedIndex = nil
            return
        }

        selectionGestureState = nil
        overrideSelectedIndex = nil
        renderCurrentLayout(transition: .spring(duration: 0.4))
    }

    private func renderCurrentLayout(transition: NagiTabTransition) {
        guard let currentLayout else { return }
        update(
            layout: currentLayout,
            selectedTab: currentSelectedTab,
            searchState: currentSearchState,
            reduceTransparency: previousParams?.reduceTransparency ?? false,
            transition: transition
        )
    }

    private func updateItemSelectionPresentation(
        displayedIndex: Int?,
        transition: NagiTabTransition = .immediate,
        blurTransition: NagiTabTransition? = nil,
        scaleTransition: NagiTabTransition? = nil,
        isSearchActive: Bool = false
    ) {
        let resolvedBlurTransition = blurTransition ?? transition
        let resolvedScaleTransition = scaleTransition ?? transition
        let selectedContentScale: CGFloat = selectionGestureState != nil && isLiftedStateEnabled
            ? 1.15
            : 1.0

        for (itemView, selectedItemView) in zip(itemViews, selectedItemViews) {
            let isSelected = displayedIndex == mainIndex(for: itemView.tab)
            itemView.update(
                isSelected: isSelected,
                usesPrivateLens: liquidLensView.usesPrivateLens,
                isCompact: isSearchActive
            )
            selectedItemView.update(
                isSelected: isSelected,
                usesPrivateLens: liquidLensView.usesPrivateLens,
                isCompact: isSearchActive
            )

            let isVisible = !isSearchActive || isSelected
            transition.setAlpha(view: itemView, alpha: isVisible ? 1 : 0)
            transition.setAlpha(view: selectedItemView, alpha: isVisible ? 1 : 0)
            resolvedBlurTransition.setBlur(layer: itemView.layer, radius: isVisible ? 0 : 10)
            resolvedBlurTransition.setBlur(layer: selectedItemView.layer, radius: isVisible ? 0 : 10)
            resolvedScaleTransition.setScale(
                view: selectedItemView,
                scale: selectedContentScale
            )
        }
    }

    private func makeLensSelectionGeometry(
        layout: NagiTabBarLayout,
        displayedIndex: Int?
    ) -> (origin: CGPoint, size: CGSize) {
        let localLensContainerFrame = localFrame(
            layout.lensContainerFrame,
            in: layout.tabBarFrame
        )
        let containerSize = localLensContainerFrame.size
        let inset = NagiTabBarMetrics.innerInset

        if layout.isLensCollapsed {
            return (
                origin: .zero,
                size: CGSize(
                    width: min(
                        NagiTabBarMetrics.collapsedLensDiameter,
                        containerSize.width
                    ),
                    height: containerSize.height
                )
            )
        }

        if let gestureState = selectionGestureState {
            let selectionWidth = gestureState.itemWidth + inset * 2.0
            let maxX = max(0, containerSize.width - selectionWidth)
            let x = min(
                max(0, gestureState.currentSelectionX),
                maxX
            )
            return (
                origin: CGPoint(x: x, y: 0),
                size: CGSize(
                    width: selectionWidth,
                    height: containerSize.height
                )
            )
        }

        if let displayedIndex,
           layout.itemFrames.indices.contains(displayedIndex) {
            let itemFrame = localFrame(
                layout.itemFrames[displayedIndex],
                in: layout.lensContainerFrame
            )
            let selectionWidth = itemFrame.width + inset * 2.0
            let maxX = max(0, containerSize.width - selectionWidth)
            let x = min(
                max(0, itemFrame.minX - inset),
                maxX
            )
            return (
                origin: CGPoint(x: x, y: 0),
                size: CGSize(
                    width: selectionWidth,
                    height: containerSize.height
                )
            )
        }

        return (
            origin: .zero,
            size: CGSize(
                width: min(56, containerSize.width),
                height: containerSize.height
            )
        )
    }

    private func makeLensParams(
        layout: NagiTabBarLayout,
        displayedIndex: Int?,
        isLifted: Bool,
        isDark: Bool,
        reduceTransparency: Bool
    ) -> NagiLensParams {
        let localLensContainerFrame = localFrame(
            layout.lensContainerFrame,
            in: layout.tabBarFrame
        )
        let selection = makeLensSelectionGeometry(
            layout: layout,
            displayedIndex: displayedIndex
        )
        return NagiLensParams(
            size: localLensContainerFrame.size,
            containerOrigin: localLensContainerFrame.origin,
            selectionOrigin: selection.origin,
            selectionSize: selection.size,
            isDark: isDark,
            inset: NagiTabBarMetrics.innerInset,
            liftedInset: NagiTabBarMetrics.innerInset,
            isLifted: isLifted,
            isCollapsed: layout.isLensCollapsed,
            reduceTransparency: reduceTransparency
        )
    }

    private func mainIndex(at location: CGPoint, requiresMainFrameHit: Bool) -> Int? {
        guard let currentLayout, !currentLayout.isSearchActive else { return nil }
        let mainFrame = localFrame(currentLayout.mainTabsFrame, in: currentLayout.tabBarFrame)
        if requiresMainFrameHit && !mainFrame.contains(location) {
            return nil
        }

        let itemFrames = currentLayout.itemFrames.map {
            localFrame($0, in: currentLayout.tabBarFrame)
        }
        guard !itemFrames.isEmpty else { return nil }
        if let index = itemFrames.firstIndex(where: { $0.contains(location) }) {
            return index
        }
        return itemFrames.indices.min {
            abs(itemFrames[$0].midX - location.x) < abs(itemFrames[$1].midX - location.x)
        }
    }

    private func tab(forMainIndex index: Int) -> AppTab {
        switch index {
        case 0: return .home
        case 1: return .library
        default: return .settings
        }
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
        }
    }
}
