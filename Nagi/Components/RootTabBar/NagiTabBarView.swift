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
}

final class NagiTabBarView: UIView {
    private let glassContainer: NagiGlassContainerView
    private let mainSurface: NagiGlassBackgroundView
    private let mainContentView: UIView
    private let itemViews: [NagiTabBarItemView]
    private let searchView: NagiNavigationSearchView
    private let liquidLensView: NagiLiquidLensView
    private var previousParams: NagiTabBarParams?
    private var lastTraitStyle: UIUserInterfaceStyle

    var onTabSelected: ((AppTab) -> Void)?
    var onSearchActivated: (() -> Void)?
    var onSearchCancelled: (() -> Void)?
    var onSearchQueryChanged: ((String) -> Void)?

    init() {
        self.glassContainer = NagiGlassContainerView(spacing: 7)
        self.mainSurface = NagiGlassBackgroundView(frame: .zero)
        self.mainContentView = UIView(frame: .zero)
        self.itemViews = [AppTab.home, AppTab.library, AppTab.settings].map { NagiTabBarItemView(tab: $0) }
        self.searchView = NagiNavigationSearchView(frame: .zero)
        self.liquidLensView = NagiLiquidLensView(frame: .zero)
        self.lastTraitStyle = .unspecified
        super.init(frame: .zero)

        clipsToBounds = false
        isUserInteractionEnabled = true

        addSubview(glassContainer)
        glassContainer.contentView.addSubview(mainSurface)
        glassContainer.contentView.addSubview(liquidLensView.selectionSurface)
        glassContainer.contentView.addSubview(mainContentView)
        glassContainer.contentView.addSubview(liquidLensView)
        glassContainer.contentView.addSubview(searchView)

        mainContentView.isUserInteractionEnabled = true
        for (index, itemView) in itemViews.enumerated() {
            mainContentView.addSubview(itemView)
            itemView.onActivate = { [weak self] in
                let tabs: [AppTab] = [.home, .library, .settings]
                guard index < tabs.count else { return }
                self?.onTabSelected?(tabs[index])
            }
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
            liftedContentView: itemViews[0],
            punchoutView: mainContentView
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glassContainer.frame = bounds
        liquidLensView.frame = bounds
        if let previousParams {
            applyLocalGeometry(previousParams.layout)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        let style = traitCollection.userInterfaceStyle
        guard style != lastTraitStyle else { return }
        lastTraitStyle = style
        if let previousParams {
            self.previousParams = nil
            apply(params: previousParams, transition: .immediate)
        }
    }

    func update(
        layout: NagiTabBarLayout,
        mode: NagiRootTabMode,
        reduceTransparency: Bool,
        transition: NagiTabTransition
    ) {
        let params = NagiTabBarParams(layout: layout, mode: mode, reduceTransparency: reduceTransparency)
        guard params != previousParams else {
            return
        }
        previousParams = params

        let isDark = traitCollection.userInterfaceStyle == .dark
        let localMainFrame = localFrame(layout.mainTabsFrame, in: layout.tabBarFrame)
        let localSearchFrame = localFrame(layout.searchFrame, in: layout.tabBarFrame)
        let localLensFrame = localFrame(layout.lensFrame, in: layout.tabBarFrame)
        let localItemFrames = layout.itemFrames.map { localFrame($0, in: layout.tabBarFrame) }
        let selectedTab = mode.selectedTab

        if selectedTab != .search, let selectedIndex = mainIndex(for: selectedTab) {
            liquidLensView.setTarget(itemViews[selectedIndex])
        }

        transition.animate { [weak self] in
            guard let self else { return }
            self.glassContainer.frame = self.bounds
            self.mainSurface.frame = localMainFrame
            self.mainSurface.update(params: NagiGlassParams(
                size: localMainFrame.size,
                cornerRadius: NagiTabBarMetrics.barHeight * 0.5,
                isDark: isDark,
                tintColor: isDark ? UIColor.white.withAlphaComponent(0.025) : UIColor.white.withAlphaComponent(0.1),
                tintKey: "main-tabs",
                isInteractive: true,
                isVisible: !layout.isSearchExpanded,
                reduceTransparency: reduceTransparency
            ))
            self.mainContentView.frame = localMainFrame
            self.mainContentView.alpha = layout.isSearchExpanded ? 0 : 1
            self.mainContentView.isUserInteractionEnabled = !layout.isSearchExpanded

            for (itemView, itemFrame) in zip(self.itemViews, localItemFrames) {
                itemView.frame = itemFrame
                itemView.update(isSelected: itemView.tab == selectedTab)
            }

            self.searchView.frame = localSearchFrame
            self.searchView.update(params: NagiSearchParams(
                size: localSearchFrame.size,
                isActive: mode.isSearchVisible,
                isExpanded: layout.isSearchExpanded,
                isDark: isDark,
                reduceTransparency: reduceTransparency
            ))
            self.searchView.alpha = mode.isSearchVisible || !layout.isSearchExpanded ? 1 : 0
        }

        liquidLensView.apply(
            params: NagiLensParams(
                baseFrame: localLensFrame,
                isLifted: !layout.isSearchExpanded && selectedTab != .search,
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

    private func applyLocalGeometry(_ layout: NagiTabBarLayout) {
        glassContainer.frame = bounds
        mainSurface.frame = localFrame(layout.mainTabsFrame, in: layout.tabBarFrame)
        mainContentView.frame = localFrame(layout.mainTabsFrame, in: layout.tabBarFrame)
        searchView.frame = localFrame(layout.searchFrame, in: layout.tabBarFrame)
        liquidLensView.frame = bounds
        liquidLensView.selectionSurface.frame = localFrame(layout.lensFrame, in: layout.tabBarFrame)
        for (itemView, itemFrame) in zip(itemViews, layout.itemFrames.map({ localFrame($0, in: layout.tabBarFrame) })) {
            itemView.frame = itemFrame
        }
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
