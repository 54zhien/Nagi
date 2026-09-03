
import SwiftUI
import UIKit

private enum ReaderSettingsControlID: Hashable {
    case transition
    case appearance
    case original
    case quiet
    case paper
}

private enum PendingReaderMutation {
    case fontStep(Int)
    case preset(ReaderThemePreset)
    case transition(ReaderPageTransition)
    case appearance(ReaderAppearanceMode)

    var visualMutationKind: ReaderVisualMutationKind {
        switch self {
        case .fontStep:
            return .font
        case .preset, .appearance:
            return .theme
        case .transition:
            return .geometry
        }
    }
}

@MainActor
final class ReaderSettingsViewController: UIViewController {
    private let model: ReaderViewModel
    private var latestPreferences: ReaderPreferences
    private var latestSystemBrightness: Double
    private var latestIsDarkAppearance: Bool
    private var latestReduceMotion: Bool

    private var readerSettingsGlassEnabled: Bool {
        UserDefaults.standard.object(
            forKey: NagiAppearanceSettings.readerSettingsUseLiquidGlassKey
        ) as? Bool ?? true
    }

    var onCustomSettings: (() -> Void)?
    var onBeforeMutation: ((ReaderVisualMutationKind) -> Void)?
    var onSystemBrightnessChanged: ((Double) -> Void)?

    private let contentView = UIView()
    private let fontSizeStepperControl = ReaderFontSizeStepperControl()
    private let transitionControl = GlassControlView()
    private let appearanceControl = GlassControlView()
    private let presetControlGroup = GlassControlGroup<ReaderSettingsControlID>(spacing: 10)
    private let customControl = GlassControlView()
    private let brightnessSlider = UISlider()
    private let minimumBrightnessImageView = UIImageView()
    private let maximumBrightnessImageView = UIImageView()
    private let indicatorView = UIView()
    private let indicatorDots: [UIView] = (0 ..< ReaderFontSize.indicatorCount).map { _ in UIView() }
    private var indicatorHideTask: Task<Void, Never>?
    private var deferredMutationTask: Task<Void, Never>?
    private var pendingMutations: [PendingReaderMutation] = []

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
        deferredMutationTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .clear

        contentView.backgroundColor = .clear
        contentView.isOpaque = false
        view.addSubview(contentView)

        indicatorView.alpha = 0
        indicatorView.isUserInteractionEnabled = false
        indicatorView.accessibilityElementsHidden = true

        contentView.addSubview(fontSizeStepperControl)
        contentView.addSubview(transitionControl)
        contentView.addSubview(appearanceControl)
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

