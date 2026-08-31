//
//  ReaderSettingsView.swift
//  Nagi
//
//  TXT / EPUB 共用的主题与排版设置。即时设置直接应用，详细排版设置使用草稿。
//

import SwiftUI
import UIKit

struct MediumReaderSettingsView: View {
    let model: ReaderViewModel
    let onCustomSettings: () -> Void
    let onBeforeThemeChange: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var systemBrightness: Double
    @State private var showFontSizeIndicator = false
    @State private var fontSizeIndicatorToken = 0

#if DEBUG || NAGI_FONT_DIAGNOSTICS
    @State private var showFontDiagnostics = false
#endif

    init(
        model: ReaderViewModel,
        systemBrightness: Binding<Double>,
        onCustomSettings: @escaping () -> Void,
        onBeforeThemeChange: @escaping () -> Void = {}
    ) {
        self.model = model
        self._systemBrightness = systemBrightness
        self.onCustomSettings = onCustomSettings
        self.onBeforeThemeChange = onBeforeThemeChange
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                topControls

                brightnessControl
                presetCards
                customButton

#if DEBUG || NAGI_FONT_DIAGNOSTICS
                fontDiagnosticsButton
#endif
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 22)
        }
        .scrollIndicators(.hidden)

#if DEBUG || NAGI_FONT_DIAGNOSTICS
        .sheet(isPresented: $showFontDiagnostics) {
            FontDiagnosticsView(model: model)
        }
#endif
    }

