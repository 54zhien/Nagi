import UIKit

struct NagiTabBarParams: Equatable {
    var layout: NagiTabBarLayout
    var selectedTab: AppTab
    var searchState: NagiTabBarSearchState
    var reduceTransparency: Bool
    var selectionGestureIndex: Int?
    var selectionGestureX: CGFloat?
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
    private let mainTabsMotionContainer: UIView
    private let itemViews: [NagiTabBarItemView]
    private let selectedItemViews: [NagiTabBarItemView]
    private let searchView: NagiNavigationSearchView
    private let liquidLensView: NagiLiquidLensView
    private let tabSelectionRecognizer: NagiTabSelectionRecognizer

    private var previousParams: NagiTabBarParams?
    private var currentLayout: NagiTabBarLayout?
    private var currentSelectedTab: AppTab = .home
    private var currentSearchState = NagiTabBarSearchState.inactive
    private var currentItemFramesInRoot: [CGRect] = []
    private var currentTabsSize: CGSize = .zero
    private var selectionGestureState: NagiSelectionGestureState?
    private var overrideSelectedIndex: Int?
    private var lastTraitStyle: UIUserInterfaceStyle

    var onTabSelected: ((AppTab) -> Void)?
    var onSearchActivated: (() -> Void)?
    var onSearchCancelled: (() -> Void)?
    var onSearchQueryChanged: ((String) -> Void)?

    init() {
        glassContainer = NagiGlassContainerView(spacing: 7)
        mainTabsMotionContainer = UIView(frame: .zero)

        let tabs: [AppTab] = [.home, .library, .settings]
        itemViews = tabs.map {
            NagiTabBarItemView(
                tab: $0,
                visualRole: .normal,
                isInteractive: false
            )
        }
        selectedItemViews = tabs.map {
            NagiTabBarItemView(
                tab: $0,
                visualRole: .selected,
                isInteractive: false
            )
        }
        searchView = NagiNavigationSearchView(frame: .zero)
        liquidLensView = NagiLiquidLensView(frame: .zero)
        tabSelectionRecognizer = NagiTabSelectionRecognizer(target: nil, action: nil)
        lastTraitStyle = .unspecified
        super.init(frame: .zero)

        traitOverrides.verticalSizeClass = .compact
        traitOverrides.horizontalSizeClass = .compact

        clipsToBounds = false
        isUserInteractionEnabled = true

        addSubview(glassContainer)

        mainTabsMotionContainer.backgroundColor = .clear
        mainTabsMotionContainer.isOpaque = false
        mainTabsMotionContainer.clipsToBounds = false
        mainTabsMotionContainer.isUserInteractionEnabled = false
        glassContainer.contentView.addSubview(mainTabsMotionContainer)
        mainTabsMotionContainer.addSubview(liquidLensView)

        glassContainer.contentView.addSubview(searchView)

        for view in itemViews {
            view.isUserInteractionEnabled = false
            liquidLensView.contentView.addSubview(view)
        }
        for view in selectedItemViews {
            view.isUserInteractionEnabled = false
            liquidLensView.selectedContentView.addSubview(view)
        }

        tabSelectionRecognizer.addTarget(
            self,
            action: #selector(handleTabSelectionGesture(_:))
        )
        tabSelectionRecognizer.shouldBeginAtLocation = { [weak self] location in
            self?.shouldBeginTabSelectionGesture(at: location) ?? false
        }
        addGestureRecognizer(tabSelectionRecognizer)

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

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (view: NagiTabBarView, _) in
            view.handleTraitCollectionChange()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glassContainer.frame = bounds
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) {
            return true
        }

