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

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var systemBrightness: Double
    @State private var showFontSizeIndicator = false
    @State private var fontSizeIndicatorToken = 0

    init(
        model: ReaderViewModel,
        systemBrightness: Binding<Double>,
        onCustomSettings: @escaping () -> Void
    ) {
        self.model = model
        self._systemBrightness = systemBrightness
        self.onCustomSettings = onCustomSettings
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                topControls

                brightnessControl
                presetCards
                customButton
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 22)
        }
        .scrollIndicators(.hidden)
    }

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
                    systemImage: "textformat.size.smaller",
                    adjustment: -ReaderFontSize.step,
                    iconPointSize: 17
                )

                Divider()
                    .frame(height: 24)
                    .opacity(0.5)

                fontSizeButton(
                    title: "大",
                    systemImage: "textformat.size.larger",
                    adjustment: ReaderFontSize.step,
                    iconPointSize: 24
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
        systemImage: String,
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
                Image(systemName: systemImage)
                    .font(.system(size: iconPointSize, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)

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
                    Label(transition.label, systemImage: transition.systemImage)
                        .tag(transition)
                }
            }
        } label: {
            Image(systemName: model.preferences.pageTransition.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
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
            Picker("外观模式", selection: model.binding(\ReaderPreferences.appearanceMode)) {
                ForEach(ReaderAppearanceMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode)
                }
            }
        } label: {
            Image(systemName: model.preferences.appearanceMode.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    preview
                    fontMenu
                    Toggle("粗体文本", isOn: $draft.boldText)
                    slider("行间距", value: $draft.lineHeight, range: 1 ... 2, step: 0.1, text: String(format: "%.1f", draft.lineHeight))
                    slider("上边距", value: $draft.contentTopInset, range: 0 ... 160, step: 4, text: "\(Int(draft.contentTopInset)) pt")
                    slider("下边距", value: $draft.contentBottomInset, range: 0 ... 160, step: 4, text: "\(Int(draft.contentBottomInset)) pt")
                    slider("页边距", value: $draft.pageMargins, range: 0.5 ... 2, step: 0.1, text: String(format: "%.1f×", draft.pageMargins))
                    slider("首行缩进", value: $draft.paragraphIndent, range: 0 ... 3, step: 0.5, text: String(format: "%.1f em", draft.paragraphIndent))
                    Toggle("保留出版方样式", isOn: $draft.publisherStyles)
                }
                .padding(16)
            }
            .navigationTitle("自定义")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: commit).fontWeight(.semibold)
                }
            }
        }
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

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("实时预览", systemImage: "eye")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(previewChapterTitle.isEmpty ? bookTitle : previewChapterTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if isLoadingPreview && previewText.isEmpty {
                ProgressView("正在载入正文…")
            } else if previewText.isEmpty {
                Text("暂时无法载入正文预览").foregroundStyle(.secondary)
            } else {
                Text(previewText)
                    .font(previewFont)
                    .fontWeight(draft.boldText ? .bold : .regular)
                    .lineSpacing(max(0, CGFloat(draft.lineHeight - 1) * 8))
                    .lineLimit(7)
            }
        }
        .foregroundStyle(Color(uiColor: previewContentColor))
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(
            Color(uiColor: previewBackgroundColor),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
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
            HStack {
                Label("字体", systemImage: "textformat")
                Spacer()
                Text(draft.fontFamily.label)
                    .font(draft.fontFamily.swiftUIFont(ofSize: 16))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 48)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .accessibilityLabel("字体")
        .accessibilityValue(draft.fontFamily.label)
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        text: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(text).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step).tint(.accentColor)
        }
        .padding(.horizontal, 4)
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
