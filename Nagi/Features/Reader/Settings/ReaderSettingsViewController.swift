//
//  ReaderSettingsViewController.swift
//  Nagi
//
//  UIKit implementation of the reader's medium settings surface.  SwiftUI
//  continues to own sheet presentation and the custom editor; this controller
//  owns the persistent controls and the scrollable settings layout.
//

import SwiftUI
import UIKit

private enum ReaderSettingsControlID: Hashable {
    case fontSmaller
    case fontLarger
    case transition
    case appearance
    case original
    case quiet
    case paper
}

@MainActor
final class ReaderSettingsViewController: UIViewController {
    private let model: ReaderViewModel
    private var latestPreferences: ReaderPreferences
    private var latestSystemBrightness: Double
    private var latestIsDarkAppearance: Bool
    private var latestReduceMotion: Bool

    var onCustomSettings: (() -> Void)?
    var onBeforeMutation: (() -> Void)?
    var onSystemBrightnessChanged: ((Double) -> Void)?

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let topControlGroup = GlassControlGroup<ReaderSettingsControlID>(spacing: 2)
    private let presetControlGroup = GlassControlGroup<ReaderSettingsControlID>(spacing: 10)
    private let customControl = GlassControlView()
    private let brightnessSlider = UISlider()
    private let minimumBrightnessImageView = UIImageView()
    private let maximumBrightnessImageView = UIImageView()
    private let indicatorView = UIView()
    private let indicatorDots: [UIView] = (0 ..< ReaderFontSize.indicatorCount).map { _ in UIView() }
    private var indicatorHideTask: Task<Void, Never>?

    init(
        model: ReaderViewModel,
        preferences: ReaderPreferences,
        systemBrightness: Double,
        isDarkAppearance: Bool,
        reduceMotion: Bool
    ) {
        self.model = model
        latestPreferences = preferences
        latestSystemBrightness = systemBrightness
        latestIsDarkAppearance = isDarkAppearance
        latestReduceMotion = reduceMotion
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        indicatorHideTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .clear
        scrollView.backgroundColor = .clear
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)

        contentView.backgroundColor = .clear
        contentView.isOpaque = false
        scrollView.addSubview(contentView)

        contentView.addSubview(topControlGroup)
        contentView.addSubview(indicatorView)
        contentView.addSubview(minimumBrightnessImageView)
        contentView.addSubview(brightnessSlider)
        contentView.addSubview(maximumBrightnessImageView)
        contentView.addSubview(presetControlGroup)
        contentView.addSubview(customControl)

        for dot in indicatorDots {
            dot.layer.cornerRadius = 2
            dot.isUserInteractionEnabled = false
            dot.accessibilityElementsHidden = true
            indicatorView.addSubview(dot)
        }

        minimumBrightnessImageView.image = UIImage(systemName: "sun.min.fill")
        maximumBrightnessImageView.image = UIImage(systemName: "sun.max.fill")
        minimumBrightnessImageView.contentMode = .center
        maximumBrightnessImageView.contentMode = .center
        minimumBrightnessImageView.tintColor = .secondaryLabel
        maximumBrightnessImageView.tintColor = .secondaryLabel
        minimumBrightnessImageView.accessibilityElementsHidden = true
        maximumBrightnessImageView.accessibilityElementsHidden = true

        brightnessSlider.minimumValue = 0
        brightnessSlider.maximumValue = 1
        brightnessSlider.isContinuous = true
        brightnessSlider.accessibilityLabel = "系统亮度"
        brightnessSlider.addTarget(
            self,
            action: #selector(brightnessChanged(_:)),
            for: .valueChanged
        )

        customControl.addTarget(
            self,
            action: #selector(customSettingsSelected),
            for: .primaryActionTriggered
        )