        guard currentSearchState.isActive,
              let currentLayout else {
            return false
        }
        let collapsedFrame = localFrame(
            currentLayout.mainTabsFrame,
            in: currentLayout.tabBarFrame
        )
        return collapsedFrame.contains(point)
    }

    private func handleTraitCollectionChange() {
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
            selectionGestureX: selectionGestureState?.currentSelectionX,
            overrideSelectedIndex: overrideSelectedIndex
        )
        guard nextParams != previousParams else {
            completion?(true)
            return
        }
        previousParams = nextParams

        let isDark = traitCollection.userInterfaceStyle == .dark
        let innerInset = NagiTabBarMetrics.innerInset
        let itemHeight = NagiTabBarMetrics.itemHeight
        let barHeight = itemHeight + innerInset * 2
        let availableSize = CGSize(
            width: min(500, layout.tabBarFrame.width),
            height: layout.tabBarFrame.height
        )

        // Reserve the standalone search slot, then give each main tab the same width.
        var availableItemsWidth = max(0, availableSize.width - innerInset * 2)
        availableItemsWidth = max(
            0,
            availableItemsWidth - barHeight - NagiTabBarMetrics.standaloneGap
        )
        let equalWidth = floorToScreenPixels(
            availableItemsWidth / CGFloat(max(1, itemViews.count))
        )
        let itemWidths = Array(repeating: equalWidth, count: itemViews.count)
        let totalItemsWidth = itemWidths.reduce(0, +)
        let contentWidth = innerInset * 2 + totalItemsWidth
        let tabsSize = CGSize(
            width: min(availableSize.width, contentWidth),
            height: barHeight
        )
        currentTabsSize = tabsSize

        let selectedIndex = mainIndex(for: selectedTab)
        let displayedIndex =
            selectionGestureState?.hoveredIndex
            ?? overrideSelectedIndex
            ?? selectedIndex

        var itemFrames: [CGRect] = []
        var selectionFrame: CGRect?
        var nextItemX = innerInset
        for index in itemViews.indices {
            let itemSize = CGSize(width: itemWidths[index], height: itemHeight)
            var itemFrame = CGRect(
                x: nextItemX,
                y: floor((tabsSize.height - itemSize.height) * 0.5),
                width: itemSize.width,
                height: itemSize.height
            )
            nextItemX += itemSize.width

            if displayedIndex == index {
                if itemFrame.width < itemFrame.height {
                    selectionFrame = itemFrame.insetBy(
                        dx: floor((itemFrame.height * 1.2 - itemFrame.width) * -0.5),
                        dy: 0
                    )
                } else {
                    selectionFrame = itemFrame
                }
            }

            if searchState.isActive, displayedIndex == index {
                itemFrame.origin.x = floor(
                    (NagiTabBarMetrics.collapsedLensDiameter - itemSize.width) * 0.5
                )
            }
            itemFrames.append(itemFrame)
        }

        var tabsFrame = CGRect(origin: .zero, size: tabsSize)
        if searchState.isActive {
            // Keep the existing outer placement while the tab content collapses.
            tabsFrame = localFrame(
                layout.mainTabsFrame,
                in: layout.tabBarFrame
            )
        }

        currentItemFramesInRoot = itemFrames.map {
            $0.offsetBy(dx: tabsFrame.minX, dy: tabsFrame.minY)
        }

        var lensSelection: (x: CGFloat, width: CGFloat)
        if let gesture = selectionGestureState {
            lensSelection = (
                gesture.currentSelectionX,
                gesture.itemWidth + innerInset * 2
            )
        } else if let selectionFrame {
            lensSelection = (
                selectionFrame.minX - innerInset,
                selectionFrame.width + innerInset * 2
            )
        } else {
            lensSelection = (0, 56)
        }

        var lensSize = tabsSize
        if searchState.isActive {
            lensSize = CGSize(
                width: NagiTabBarMetrics.collapsedLensDiameter,
                height: NagiTabBarMetrics.collapsedLensDiameter
            )
            lensSelection = (0, NagiTabBarMetrics.collapsedLensDiameter)
        }
        lensSelection.x = max(
            0,
            min(lensSelection.x, lensSize.width - lensSelection.width)
        )

        let searchSize: CGSize
        let searchFrame: CGRect
        if searchState.isActive {
            searchSize = CGSize(
                width: availableSize.width,
                height: NagiTabBarMetrics.activeSearchHeight
            )
            searchFrame = CGRect(
                x: 0,
                y: tabsSize.height - searchSize.height,
                width: searchSize.width,
                height: searchSize.height
            )
        } else {
            searchSize = CGSize(width: barHeight, height: barHeight)
            searchFrame = CGRect(
                x: availableSize.width - searchSize.width,
                y: 0,
                width: searchSize.width,
                height: searchSize.height
            )
        }

        let searchBackgroundSize = searchState.isActive
            ? CGSize(
                width: max(
                    0,
                    searchSize.width
                        - NagiTabBarMetrics.searchCloseDiameter
                        - NagiTabBarMetrics.standaloneGap
                ),
                height: searchSize.height
            )
            : searchSize
        let searchParams = NagiSearchParams(
            containerSize: searchSize,
            backgroundFrame: CGRect(origin: .zero, size: searchBackgroundSize),
            closeFrame: searchState.isActive
                ? CGRect(
                    x: searchSize.width - NagiTabBarMetrics.searchCloseDiameter,
                    y: 0,
                    width: NagiTabBarMetrics.searchCloseDiameter,
                    height: NagiTabBarMetrics.searchCloseDiameter
                )
                : .zero,
            isActive: searchState.isActive,
            isExpandedStandaloneBar: false,
            isDark: isDark,
            reduceTransparency: reduceTransparency
        )
        let searchChanged = searchView.prepare(params: searchParams)

        let itemAlphaTransition: NagiTabTransition = transition.isImmediate
            ? .immediate
            : .easeInOut(duration: 0.25)

        transition.perform({ [weak self] in
            guard let self else { return }

            transition.setFrame(
                view: mainTabsMotionContainer,
                frame: tabsFrame
            )
            transition.setFrame(
                view: liquidLensView,
                frame: CGRect(origin: .zero, size: tabsFrame.size)
            )

            for index in itemViews.indices {
                let frame = itemFrames[index]
                transition.setFrame(view: itemViews[index], frame: frame)
                transition.setPosition(
                    view: selectedItemViews[index],
                    position: CGPoint(x: frame.midX, y: frame.midY)
                )
                transition.setBounds(
                    view: selectedItemViews[index],
                    bounds: CGRect(origin: .zero, size: frame.size)
                )
            }

            updateItemSelectionPresentation(
                displayedIndex: displayedIndex,
                transition: transition,
                blurTransition: itemAlphaTransition,
                isSearchActive: searchState.isActive
            )

            liquidLensView.apply(
                params: NagiLensParams(
                    size: lensSize,
                    containerOrigin: .zero,
                    selectionOrigin: CGPoint(x: lensSelection.x, y: 0),
                    selectionSize: CGSize(
                        width: lensSelection.width,
                        height: lensSize.height
                    ),
                    isDark: isDark,
                    inset: innerInset,
                    liftedInset: innerInset,
                    isLifted: selectionGestureState != nil,
                    isCollapsed: searchState.isActive,
                    reduceTransparency: reduceTransparency
                ),
                transition: transition
            )

            if searchChanged {
                searchView.applyInternalGeometry(
                    params: searchParams,
                    transition: transition
                )
            }
            transition.setFrame(view: searchView, frame: searchFrame)

            glassContainer.update(
                size: availableSize,
                isDark: isDark,
                transition: transition
            )
        }, completion: completion)

        if selectionGestureState == nil,
           overrideSelectedIndex == selectedIndex {
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

    private func shouldBeginTabSelectionGesture(at location: CGPoint) -> Bool {
        if currentSearchState.isActive {
            guard let currentLayout else { return false }
            return localFrame(
                currentLayout.mainTabsFrame,
                in: currentLayout.tabBarFrame
            ).contains(location)
        }
        return mainIndex(at: location, requiresMainFrameHit: true) != nil
    }

    @objc private func handleTabSelectionGesture(
        _ recognizer: NagiTabSelectionRecognizer
    ) {
        if currentSearchState.isActive {
            if recognizer.state == .ended || recognizer.state == .cancelled {
                onSearchCancelled?()
            }
            return
        }

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
              !currentSearchState.isActive,
              let hoveredIndex = mainIndex(
                at: location,
                requiresMainFrameHit: true
              ),
              let originalIndex = mainIndex(for: currentSelectedTab),
              itemViews.indices.contains(hoveredIndex) else {
            return
        }

        // Start the lens from the item frame currently under the touch.
        let itemFrame = itemViews[hoveredIndex].frame
        let startX = itemFrame.minX - NagiTabBarMetrics.innerInset
        selectionGestureState = NagiSelectionGestureState(
            originalIndex: originalIndex,
            hoveredIndex: hoveredIndex,
            startSelectionX: startX,
            currentSelectionX: startX,
            itemWidth: itemFrame.width
        )
        renderCurrentLayout(transition: .spring(duration: 0.4))
    }

    private func updateTabSelection(
        using recognizer: NagiTabSelectionRecognizer
    ) {
        guard var gesture = selectionGestureState else { return }

        gesture.currentSelectionX = gesture.startSelectionX
            + recognizer.translation().x
        if let hovered = mainIndex(
            at: recognizer.currentLocation,
            requiresMainFrameHit: false
        ) {
            gesture.hoveredIndex = hovered
        }
        selectionGestureState = gesture
        renderCurrentLayout(transition: .immediate)
    }

    private func finishTabSelection() {
        guard let gesture = selectionGestureState,
              let actualIndex = mainIndex(for: currentSelectedTab) else {
            cancelTabSelection()
            return
        }

        let finalIndex = max(
            0,
            min(itemViews.count - 1, gesture.hoveredIndex)
        )
        selectionGestureState = nil

        if finalIndex != actualIndex {
            overrideSelectedIndex = finalIndex
            onTabSelected?(tab(forMainIndex: finalIndex))
        } else {
            overrideSelectedIndex = nil
            renderCurrentLayout(transition: .spring(duration: 0.4))
        }
    }

    private func cancelTabSelection() {
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
        transition: NagiTabTransition,
        blurTransition: NagiTabTransition,
        isSearchActive: Bool
    ) {
        let selectedScale: CGFloat = selectionGestureState != nil ? 1.15 : 1.0

        for index in itemViews.indices {
            let isSelected = displayedIndex == index
            let itemView = itemViews[index]
            let selectedItemView = selectedItemViews[index]

            itemView.update(
                isSelected: isSelected,
                usesPrivateLens: liquidLensView.usesPrivateLens,
                isCompact: isSearchActive,
                titleTransition: blurTransition
            )
            selectedItemView.update(
                isSelected: isSelected,
                usesPrivateLens: liquidLensView.usesPrivateLens,
                isCompact: isSearchActive,
                titleTransition: blurTransition
            )

            if isSearchActive {
                if isSelected {
                    transition.setAlpha(view: itemView, alpha: 1)
                    blurTransition.setBlur(layer: itemView.layer, radius: 0)
                    transition.setAlpha(view: selectedItemView, alpha: 1)
                    blurTransition.setBlur(layer: selectedItemView.layer, radius: 0)
                } else {
                    transition.setAlpha(view: itemView, alpha: 0)
                    blurTransition.setBlur(layer: itemView.layer, radius: 10)
                    transition.setAlpha(view: selectedItemView, alpha: 0)
                    blurTransition.setBlur(layer: selectedItemView.layer, radius: 10)
                }
            } else {
                transition.setAlpha(view: itemView, alpha: 1)
                blurTransition.setBlur(layer: itemView.layer, radius: 0)
                transition.setAlpha(view: selectedItemView, alpha: 1)
                blurTransition.setBlur(layer: selectedItemView.layer, radius: 0)
            }

            transition.setScale(
                view: selectedItemView,
                scale: selectedScale
            )
        }
    }

    private func mainIndex(
        at location: CGPoint,
        requiresMainFrameHit: Bool
    ) -> Int? {
        guard !currentSearchState.isActive,
              !currentItemFramesInRoot.isEmpty else {
            return nil
        }

        let unionFrame = currentItemFramesInRoot.reduce(CGRect.null) {
            $0.union($1)
        }
        if requiresMainFrameHit && !unionFrame.insetBy(
            dx: -NagiTabBarMetrics.innerInset,
            dy: -NagiTabBarMetrics.innerInset
        ).contains(location) {
            return nil
        }

        if let index = currentItemFramesInRoot.firstIndex(where: {
            $0.contains(location)
        }) {
            return index
        }

        return currentItemFramesInRoot.indices.min {
            abs(currentItemFramesInRoot[$0].midX - location.x)
                < abs(currentItemFramesInRoot[$1].midX - location.x)
        }
    }

    private func tab(forMainIndex index: Int) -> AppTab {
        switch index {
        case 0: return .home
        case 1: return .library
        default: return .settings
        }
    }

    private func mainIndex(for tab: AppTab) -> Int? {
        switch tab {
        case .home: return 0
        case .library: return 1
        case .settings: return 2
        }
    }

    private func localFrame(_ frame: CGRect, in parentFrame: CGRect) -> CGRect {
        guard !frame.isEmpty else { return .zero }
        return frame.offsetBy(
            dx: -parentFrame.minX,
            dy: -parentFrame.minY
        )
    }
}
