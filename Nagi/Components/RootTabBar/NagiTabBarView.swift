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

        for (index, itemView) in itemViews.enumerated() {
            liquidLensView.contentView.addSubview(itemView)
            itemView.onActivate = { [weak self] in
                let tabs: [AppTab] = [.home, .library, .settings]
                guard index < tabs.count else { return }
                guard self?.selectionGestureState == nil else { return }
                self?.onTabSelected?(tabs[index])
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
            selectionGestureIndex: selectionGestureState?.hoveredIndex
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
        let displayedIndex = selectionGestureState?.hoveredIndex ?? selectedIndex
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

        let searchParamsChanged = searchView.prepare(params: searchParams)
        searchTransitionGeneration += 1
        let generation = searchTransitionGeneration
        let searchGeometryDidChange = searchGeometryChanged(
            from: oldParams?.layout,
            to: layout
        )
        let shouldClipSearchContent = !transition.isImmediate && searchGeometryDidChange
        searchView.setContentClipping(shouldClipSearchContent)

        transition.animate { [weak self] in
            guard let self else { return }
            NagiTabTransition.setFrame(self.searchView, localSearchContainerFrame)
            if searchParamsChanged || searchGeometryDidChange || oldParams == nil {
                self.searchView.applyInternalGeometry(params: searchParams)
            }
            self.liquidLensView.contentView.isUserInteractionEnabled = !layout.isSearchActive

            for ((itemView, selectedItemView), itemFrame) in zip(
                zip(self.itemViews, self.selectedItemViews),
                localItemFrames
            ) {
                itemView.frame = itemFrame
                selectedItemView.frame = itemFrame
            }
            self.updateItemSelectionPresentation(displayedIndex: displayedIndex)
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
        let oldContainerFrame = localFrame(oldLayout.searchContainerFrame, in: oldLayout.tabBarFrame)
        let newContainerFrame = localFrame(newLayout.searchContainerFrame, in: newLayout.tabBarFrame)
        let oldBackgroundFrame = localFrame(
            oldLayout.searchBackgroundFrame,
            in: oldLayout.searchContainerFrame
        )
        let newBackgroundFrame = localFrame(
            newLayout.searchBackgroundFrame,
            in: newLayout.searchContainerFrame
        )
        let oldCloseFrame = localFrame(oldLayout.searchCloseFrame, in: oldLayout.searchContainerFrame)
        let newCloseFrame = localFrame(newLayout.searchCloseFrame, in: newLayout.searchContainerFrame)
        return oldLayout.isSearchActive != newLayout.isSearchActive ||
            oldContainerFrame != newContainerFrame ||
            oldBackgroundFrame != newBackgroundFrame ||
            oldCloseFrame != newCloseFrame
    }

    @objc private func handleTabSelectionGesture(_ recognizer: NagiTabSelectionRecognizer) {
        switch recognizer.state {
        case .began:
            beginTabSelection(at: recognizer.initialLocation)
        case .changed:
            updateTabSelection(using: recognizer)
        case .ended:
            updateTabSelection(using: recognizer)
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
              let currentMode,
              !currentLayout.isSearchActive,
              let hoveredIndex = mainIndex(at: location, requiresMainFrameHit: true),
              let originalIndex = mainIndex(for: currentMode.previousTab ?? currentMode.selectedTab),
              currentLayout.itemFrames.indices.contains(originalIndex) else {
            return
        }

        let localItemFrames = currentLayout.itemFrames.map {
            localFrame($0, in: currentLayout.lensContainerFrame)
        }
        let startSelectionX = localItemFrames[originalIndex].minX
        let itemWidth = localItemFrames[originalIndex].width
        guard itemWidth > 0 else { return }

        selectionGestureState = NagiSelectionGestureState(
            originalIndex: originalIndex,
            hoveredIndex: hoveredIndex,
            startSelectionX: startSelectionX,
            currentSelectionX: startSelectionX,
            itemWidth: itemWidth
        )
        liquidLensView.beginInteractiveSelection()
        liquidLensView.updateInteractiveSelection(
            originX: startSelectionX,
            hoveredIndex: hoveredIndex
        )
        updateItemSelectionPresentation(displayedIndex: hoveredIndex)
    }

    private func updateTabSelection(using recognizer: NagiTabSelectionRecognizer) {
        guard var gestureState = selectionGestureState,
              let currentLayout else {
            return
        }

        let localItemFrames = currentLayout.itemFrames.map {
            localFrame($0, in: currentLayout.lensContainerFrame)
        }
        guard let firstFrame = localItemFrames.first,
              let lastFrame = localItemFrames.last else {
            return
        }

        let translation = recognizer.translation(in: liquidLensView)
        let minSelectionX = firstFrame.minX
        let maxSelectionX = lastFrame.minX
        let currentSelectionX = min(
            max(minSelectionX, gestureState.startSelectionX + translation.x),
            maxSelectionX
        )
        let hoveredIndex = mainIndex(
            at: recognizer.currentTouchLocation,
            requiresMainFrameHit: false
        ) ?? gestureState.hoveredIndex

        gestureState.currentSelectionX = currentSelectionX
        gestureState.hoveredIndex = hoveredIndex
        selectionGestureState = gestureState

        liquidLensView.updateInteractiveSelection(
            originX: currentSelectionX,
            hoveredIndex: hoveredIndex
        )
        updateItemSelectionPresentation(displayedIndex: hoveredIndex)
    }

    private func finishTabSelection() {
        guard let gestureState = selectionGestureState,
              let currentLayout,
              let currentMode,
              let actualIndex = mainIndex(for: currentMode.previousTab ?? currentMode.selectedTab) else {
            cancelTabSelection()
            return
        }

        let finalIndex = max(0, min(NagiTabBarMetrics.mainItemCount - 1, gestureState.hoveredIndex))
        let finalTab = tab(forMainIndex: finalIndex)
        let actualTab = tab(forMainIndex: actualIndex)
        selectionGestureState = nil
        liquidLensView.endInteractiveSelection()
        updateItemSelectionPresentation(displayedIndex: finalIndex)

        let transition = NagiTabTransition.spring(
            duration: 0.22,
            damping: 0.88,
            velocity: 0.1
        )
        applyLensSelection(
            layout: currentLayout,
            displayedIndex: finalIndex,
            isLifted: false,
            transition: transition
        ) { [weak self] completed in
            guard let self, completed, finalTab != actualTab else { return }
            self.onTabSelected?(finalTab)
        }
    }

    private func cancelTabSelection() {
        guard let currentLayout,
              let currentMode,
              let actualIndex = mainIndex(for: currentMode.previousTab ?? currentMode.selectedTab) else {
            selectionGestureState = nil
            liquidLensView.endInteractiveSelection()
            return
        }

        selectionGestureState = nil
        liquidLensView.endInteractiveSelection()
        updateItemSelectionPresentation(displayedIndex: actualIndex)
        applyLensSelection(
            layout: currentLayout,
            displayedIndex: actualIndex,
            isLifted: false,
            transition: .spring(duration: 0.22, damping: 0.88, velocity: 0.1)
        )
    }

    private func updateItemSelectionPresentation(displayedIndex: Int?) {
        for (itemView, selectedItemView) in zip(itemViews, selectedItemViews) {
            let isSelected = displayedIndex == mainIndex(for: itemView.tab)
            itemView.update(
                isSelected: isSelected,
                showsSelectedAppearance: !liquidLensView.usesPrivateLens && isSelected
            )
            selectedItemView.update(isSelected: isSelected)
            selectedItemView.alpha = isSelected ? 1 : 0
        }
    }

    private func applyLensSelection(
        layout: NagiTabBarLayout,
        displayedIndex: Int?,
        isLifted: Bool,
        transition: NagiTabTransition,
        completion: ((Bool) -> Void)? = nil
    ) {
        let isDark = traitCollection.userInterfaceStyle == .dark
        liquidLensView.apply(
            params: makeLensParams(
                layout: layout,
                displayedIndex: displayedIndex,
                isLifted: isLifted,
                isDark: isDark,
                reduceTransparency: previousParams?.reduceTransparency ?? false
            ),
            transition: transition,
            completion: completion
        )
    }

    private func makeLensParams(
        layout: NagiTabBarLayout,
        displayedIndex: Int?,
        isLifted: Bool,
        isDark: Bool,
        reduceTransparency: Bool
    ) -> NagiLensParams {
        let localLensContainerFrame = localFrame(layout.lensContainerFrame, in: layout.tabBarFrame)
        let lensSelectionFrame = displayedIndex.flatMap { index in
            guard layout.itemFrames.indices.contains(index) else { return nil }
            return layout.itemFrames[index]
        } ?? layout.lensSelectionFrame
        let localSelectionFrame = localFrame(lensSelectionFrame, in: layout.lensContainerFrame)
        return NagiLensParams(
            size: localLensContainerFrame.size,
            containerOrigin: localLensContainerFrame.origin,
            selectionOrigin: localSelectionFrame.origin,
            selectionSize: localSelectionFrame.size,
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
        case .search: return nil
        }
    }
}