        render()
    }

    func update(
        preferences: ReaderPreferences,
        systemBrightness: Double,
        isDarkAppearance: Bool,
        reduceMotion: Bool
    ) {
        latestPreferences = preferences
        latestSystemBrightness = min(max(systemBrightness, 0), 1)
        latestIsDarkAppearance = isDarkAppearance
        latestReduceMotion = reduceMotion
        guard isViewLoaded else { return }
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        scrollView.frame = view.bounds
        let width = max(0, view.bounds.width - 36)
        let horizontalInset: CGFloat = 18
        let topHeight: CGFloat = 44
        let topFrame = CGRect(x: horizontalInset, y: 8, width: width, height: topHeight)
        topControlGroup.frame = topFrame

        let fontGroupWidth = max(0, width - 116)
        let fontItemWidth = max(0, fontGroupWidth / 2)
        topControlGroup.setItemFrames([
            .fontSmaller: CGRect(x: 0, y: 0, width: fontItemWidth, height: topHeight),
            .fontLarger: CGRect(
                x: fontItemWidth,
                y: 0,
                width: max(0, fontGroupWidth - fontItemWidth),
                height: topHeight
            ),
            .transition: CGRect(x: fontGroupWidth + 10, y: 0, width: 48, height: topHeight),
            .appearance: CGRect(x: fontGroupWidth + 68, y: 0, width: 48, height: topHeight)
        ])

        let indicatorY: CGFloat = 58
        indicatorView.frame = CGRect(
            x: horizontalInset,
            y: indicatorY,
            width: fontGroupWidth,
            height: 8
        )
        layoutIndicatorDots()

        let brightnessY: CGFloat = 84
        let brightnessHeight: CGFloat = 44
        minimumBrightnessImageView.frame = CGRect(
            x: horizontalInset + 4,
            y: brightnessY,
            width: 20,
            height: brightnessHeight
        )
        maximumBrightnessImageView.frame = CGRect(
            x: horizontalInset + width - 24,
            y: brightnessY,
            width: 20,
            height: brightnessHeight
        )
        brightnessSlider.frame = CGRect(
            x: horizontalInset + 36,
            y: brightnessY,
            width: max(0, width - 72),
            height: brightnessHeight
        )

        let presetY: CGFloat = 142
        let presetHeight: CGFloat = 208
        presetControlGroup.frame = CGRect(
            x: horizontalInset,
            y: presetY,
            width: width,
            height: presetHeight
        )
        let presetWidth = max(0, (width - 20) / 3)
        presetControlGroup.setItemFrames([
            .original: CGRect(x: 0, y: 0, width: presetWidth, height: presetHeight),
            .quiet: CGRect(
                x: presetWidth + 10,
                y: 0,
                width: presetWidth,
                height: presetHeight
            ),
            .paper: CGRect(
                x: (presetWidth + 10) * 2,
                y: 0,
                width: presetWidth,
                height: presetHeight
            )
        ])

        customControl.frame = CGRect(
            x: horizontalInset,
            y: 368,
            width: width,
            height: 48
        )

        let contentHeight: CGFloat = 438
        contentView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: contentHeight)
        scrollView.contentSize = contentView.bounds.size
    }

    private func render() {
        guard isViewLoaded else { return }

        let preferences = latestPreferences
        let accentColor = UIColor(named: "AccentColor") ?? .systemBlue
        let currentFontIndex = fontSizeIndex(for: preferences.fontSize)
        let smallerIndex = max(0, currentFontIndex - 1)
        let largerIndex = min(ReaderFontSize.indicatorCount - 1, currentFontIndex + 1)
        let symbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 24,
            weight: .regular
        )

        topControlGroup.update(items: [
            .init(
                id: .fontSmaller,
                image: UIImage(named: "readerFontSizeSmaller")?.withRenderingMode(.alwaysTemplate),
                accessibilityLabel: "字号小",
                tintColor: accentColor,
                isEnabled: smallerIndex != currentFontIndex,
                reduceMotion: latestReduceMotion,
                action: { [weak self] in self?.adjustFontSize(to: smallerIndex) }
            ),
            .init(
                id: .fontLarger,
                image: UIImage(named: "readerFontSizeLarger")?.withRenderingMode(.alwaysTemplate),
                accessibilityLabel: "字号大",
                tintColor: accentColor,
                isEnabled: largerIndex != currentFontIndex,
                reduceMotion: latestReduceMotion,
                action: { [weak self] in self?.adjustFontSize(to: largerIndex) }
            ),
            .init(
                id: .transition,
                image: UIImage(
                    systemName: preferences.pageTransition.systemImage,
                    withConfiguration: symbolConfiguration
                ),
                accessibilityLabel: "翻页方式",
                tintColor: .label,
                reduceMotion: latestReduceMotion,
                action: { [weak self] in self?.presentTransitionMenu() }
            ),
            .init(
                id: .appearance,
                image: UIImage(
                    systemName: preferences.appearanceMode.systemImage,
                    withConfiguration: symbolConfiguration
                ),
                accessibilityLabel: "外观模式",
                tintColor: .label,
                reduceMotion: latestReduceMotion,
                action: { [weak self] in self?.presentAppearanceMenu() }
            )
        ])
        topControlGroup.accessibilityLabel = "字号、翻页和外观"
        let fontAccessibilityValue = "当前字号 \(Int(preferences.fontSize.rounded())) 磅"
        topControlGroup.control(for: .fontSmaller)?.accessibilityValue = fontAccessibilityValue
        topControlGroup.control(for: .fontLarger)?.accessibilityValue = fontAccessibilityValue
        topControlGroup.control(for: .transition)?.accessibilityValue = preferences.pageTransition.label
        topControlGroup.control(for: .appearance)?.accessibilityValue = preferences.appearanceMode.label

        presetControlGroup.update(items: ReaderThemePreset.allCases.map { preset in
            let isSelected = preferences.themePreset == preset
            let theme = preset.paletteTheme
            let background = theme.readerBackgroundUIColor(isDarkAppearance: latestIsDarkAppearance)
            let content = isSelected
                ? accentColor
                : theme.readerContentUIColor(isDarkAppearance: latestIsDarkAppearance)
            return .init(
                id: controlID(for: preset),
                image: nil,
                accessibilityLabel: "主题预设：\(preset.label)",
                tintColor: background,
                reduceMotion: latestReduceMotion,
                title: preset.label,
                isSelected: isSelected,
                cornerRadius: 18,
                contentColor: content,
                action: { [weak self] in self?.select(preset: preset) }
            )
        })
        presetControlGroup.accessibilityLabel = "主题预设"

        customControl.update(
            image: UIImage(systemName: "gear"),
            accessibilityLabel: "自定义",
            tintColor: nil,
            isEnabled: true,
            reduceMotion: latestReduceMotion,
            title: "自定义",
            cornerRadius: 24,
            contentColor: accentColor
        )
        customControl.accessibilityHint = "打开更多文字与布局选项"

        let brightness = Float(min(max(latestSystemBrightness, 0), 1))
        if abs(brightnessSlider.value - brightness) > 0.0001 {
            brightnessSlider.setValue(brightness, animated: false)
        }
        brightnessSlider.accessibilityValue = "\(Int(Double(brightness) * 100))%"

        for (index, dot) in indicatorDots.enumerated() {
            dot.backgroundColor = index <= currentFontIndex
                ? accentColor
                : UIColor.secondaryLabel.withAlphaComponent(0.22)
        }
        setNeedsLayout()
    }

    private func layoutIndicatorDots() {
        guard !indicatorDots.isEmpty else { return }
        let dotSize: CGFloat = 4
        let spacing: CGFloat = 6
        let totalWidth = dotSize * CGFloat(indicatorDots.count)
            + spacing * CGFloat(max(0, indicatorDots.count - 1))
        var x = max(0, (indicatorView.bounds.width - totalWidth) / 2)
        for dot in indicatorDots {
            dot.frame = CGRect(x: x, y: 2, width: dotSize, height: dotSize)
            x += dotSize + spacing
        }
    }

    private func fontSizeIndex(for size: Double) -> Int {
        let rawIndex = Int(
            ((size - ReaderFontSize.minimum) / ReaderFontSize.step).rounded()
        )
        return min(max(rawIndex, 0), ReaderFontSize.indicatorCount - 1)
    }

    private func controlID(for preset: ReaderThemePreset) -> ReaderSettingsControlID {
        switch preset {
        case .original: return .original
        case .quiet: return .quiet
        case .paper: return .paper
        }
    }

    private func adjustFontSize(to index: Int) {
        guard ReaderFontSize.indicatorCount > 0 else { return }
        let currentIndex = fontSizeIndex(for: model.preferences.fontSize)
        guard index != currentIndex else { return }

        onBeforeMutation?()
        let size = ReaderFontSize.minimum + Double(index) * ReaderFontSize.step
        model.setFontSize(size)
        latestPreferences = model.preferences
        showFontSizeIndicator()
        render()
    }

    private func select(preset: ReaderThemePreset) {
        guard model.preferences.themePreset != preset else { return }
        onBeforeMutation?()
        model.selectPreset(preset)
        latestPreferences = model.preferences
        render()
    }

    private func presentTransitionMenu() {
        guard let source = topControlGroup.control(for: .transition) else { return }
        let alert = UIAlertController(title: "翻页方式", message: nil, preferredStyle: .actionSheet)
        for transition in ReaderPageTransition.allCases {
            let action = UIAlertAction(
                title: transition.label,
                style: .default
            ) { [weak self] _ in
                self?.select(transition: transition)
            }
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        configurePopover(alert, sourceView: source)
        present(alert, animated: !latestReduceMotion)
    }

    private func presentAppearanceMenu() {
        guard let source = topControlGroup.control(for: .appearance) else { return }
        let alert = UIAlertController(title: "外观模式", message: nil, preferredStyle: .actionSheet)
        for appearance in ReaderAppearanceMode.allCases {
            let action = UIAlertAction(
                title: appearance.label,
                style: .default
            ) { [weak self] _ in
                self?.select(appearance: appearance)
            }
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        configurePopover(alert, sourceView: source)
        present(alert, animated: !latestReduceMotion)
    }

    private func configurePopover(_ alert: UIAlertController, sourceView: UIView) {
        guard let popover = alert.popoverPresentationController else { return }
        popover.sourceView = sourceView
        popover.sourceRect = sourceView.bounds
        popover.permittedArrowDirections = [.up, .down]
    }

    private func select(transition: ReaderPageTransition) {
        guard model.preferences.pageTransition != transition else { return }
        onBeforeMutation?()
        model.setPageTransition(transition)
        latestPreferences = model.preferences
        render()
    }

    private func select(appearance: ReaderAppearanceMode) {
        guard model.preferences.appearanceMode != appearance else { return }
        onBeforeMutation?()
        model.setAppearance(appearance)
        latestPreferences = model.preferences
        render()
    }

    private func showFontSizeIndicator() {
        indicatorHideTask?.cancel()
        indicatorView.alpha = 1
        indicatorHideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            if self.latestReduceMotion {
                self.indicatorView.alpha = 0
            } else {
                UIView.animate(
                    withDuration: 0.15,
                    delay: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction]
                ) {
                    self.indicatorView.alpha = 0
                }
            }
        }
    }

    @objc private func brightnessChanged(_ sender: UISlider) {
        latestSystemBrightness = Double(sender.value)
        sender.accessibilityValue = "\(Int(latestSystemBrightness * 100))%"
        onSystemBrightnessChanged?(latestSystemBrightness)
    }

    @objc private func customSettingsSelected() {
        onCustomSettings?()
    }
}

