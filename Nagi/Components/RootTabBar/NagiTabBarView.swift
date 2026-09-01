//
//  NagiTabBarView.swift
//  Nagi
//
//  RootTabBar 的持久化 UIKit 实现。所有 surface、tab item、搜索控件和
//  selection lens 只创建一次，之后只根据 Equatable 参数更新几何与状态。
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
    private let mainSurface: NagiGlassBackgroundView
    private let itemViews: [NagiTabBarItemView]
    private let selectedItemViews: [NagiTabBarItemView]
    private let searchView: NagiNavigationSearchView
    private let liquidLensView: NagiLiquidLensView
    private var previousParams: NagiTabBarParams?
    private var currentLayout: NagiTabBarLayout?
    private var currentMode: NagiRootTabMode?
    private var selectionGestureState: NagiSelectionGestureState?
    private let isLiftedStateEnabled = true
    private var lastTraitStyle: UIUserInterfaceStyle

    var onTabSelected: ((AppTab) -> Void)?
    var onSearchActivated: (() -> Void)?
    var onSearchCancelled: (() -> Void)?
    var onSearchQueryChanged: ((String) -> Void)?

    init() {
        self.glassContainer = NagiGlassContainerView(spacing: 7)
        self.mainSurface = NagiGlassBackgroundView(frame: .zero)
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
        glassContainer.contentView.addSubview(mainSurface)
        glassContainer.contentView.addSubview(liquidLensView.selectionSurface)
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
            liftedContainerView: glassContainer.contentView,
            liftedContentView: liquidLensView.selectedContentView,
            punchoutView: liquidLensView.contentView
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
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

        let params = NagiTabBarParams(
            layout: layout,
            mode: mode,
            reduceTransparency: reduceTransparency,
            selectionGestureIndex: selectionGestureState?.index
        )
        guard params != previousParams else {
            return
        }
        previousParams = params

        let isDark = traitCollection.userInterfaceStyle == .dark
        let localMainFrame = localFrame(layout.mainTabsFrame, in: layout.tabBarFrame)
        let localSearchFrame = localFrame(layout.searchFrame, in: layout.tabBarFrame)
        let localItemFrames = layout.itemFrames.map { localFrame($0, in: layout.mainTabsFrame) }
        let selectedTab = mode.selectedTab
        let selectedIndex = mainIndex(for: selectedTab)
        let displayedIndex = selectionGestureState?.index ?? selectedIndex
        let lensFrame: CGRect
        if let displayedIndex, layout.itemFrames.indices.contains(displayedIndex) {
            lensFrame = localFrame(layout.itemFrames[displayedIndex], in: layout.tabBarFrame)
        } else {
            lensFrame = .zero
        }
        let isLifted = selectionGestureState != nil && isLiftedStateEnabled
        let isLensVisible = !layout.isSearchExpanded && !lensFrame.isEmpty
        let mainGlassParams = NagiGlassParams(
            size: localMainFrame.size,
            cornerRadius: NagiTabBarMetrics.barHeight * 0.5,
            isDark: isDark,
            tintColor: isDark ? UIColor.white.withAlphaComponent(0.025) : UIColor.white.withAlphaComponent(0.1),
            tintKey: "main-tabs",
            isInteractive: true,
            isVisible: !layout.isSearchExpanded,
            reduceTransparency: reduceTransparency
        )
        let searchParams = NagiSearchParams(
            size: localSearchFrame.size,
            isActive: mode.isSearchVisible,
            isExpanded: layout.isSearchExpanded,
            isDark: isDark,
            reduceTransparency: reduceTransparency
        )

        mainSurface.prepare(params: mainGlassParams)
        searchView.prepare(params: searchParams)

        transition.animate { [weak self] in
            guard let self else { return }
            self.glassContainer.frame = self.bounds
            self.mainSurface.applyGeometry(params: mainGlassParams)
            self.liquidLensView.contentView.frame = localMainFrame
            self.liquidLensView.selectedContentView.frame = localMainFrame
            self.liquidLensView.contentView.isUserInteractionEnabled = !layout.isSearchExpanded

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
                selectedItemView.update(isSelected: displayedIndex == self.mainIndex(for: selectedItemView.tab))
                selectedItemView.alpha = displayedIndex == self.mainIndex(for: selectedItemView.tab) ? 1 : 0
            }

            NagiTabTransition.setFrame(self.searchView, localSearchFrame)
            self.searchView.applyGeometry(params: searchParams)
            self.searchView.alpha = mode.isSearchVisible || !layout.isSearchExpanded ? 1 : 0
        }

        liquidLensView.apply(
            params: NagiLensParams(
                baseFrame: lensFrame,
                isVisible: isLensVisible,
                isLifted: isLifted,
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

    private func localFrame(_ frame: CGRect, in barFrame: CGRect) -> CGRect {
        guard !frame.isEmpty else { return .zero }
        return frame.offsetBy(dx: -barFrame.minX, dy: -barFrame.minY)
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
