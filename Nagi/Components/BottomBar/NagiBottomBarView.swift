//
//  NagiBottomBarView.swift
//  Nagi
//
//  Persistent root navigation surface. All controls are created once.
//

import UIKit

@MainActor
final class NagiBottomBarView: UIView {
    let glassView = NagiBottomBarGlassView()
    let searchContainer = NagiSearchContainerView()

    var onSelectTab: ((AppTab) -> Void)?
    var onSearchActivate: (() -> Void)?
    var onSearchCancel: (() -> Void)?

    private let homeButton = UIButton(type: .system)
    private let libraryButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private var currentMode: BottomBarMode = .tabs
    private var selectedTab: AppTab = .home

    override init(frame: CGRect) {
        super.init(frame: frame)

        isOpaque = false
        clipsToBounds = false
        accessibilityLabel = "主导航"

        glassView.isUserInteractionEnabled = false
        addSubview(glassView)
        addButton(
            homeButton,
            title: "主页",
            image: UIImage(named: "homeIcon") ?? UIImage(systemName: "house"),
            action: #selector(homePressed)
        )
        addButton(
            libraryButton,
            title: "书库",
            image: UIImage(systemName: "books.vertical"),
            action: #selector(libraryPressed)
        )
        addButton(
            settingsButton,
            title: "设置",
            image: UIImage(systemName: "gearshape"),
            action: #selector(settingsPressed)
        )

        searchContainer.onActivate = { [weak self] in self?.onSearchActivate?() }
        searchContainer.onCancel = { [weak self] in self?.onSearchCancel?() }
        addSubview(searchContainer)
        updateSelectionAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        selectedTab: AppTab,
        mode: BottomBarMode,
        reduceMotion: Bool,
        reduceTransparency: Bool
    ) {
        self.selectedTab = selectedTab
        self.currentMode = mode
        glassView.setReduceTransparency(reduceTransparency)
        searchContainer.configure(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency
        )
        updateSelectionAppearance()
    }

    func layoutContents(for mode: BottomBarMode) {
        currentMode = mode
        glassView.frame = bounds

        let frames = NagiBottomBarLayout.normalItemFrames(in: bounds)
        guard frames.count == 4 else { return }

        homeButton.frame = frames[0]
        libraryButton.frame = frames[1]
        settingsButton.frame = frames[2]

        let isSearchActive = mode == .searchActive
        searchContainer.setSearching(isSearchActive)
        searchContainer.frame = isSearchActive
            ? NagiBottomBarLayout.activeSearchFrame(in: bounds)
            : frames[3]

        let normalAlpha: CGFloat = isSearchActive ? 0 : 1
        homeButton.alpha = normalAlpha
        libraryButton.alpha = normalAlpha
        settingsButton.alpha = normalAlpha
        homeButton.isUserInteractionEnabled = !isSearchActive
        libraryButton.isUserInteractionEnabled = !isSearchActive
        settingsButton.isUserInteractionEnabled = !isSearchActive
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutContents(for: currentMode)
    }

    private func addButton(
        _ button: UIButton,
        title: String,
        image: UIImage?,
        action: Selector
    ) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = image
        configuration.baseForegroundColor = .secondaryLabel
        configuration.contentInsets = .zero
        configuration.imagePadding = 0
        button.configuration = configuration
        button.accessibilityLabel = title
        button.accessibilityTraits = [.button]
        button.addTarget(self, action: action, for: .touchUpInside)
        addSubview(button)
    }

    private func updateSelectionAppearance() {
        let selectedColor = tintColor
        let normalColor = UIColor.secondaryLabel
        var homeConfiguration = homeButton.configuration
        homeConfiguration?.baseForegroundColor = selectedTab == .home
            ? selectedColor
            : normalColor
        homeButton.configuration = homeConfiguration

        var libraryConfiguration = libraryButton.configuration
        libraryConfiguration?.baseForegroundColor = selectedTab == .library
            ? selectedColor
            : normalColor
        libraryButton.configuration = libraryConfiguration

        var settingsConfiguration = settingsButton.configuration
        settingsConfiguration?.baseForegroundColor = selectedTab == .settings
            ? selectedColor
            : normalColor
        settingsButton.configuration = settingsConfiguration
    }

    private func select(_ tab: AppTab) {
        guard currentMode != .searchActive else { return }
        selectedTab = tab
        updateSelectionAppearance()
        onSelectTab?(tab)
    }

    @objc private func homePressed() { select(.home) }
    @objc private func libraryPressed() { select(.library) }
    @objc private func settingsPressed() { select(.settings) }
}