        configurePersistentControls()
        updateAllControls()
    }

    func update(
        preferences: ReaderPreferences,
        systemBrightness: Double,
        isDarkAppearance: Bool,
        reduceMotion: Bool
    ) {
        let previousPreferences = latestPreferences
        let previousBrightness = latestSystemBrightness
        let previousIsDarkAppearance = latestIsDarkAppearance
        let previousReduceMotion = latestReduceMotion

        latestPreferences = preferences
        latestSystemBrightness = min(max(systemBrightness, 0), 1)
        latestIsDarkAppearance = isDarkAppearance
        latestReduceMotion = reduceMotion
        guard isViewLoaded else { return }

        if previousReduceMotion != reduceMotion {
            updateFontControls()
            updateTransitionControl()
            updateAppearanceControl()
            updateThemeControls()
            updateCustomControl()
        } else {
            if previousPreferences.fontSize != preferences.fontSize {
                updateFontControls()
            }
            if previousPreferences.pageTransition != preferences.pageTransition {
                updateTransitionControl()
            }
            if previousPreferences.appearanceMode != preferences.appearanceMode {
                updateAppearanceControl()
            }
            if previousPreferences.themePreset != preferences.themePreset
                || previousIsDarkAppearance != isDarkAppearance {
                updateThemeControls()
            }
        }

        if abs(previousBrightness - latestSystemBrightness) > 0.0001 {
            updateBrightness()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        contentView.frame = view.bounds
        let width = max(0, view.bounds.width - Layout.horizontalInset * 2)
        let fontGroupWidth = max(0, width - 116)
        let topY = Layout.topY
        let topHeight = Layout.topHeight

        fontSizeStepperControl.frame = CGRect(
            x: Layout.horizontalInset,
            y: topY,
            width: fontGroupWidth,
            height: topHeight
        )
        transitionControl.frame = CGRect(
            x: Layout.horizontalInset + fontGroupWidth + 10,
            y: topY,
            width: 48,
            height: topHeight
        )
        appearanceControl.frame = CGRect(
            x: Layout.horizontalInset + fontGroupWidth + 68,
            y: topY,
            width: 48,
            height: topHeight
        )

        indicatorView.frame = CGRect(
            x: Layout.horizontalInset,
            y: Layout.indicatorY,
            width: fontGroupWidth,
            height: 8
        )
        layoutIndicatorDots()

        minimumBrightnessImageView.frame = CGRect(
            x: Layout.horizontalInset + 4,
            y: Layout.brightnessY,
            width: 20,
            height: Layout.brightnessHeight
        )
        maximumBrightnessImageView.frame = CGRect(
            x: Layout.horizontalInset + width - 24,
            y: Layout.brightnessY,
            width: 20,
            height: Layout.brightnessHeight
        )
        brightnessSlider.frame = CGRect(
            x: Layout.horizontalInset + 36,
            y: Layout.brightnessY,
            width: max(0, width - 72),
            height: Layout.brightnessHeight
        )

        presetControlGroup.frame = CGRect(
            x: Layout.horizontalInset,
            y: Layout.presetY,
            width: width,
            height: Layout.presetHeight
        )
        let presetWidth = max(0, (width - 20) / 3)
        presetControlGroup.setItemFrames([
            .original: CGRect(x: 0, y: 0, width: presetWidth, height: Layout.presetHeight),
            .quiet: CGRect(
                x: presetWidth + 10,
                y: 0,
                width: presetWidth,
                height: Layout.presetHeight
            ),
            .paper: CGRect(
                x: (presetWidth + 10) * 2,
                y: 0,
                width: presetWidth,
                height: Layout.presetHeight
            )
        ])

        customControl.frame = CGRect(
            x: Layout.horizontalInset,
            y: Layout.customY,
            width: width,
            height: Layout.customHeight
        )
    }

    private enum Layout {
        static let horizontalInset: CGFloat = 18
        static let topY: CGFloat = 8
        static let topHeight: CGFloat = 44
        static let indicatorY: CGFloat = 58
        static let brightnessY: CGFloat = 84
        static let brightnessHeight: CGFloat = 44
        static let presetY: CGFloat = 142
        static let presetHeight: CGFloat = 208
        static let customY: CGFloat = 368
        static let customHeight: CGFloat = 48
    }

    private enum IconMetrics {
        static let fontSmaller: CGFloat = 18
        static let fontLarger: CGFloat = 27
        static let topTransition: CGFloat = 23
        static let topAppearance: CGFloat = 23
        static let menuTransition: CGFloat = 20
        static let menuAppearance: CGFloat = 20
    }

    private var accentColor: UIColor {
        UIColor(named: "AccentColor") ?? .systemBlue
    }

    private func symbolConfiguration(pointSize: CGFloat) -> UIImage.SymbolConfiguration {
        UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    }

    private func configurePersistentControls() {
        fontSizeStepperControl.onDecrease = { [weak self] in
            self?.adjustFontSize(by: -1)
        }
        fontSizeStepperControl.onIncrease = { [weak self] in
            self?.adjustFontSize(by: 1)
        }

        transitionControl.accessibilityLabel = "翻页方式"
        appearanceControl.accessibilityLabel = "外观模式"

        presetControlGroup.update(items: ReaderThemePreset.allCases.map { preset in
            .init(
                id: controlID(for: preset),
                image: nil,
                accessibilityLabel: "主题预设：\(preset.label)",
                tintColor: nil,
                title: preset.label,
                cornerRadius: 18,
                usesGlass: readerSettingsGlassEnabled,
                action: { [weak self] in self?.select(preset: preset) }
            )
        })
        presetControlGroup.accessibilityLabel = "主题预设"
        customControl.accessibilityHint = "打开更多文字与布局选项"
    }

    private func updateAllControls() {
        updateFontControls()
        updateTransitionControl()
        updateAppearanceControl()
        updateThemeControls()
        updateCustomControl()
        updateBrightness()
    }

    private func updateFontControls() {
        let currentFontIndex = fontSizeIndex(for: latestPreferences.fontSize)
        let smallerIndex = max(0, currentFontIndex - 1)
        let largerIndex = min(ReaderFontSize.indicatorCount - 1, currentFontIndex + 1)
        let accessibilityValue = "当前字号 \(Int(latestPreferences.fontSize.rounded())) 磅"

        fontSizeStepperControl.update(
            isSmallerEnabled: smallerIndex != currentFontIndex,
            isLargerEnabled: largerIndex != currentFontIndex,
            smallerPointSize: IconMetrics.fontSmaller,
            largerPointSize: IconMetrics.fontLarger,
            tintColor: accentColor,
            accessibilityValue: accessibilityValue,
            usesGlass: readerSettingsGlassEnabled
        )

        for (index, dot) in indicatorDots.enumerated() {
            dot.backgroundColor = index <= currentFontIndex
                ? accentColor
                : UIColor.secondaryLabel.withAlphaComponent(0.22)
        }
    }

    private func updateTransitionControl() {
        let transition = latestPreferences.pageTransition
        transitionControl.update(
            image: UIImage(
                systemName: transition.systemImage,
                withConfiguration: symbolConfiguration(
                    pointSize: IconMetrics.topTransition
                )
            ),
            accessibilityLabel: "翻页方式",
            tintColor: .label,
            isEnabled: true,
            reduceMotion: latestReduceMotion,
            usesGlass: readerSettingsGlassEnabled
        )
        transitionControl.accessibilityValue = transition.label
        transitionControl.setPrimaryMenu(UIMenu(
            title: "翻页方式",
            children: ReaderPageTransition.allCases.map { option in
                UIAction(
                    title: option.label,
                    image: UIImage(
                        systemName: option.systemImage,
                        withConfiguration: symbolConfiguration(
                            pointSize: IconMetrics.menuTransition
                        )
                    ),
                    state: option == transition ? .on : .off
                ) { [weak self] _ in
                    self?.select(transition: option)
                }
            }
        ))
    }

    private func updateAppearanceControl() {
        let appearance = latestPreferences.appearanceMode
        appearanceControl.update(
            image: UIImage(
                systemName: appearance.systemImage,
                withConfiguration: symbolConfiguration(
                    pointSize: IconMetrics.topAppearance
                )
            ),
            accessibilityLabel: "外观模式",
            tintColor: .label,
            isEnabled: true,
            reduceMotion: latestReduceMotion,
            usesGlass: readerSettingsGlassEnabled
        )
        appearanceControl.accessibilityValue = appearance.label
        appearanceControl.setPrimaryMenu(UIMenu(
            title: "外观模式",
            children: ReaderAppearanceMode.allCases.map { option in
                UIAction(
                    title: option.label,
                    image: UIImage(
                        systemName: option.systemImage,
                        withConfiguration: symbolConfiguration(
                            pointSize: IconMetrics.menuAppearance
                        )
                    ),
                    state: option == appearance ? .on : .off
                ) { [weak self] _ in
                    self?.select(appearance: option)
                }
            }
        ))
    }

    private func updateThemeControls() {
        for preset in ReaderThemePreset.allCases {
            let isSelected = latestPreferences.themePreset == preset
            let theme = preset.paletteTheme
            let background = theme.readerBackgroundUIColor(
                isDarkAppearance: latestIsDarkAppearance
            )
            let content = isSelected
                ? accentColor
                : theme.readerContentUIColor(isDarkAppearance: latestIsDarkAppearance)
            presetControlGroup.control(for: controlID(for: preset))?.update(
                image: nil,
                accessibilityLabel: "主题预设：\(preset.label)",
                tintColor: nil,
                isEnabled: true,
                reduceMotion: latestReduceMotion,
                title: preset.label,
                isSelected: isSelected,
                cornerRadius: 18,
                contentColor: content,
                fillColor: background,
                usesGlass: readerSettingsGlassEnabled
            )
        }
    }

    private func updateCustomControl() {
        customControl.update(
            image: UIImage(systemName: "gear"),
            accessibilityLabel: "自定义",
            tintColor: nil,
            isEnabled: true,
            reduceMotion: latestReduceMotion,
            title: "自定义",
            cornerRadius: 24,
            contentColor: accentColor,
            usesGlass: readerSettingsGlassEnabled
        )
    }

    private func updateBrightness() {
        let brightness = Float(min(max(latestSystemBrightness, 0), 1))
        if abs(brightnessSlider.value - brightness) > 0.0001 {
            brightnessSlider.setValue(brightness, animated: false)
        }
        brightnessSlider.accessibilityValue = "\(Int(Double(brightness) * 100))%"
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

    private func adjustFontSize(by step: Int) {
        guard ReaderFontSize.indicatorCount > 0 else { return }
        let currentIndex = fontSizeIndex(for: model.preferences.fontSize)
        let targetIndex = min(
            max(currentIndex + step, 0),
            ReaderFontSize.indicatorCount - 1
        )
        guard targetIndex != currentIndex else { return }
        enqueueMutation(.fontStep(step))
    }

    private func select(preset: ReaderThemePreset) {
        guard model.preferences.themePreset != preset else { return }
        enqueueMutation(.preset(preset))
    }

    private func select(transition: ReaderPageTransition) {
        guard model.preferences.pageTransition != transition else { return }
        enqueueMutation(.transition(transition))
    }

    private func select(appearance: ReaderAppearanceMode) {
        guard model.preferences.appearanceMode != appearance else { return }
        enqueueMutation(.appearance(appearance))
    }

    private func enqueueMutation(_ mutation: PendingReaderMutation) {
        switch mutation {
        case .fontStep(let step):
            var combinedStep = step
            pendingMutations.removeAll { pending in
                guard case .fontStep(let pendingStep) = pending else { return false }
                combinedStep += pendingStep
                return true
            }
            if combinedStep != 0 {
                pendingMutations.append(.fontStep(combinedStep))
            }

        case .preset:
            pendingMutations.removeAll {
                if case .preset = $0 { return true }
                return false
            }
            pendingMutations.append(mutation)

        case .transition:
            pendingMutations.removeAll {
                if case .transition = $0 { return true }
                return false
            }
            pendingMutations.append(mutation)

        case .appearance:
            pendingMutations.removeAll {
                if case .appearance = $0 { return true }
                return false
            }
            pendingMutations.append(mutation)
        }
        guard deferredMutationTask == nil else { return }

        deferredMutationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }

            let mutations = self.pendingMutations
            self.pendingMutations.removeAll(keepingCapacity: true)
            self.deferredMutationTask = nil
            guard !mutations.isEmpty else { return }

            let mutationKind = mutations
                .dropFirst()
                .reduce(mutations[0].visualMutationKind) {
                    $0.merged(with: $1.visualMutationKind)
                }
            self.onBeforeMutation?(mutationKind)
            for mutation in mutations {
                self.apply(mutation)
            }
        }
    }

    private func apply(_ mutation: PendingReaderMutation) {
        let previousPreferences = model.preferences

        switch mutation {
        case .fontStep(let step):
            let currentIndex = fontSizeIndex(for: model.preferences.fontSize)
            let targetIndex = min(
                max(currentIndex + step, 0),
                ReaderFontSize.indicatorCount - 1
            )
            guard targetIndex != currentIndex else { return }
            let size = ReaderFontSize.minimum + Double(targetIndex) * ReaderFontSize.step
            model.setFontSize(size)
            showFontSizeIndicator()

        case .preset(let preset):
            guard model.preferences.themePreset != preset else { return }
            model.selectPreset(preset)

        case .transition(let transition):
            guard model.preferences.pageTransition != transition else { return }
            model.setPageTransition(transition)

        case .appearance(let appearance):
            guard model.preferences.appearanceMode != appearance else { return }
            model.setAppearance(appearance)
        }

        latestPreferences = model.preferences
        updateChangedPreferenceControls(from: previousPreferences)
    }

    private func updateChangedPreferenceControls(from previous: ReaderPreferences) {
        if previous.fontSize != latestPreferences.fontSize {
            updateFontControls()
        }
        if previous.pageTransition != latestPreferences.pageTransition {
            updateTransitionControl()
        }
        if previous.appearanceMode != latestPreferences.appearanceMode {
            updateAppearanceControl()
        }
        if previous.themePreset != latestPreferences.themePreset {
            updateThemeControls()
        }
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
    let onBeforeMutation: (ReaderVisualMutationKind) -> Void
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