#if DEBUG || NAGI_FONT_DIAGNOSTICS
    private var fontDiagnosticsButton: some View {
        Button {
            showFontDiagnostics = true
        } label: {
            Label("字体诊断", systemImage: "stethoscope")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
    }
#endif

    private var topControls: some View {
        HStack(spacing: 10) {
            fontSizeControlWithIndicator
                .frame(maxWidth: .infinity)
            transitionMenu
            appearanceMenu
        }
    }

    private var fontSizeControlWithIndicator: some View {
        ZStack(alignment: .bottom) {
            fontSizeControl

            if showFontSizeIndicator {
                fontSizeIndicator
                    .offset(y: 11)
                    .transition(.opacity)
                    .task(id: fontSizeIndicatorToken) {
                        do {
                            try await Task.sleep(nanoseconds: 1_000_000_000)
                        } catch {
                            return
                        }

                        guard !Task.isCancelled else { return }
                        if reduceMotion {
                            showFontSizeIndicator = false
                        } else {
                            withAnimation(.easeOut(duration: 0.15)) {
                                showFontSizeIndicator = false
                            }
                        }
                    }
            }
        }
    }

    private var fontSizeIndicator: some View {
        HStack(spacing: 4) {
            ForEach(0..<ReaderFontSize.indicatorCount, id: \.self) { index in
                Circle()
                    .fill(
                        index <= fontSizeIndicatorIndex
                            ? Color.accentColor
                            : Color.secondary.opacity(0.22)
                    )
                    .frame(width: 4, height: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var fontSizeIndicatorIndex: Int {
        let rawIndex = Int(
            ((model.preferences.fontSize - ReaderFontSize.minimum) / ReaderFontSize.step)
                .rounded()
        )
        return min(max(rawIndex, 0), ReaderFontSize.indicatorCount - 1)
    }

    private var fontSizeControl: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                fontSizeButton(
                    title: "小",
                    assetName: "readerFontSizeSmaller",
                    adjustment: -ReaderFontSize.step,
                    iconPointSize: 20
                )

                Divider()
                    .frame(height: 32)
                    .overlay(Color.primary.opacity(0.36))

                fontSizeButton(
                    title: "大",
                    assetName: "readerFontSizeLarger",
                    adjustment: ReaderFontSize.step,
                    iconPointSize: 28
                )
            }
            .frame(maxWidth: .infinity)
            .padding(4)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("字号")
        .accessibilityValue("当前字号 \(Int(model.preferences.fontSize.rounded())) 磅")
    }

    private func fontSizeButton(
        title: String,
        assetName: String,
        adjustment: Double,
        iconPointSize: CGFloat
    ) -> some View {
        let currentSize = model.preferences.fontSize
        let direction = adjustment < 0 ? -1 : 1
        let adjustedIndex = min(
            max(fontSizeIndicatorIndex + direction, 0),
            ReaderFontSize.indicatorCount - 1
        )
        let adjustedSize = ReaderFontSize.minimum
            + Double(adjustedIndex) * ReaderFontSize.step
        let canAdjust = adjustedIndex != fontSizeIndicatorIndex

        return Button {
            guard canAdjust else { return }
            model.setFontSize(adjustedSize)
            fontSizeIndicatorToken &+= 1
            if reduceMotion {
                showFontSizeIndicator = true
            } else {
                withAnimation(.easeIn(duration: 0.12)) {
                    showFontSizeIndicator = true
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(assetName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconPointSize, height: iconPointSize)
                    .foregroundStyle(.primary)

                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .disabled(!canAdjust)
        .opacity(canAdjust ? 1 : 0.45)
        .accessibilityLabel("字号\(title)")
        .accessibilityValue("当前字号 \(Int(currentSize.rounded())) 磅")
    }

    private var transitionMenu: some View {
        Menu {
            Picker("翻页方式", selection: model.binding(\ReaderPreferences.pageTransition)) {
                ForEach(ReaderPageTransition.allCases) { transition in
                    Label {
                        Text(transition.label)
                    } icon: {
                        Image(transition.assetName)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                            .foregroundStyle(.primary)
                    }
                        .tag(transition)
                }
            }
        } label: {
            Image(model.preferences.pageTransition.assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .frame(width: 48, height: 44)
        .contentShape(Rectangle())
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel("翻页方式")
        .accessibilityValue(model.preferences.pageTransition.label)
    }

    private var appearanceMenu: some View {
        Menu {
            Picker("外观模式", selection: appearanceSelection) {
                ForEach(ReaderAppearanceMode.allCases) { mode in
                    Label {
                        Text(mode.label)
                    } icon: {
                        appearanceIcon(for: mode, size: 22)
                    }
                    .tag(mode)
                }
            }
        } label: {
            appearanceIcon(for: model.preferences.appearanceMode, size: 28)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .frame(width: 48, height: 44)
        .contentShape(Rectangle())
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel("外观模式")
        .accessibilityValue(model.preferences.appearanceMode.label)
    }

    private var appearanceSelection: Binding<ReaderAppearanceMode> {
        Binding(
            get: { model.preferences.appearanceMode },
            set: { newValue in
                guard newValue != model.preferences.appearanceMode else { return }
                onBeforeThemeChange()
                model.setAppearance(newValue)
            }
        )
    }

    @ViewBuilder
    private func appearanceIcon(for mode: ReaderAppearanceMode, size: CGFloat) -> some View {
        if let assetName = mode.assetName {
            Image(assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.primary)
        } else {
            Image(systemName: mode.systemImage)
                .font(.system(size: size * 0.62, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: size, height: size)
                .foregroundStyle(.primary)
        }
    }

    private var brightnessControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.min.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: $systemBrightness, in: 0 ... 1, step: 0.01)
                .tint(.accentColor)
                .accessibilityLabel("系统亮度")
                .accessibilityValue("\(Int(systemBrightness * 100))%")
            Image(systemName: "sun.max.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
    }

    private var presetCards: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(ReaderThemePreset.allCases) { preset in
                    presetCard(preset)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("主题预设")
    }

    private func presetCard(_ preset: ReaderThemePreset) -> some View {
        let isSelected = model.preferences.themePreset == preset
        let cardColor = preset.backgroundColor(isDarkAppearance: isDarkAppearance)
        let cardShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        return Button {
            guard model.preferences.themePreset != preset else { return }
            onBeforeThemeChange()
            model.selectPreset(preset)
        } label: {
            ZStack(alignment: .topTrailing) {
                Text(preset.label)
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 12)

                Text("*")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(
                        preset.contentColor(isDarkAppearance: isDarkAppearance)
                            .opacity(0.68)
                    )
                    .padding(.top, 10)
                    .padding(.trailing, 12)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(
                isSelected
                    ? Color.accentColor
                    : preset.contentColor(isDarkAppearance: isDarkAppearance)
            )
            .padding(.vertical, 7)
            // 三列卡片继续沿用原三列两行预设网格的比例，并向下延伸一些。
            .frame(maxWidth: .infinity, minHeight: ReaderControlValues.presetGridHeight)
            .overlay {
                if isSelected {
                    cardShape
                        .stroke(Color.accentColor.opacity(0.85), lineWidth: 2)
                }
            }
            .contentShape(cardShape)
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular
                .tint(cardColor)
                .interactive(),
            in: cardShape
        )
        .contentShape(cardShape)
        .accessibilityLabel("主题预设：\(preset.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var customButton: some View {
        Button(action: onCustomSettings) {
            Label("自定义", systemImage: "gear")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .glassEffect(
            .regular.interactive(),
            in: Capsule()
        )
        .contentShape(Capsule())
        .accessibilityHint("打开更多文字与布局选项")
    }

    private var isDarkAppearance: Bool {
        switch model.preferences.appearanceMode {
        case .light:
            return false
        case .dark:
            return true
        case .system:
            return colorScheme == .dark
        }
    }

    private enum ReaderControlValues {
        static let presetGridHeight: CGFloat = 208
    }
}

struct CustomReaderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialDraft: ReaderCustomizationDraft
    let previewText: String
    let previewChapterTitle: String
    let bookTitle: String
    let fontSize: Double
    let previewContentColor: UIColor
    let previewBackgroundColor: UIColor
    let isLoadingPreview: Bool
    let onCommit: (ReaderCustomizationDraft) -> Void

    @State private var draft: ReaderCustomizationDraft
    @State private var showDiscardConfirmation = false
    @State private var didFinish = false

    private enum Layout {
        static let previewHeight: CGFloat = 228
        static let previewMaskHeight: CGFloat = 32
        static let cardCornerRadius: CGFloat = 22
        static let rowHeight: CGFloat = 60
        static let cardHorizontalPadding: CGFloat = 20
        static let sliderValueWidth: CGFloat = 58
    }

    private enum LayoutSymbol {
        static let lineSpacing = ReaderSystemSymbol.name(
            "arrow.up.and.down.text.horizontal",
            fallback: "arrow.up.and.down"
        )
        static let characterSpacing = ReaderSystemSymbol.name(
            "textformat.abc",
            fallback: "character"
        )
        static let wordSpacing = ReaderSystemSymbol.name(
            "text.word.spacing",
            fallback: "text.alignleft"
        )
        static let pageMargins = ReaderSystemSymbol.name(
            "rectangle.portrait.inset.filled",
            fallback: "rectangle.portrait"
        )
    }

    // 朱自清《春》（1933）中的短段落，用于展示字体、行距和页边空白。
    private static let previewSampleText = """
    一切都像刚睡醒的样子，欣欣然张开了眼。山朗润起来了，水涨起来了，太阳的脸红起来了。

    小草偷偷地从土里钻出来，嫩嫩的，绿绿的。园子里，田野里，瞧去，一大片一大片满是的。风轻悄悄的，草软绵绵的。

    桃树、杏树、梨树，你不让我，我不让你，都开满了花赶趟儿。红的像火，粉的像霞，白的像雪。花里带着甜味；闭了眼，树上仿佛已经满是桃儿、杏儿、梨儿！
    """

    init(
        initialDraft: ReaderCustomizationDraft,
        previewText: String,
        previewChapterTitle: String,
        bookTitle: String,
        fontSize: Double,
        previewContentColor: UIColor,
        previewBackgroundColor: UIColor,
        isLoadingPreview: Bool,
        onCommit: @escaping (ReaderCustomizationDraft) -> Void
    ) {
        self.initialDraft = initialDraft
        self.previewText = previewText
        self.previewChapterTitle = previewChapterTitle
        self.bookTitle = bookTitle
        self.fontSize = fontSize
        self.previewContentColor = previewContentColor
        self.previewBackgroundColor = previewBackgroundColor
        self.isLoadingPreview = isLoadingPreview
        self.onCommit = onCommit
        _draft = State(initialValue: initialDraft)
    }

    private var isDirty: Bool { draft != initialDraft }

    private var nagiAccentColor: Color {
        Color("AccentColor")
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                ScrollView {
                    settingsContent
                        .padding(.horizontal, 16)
                        // Reserve the initial preview space, then let the cards
                        // scroll beneath the fixed preview overlay.
                        .padding(.top, Layout.previewHeight + 18)
                        .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)

                preview
                    .frame(maxWidth: .infinity)
                    .frame(height: Layout.previewHeight, alignment: .topLeading)
                    .background(Color(uiColor: previewBackgroundColor))
                    .overlay(alignment: .bottom) {
                        previewBottomMask
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color(uiColor: .separator))
                            .frame(height: 1)
                            .allowsHitTesting(false)
                    }
                    .clipped()
                    .allowsHitTesting(false)
                    .zIndex(1)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("自定义主题")
            .navigationBarTitleDisplayMode(.inline)
            // Keep the system navigation-bar surface continuous with the
            // fixed preview surface below it.
            .toolbarBackground(Color(uiColor: previewBackgroundColor), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(previewColorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: cancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("取消")
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: commit) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .glassEffect(
                        .regular
                            .tint(nagiAccentColor)
                            .interactive(),
                        in: Circle()
                    )
                    .accessibilityLabel("完成")
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isDirty && !didFinish)
        .confirmationDialog("放弃修改？", isPresented: $showDiscardConfirmation, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) {
                didFinish = true
                dismiss()
            }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("尚未保存的文字和布局调整将被丢弃。")
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            settingsSection("文本") {
                VStack(spacing: 0) {
                    fontMenu
                    cardDivider
                    Toggle(isOn: $draft.boldText) {
                        Label {
                            Text("粗体文本")
                        } icon: {
                            Image(systemName: "bold")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 24, height: 24)
                                .foregroundStyle(nagiAccentColor)
                        }
                        .font(.body)
                        .foregroundStyle(.primary)
                    }
                        .frame(maxWidth: .infinity, minHeight: Layout.rowHeight)
                        .padding(.horizontal, Layout.cardHorizontalPadding)
                        .contentShape(Rectangle())
                        .tint(nagiAccentColor)
                }
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                )
            }

            settingsSection("布局选项") {
                VStack(spacing: 0) {
                    Toggle("保留出版方样式", isOn: $draft.publisherStyles)
                        .frame(minHeight: Layout.rowHeight)
                        .padding(.horizontal, Layout.cardHorizontalPadding)
                        .contentShape(Rectangle())

                    cardDivider

                    slider(
                        "行间距",
                        systemImage: LayoutSymbol.lineSpacing,
                        value: $draft.lineHeight,
                        range: ReaderLayoutMetrics.lineHeightRange,
                        step: 0.05,
                        text: String(format: "%.2f", draft.lineHeight)
                    )

                    cardDivider

                    slider(
                        "字符间距",
                        systemImage: LayoutSymbol.characterSpacing,
                        value: $draft.characterSpacing,
                        range: ReaderLayoutMetrics.characterSpacingRange,
                        step: 1,
                        text: "\(Int(draft.characterSpacing))%"
                    )

                    cardDivider

                    slider(
                        "词间距",
                        systemImage: LayoutSymbol.wordSpacing,
                        value: $draft.wordSpacing,
                        range: ReaderLayoutMetrics.wordSpacingRange,
                        step: 2,
                        text: "\(Int(draft.wordSpacing))%"
                    )

                    cardDivider

                    slider(
                        "页边空白",
                        systemImage: LayoutSymbol.pageMargins,
                        value: $draft.pageMargins,
                        range: ReaderLayoutMetrics.pageMarginsRange,
                        step: ReaderLayoutMetrics.pageMarginsStep,
                        text: "\(Int(draft.pageMargins.rounded())) pt"
                    )
                }
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                )

                Text("正文上下留白由系统安全区和页眉实际占用决定；首行缩进固定为 2；页边空白按设置调节。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
        }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 12)

            content()
        }
    }

    private var cardDivider: some View {
        Divider()
            .padding(.leading, Layout.cardHorizontalPadding)
    }

    private var preview: some View {
        Text(Self.previewSampleText)
            .font(previewFont)
            .fontWeight(draft.boldText ? .bold : .regular)
            .kerning(ReaderLayoutMetrics.spacingPoints(for: draft.characterSpacing))
            .lineSpacing(CGFloat(draft.lineHeight - 1) * 8)
            .padding(.horizontal, previewPageMarginInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .foregroundStyle(Color(uiColor: previewContentColor))
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正文预览")
    }

    private var previewColorScheme: ColorScheme {
        var white: CGFloat = 0
        var alpha: CGFloat = 0
        if previewBackgroundColor.getWhite(&white, alpha: &alpha) {
            return white < 0.5 ? .dark : .light
        }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard previewBackgroundColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .light
        }

        let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
        return luminance < 0.5 ? .dark : .light
    }

    private var previewBottomMask: some View {
        LinearGradient(
            stops: [
                .init(color: Color(uiColor: previewBackgroundColor), location: 0),
                .init(color: Color(uiColor: previewBackgroundColor).opacity(0.92), location: 0.55),
                .init(color: Color(uiColor: previewBackgroundColor).opacity(0), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: Layout.previewMaskHeight)
        .allowsHitTesting(false)
    }

    private var previewPageMarginInset: CGFloat {
        max(ReaderLayoutMetrics.pageBlankInset(for: draft.pageMargins) - 16, 0)
    }

    private var previewFont: Font {
        let size = CGFloat(min(max(fontSize, 8), 42))
        return draft.fontFamily.swiftUIFont(ofSize: size)
    }

    private var fontMenu: some View {
        Menu {
            ForEach(ReaderFontFamily.options) { family in
                Button {
                    draft.fontFamily = family
                } label: {
                    HStack(spacing: 10) {
                        Text(family.label)
                            .font(family.swiftUIFont(ofSize: 17))
                        Spacer(minLength: 16)
                        Image(systemName: family == draft.fontFamily ? "checkmark" : "textformat")
                            .font(.body.weight(.semibold))
                    }
                }
                .accessibilityLabel(family.label)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "textformat")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(nagiAccentColor)
                    .accessibilityHidden(true)

                Text("字体")
                    .font(.body)
                    .foregroundStyle(.primary)

                Spacer()
                Text(draft.fontFamily.label)
                    .font(draft.fontFamily.swiftUIFont(ofSize: 16))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: Layout.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .padding(.horizontal, Layout.cardHorizontalPadding)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityLabel("字体")
        .accessibilityValue(draft.fontFamily.label)
    }

    private func slider(
        _ title: String,
        systemImage: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        text: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                Spacer()
            }
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 28, height: 24)
                    .foregroundStyle(nagiAccentColor)
                    .accessibilityHidden(true)

                Slider(value: value, in: range, step: step)
                    .tint(nagiAccentColor)

                Text(text)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: Layout.sliderValueWidth, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Layout.cardHorizontalPadding)
        .padding(.vertical, 18)
    }

    private func cancel() {
        guard isDirty else {
            didFinish = true
            dismiss()
            return
        }
        showDiscardConfirmation = true
    }

    private func commit() {
        didFinish = true
        onCommit(draft)
        dismiss()
    }
}

#if DEBUG || NAGI_FONT_DIAGNOSTICS
private struct FontDiagnosticsView: View {
    let model: ReaderViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let diagnostics = model.fontDiagnostics {
                        diagnosticsContent(diagnostics)
                    } else {
                        ContentUnavailableView(
                            "尚未读取正文状态",
                            systemImage: "text.magnifyingglass",
                            description: Text("点击刷新，读取当前可见 EPUB 正文的 WebView 状态。")
                        )
                    }

                    Button {
                        Task { await refresh() }
                    } label: {
                        Label(
                            isRefreshing ? "正在读取…" : "刷新诊断",
                            systemImage: "arrow.clockwise"
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRefreshing)
                }
                .padding(20)
            }
            .navigationTitle("字体诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task {
            await refresh()
        }
    }

    @ViewBuilder
    private func diagnosticsContent(_ diagnostics: ReaderFontDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            diagnosticRow("App 当前选择", diagnostics.appSelection)
            diagnosticRow("UIKit 字体探针", diagnostics.nativeFontFace)
            diagnosticRow("Readium 当前设置", diagnostics.readiumPreference)
            diagnosticRow("CSS 目标族", diagnostics.requestedCSSFamily)
            diagnosticRow("Root CSS 变量", diagnostics.rootCSSFamily)
            diagnosticRow("CSS Body", diagnostics.bodyFontFamily)
            diagnosticRow(
                "正文元素",
                diagnostics.elementFontFamily,
                detail: diagnostics.elementTag.isEmpty ? nil : diagnostics.elementTag
            )
            diagnosticRow("覆盖脚本", diagnostics.overridePresent ? "已存在" : "不存在")
            diagnosticRow("文档状态", diagnostics.readyState)
            diagnosticRow("字体面数量", diagnostics.fontFaceCount.map(String.init) ?? "未知")
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

        diagnosticBlock("UIKit Family / Face 扫描", diagnostics.nativeFamilyReport)

        VStack(alignment: .leading, spacing: 0) {
            Text("WebKit Font Check")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            ForEach(diagnostics.fontChecks.keys.sorted(), id: \.self) { family in
                HStack(spacing: 12) {
                    Text(family)
                        .font(.footnote.monospaced())
                    Spacer(minLength: 12)
                    checkValue(diagnostics.fontChecks[family] ?? nil)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

        diagnosticBlock(
            "EPUB Publisher CSS font-family",
            diagnostics.publisherFontRuleReport
        )

        if let errorMessage = diagnostics.errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("说明")
                .font(.headline)
            Text("computedStyle 显示的是 CSS 请求值，不等于最终字形来源；Font Check 用于确认当前 WebView 是否接受该系统字体。此面板只读取当前可见资源，不修改正文样式。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !diagnostics.resourceURL.isEmpty {
                Text(diagnostics.resourceURL)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func diagnosticBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(value.isEmpty ? "—" : value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func diagnosticRow(_ title: String, _ value: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value.isEmpty ? "—" : value)
                    .font(.footnote.monospaced())
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                if let detail {
                    Text(detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func checkValue(_ value: Bool?) -> some View {
        switch value {
        case .some(true):
            Text("true")
                .foregroundStyle(.green)
                .font(.footnote.monospaced())
        case .some(false):
            Text("false")
                .foregroundStyle(.red)
                .font(.footnote.monospaced())
        case .none:
            Text("unknown")
                .foregroundStyle(.secondary)
                .font(.footnote.monospaced())
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await model.refreshFontDiagnostics()
        isRefreshing = false
    }
}
#endif