@MainActor
struct ReaderSettingsViewControllerRepresentable: UIViewControllerRepresentable {
    let model: ReaderViewModel
    let preferences: ReaderPreferences
    let systemBrightness: Double
    let isDarkAppearance: Bool
    let reduceMotion: Bool
    let onCustomSettings: () -> Void
    let onBeforeMutation: () -> Void
    let onSystemBrightnessChanged: (Double) -> Void

    func makeUIViewController(context: Context) -> ReaderSettingsViewController {
        let controller = ReaderSettingsViewController(
            model: model,
            preferences: preferences,
            systemBrightness: systemBrightness,
            isDarkAppearance: isDarkAppearance,
            reduceMotion: reduceMotion
        )
        controller.onCustomSettings = onCustomSettings
        controller.onBeforeMutation = onBeforeMutation
        controller.onSystemBrightnessChanged = onSystemBrightnessChanged
        return controller
    }

    func updateUIViewController(
        _ uiViewController: ReaderSettingsViewController,
        context: Context
    ) {
        uiViewController.onCustomSettings = onCustomSettings
        uiViewController.onBeforeMutation = onBeforeMutation
        uiViewController.onSystemBrightnessChanged = onSystemBrightnessChanged
        uiViewController.update(
            preferences: preferences,
            systemBrightness: systemBrightness,
            isDarkAppearance: isDarkAppearance,
            reduceMotion: reduceMotion
        )
    }
}
