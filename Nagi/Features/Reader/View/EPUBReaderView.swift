
import Foundation
import SwiftUI
import SwiftData

struct EPUBReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @State private var model: EPUBReaderModel
    @State private var showControls = true
    @State private var showSettings = false
    @State private var showCustomSettings = false
    @State private var customDraft: EPUBReaderDraft?
    @State private var showTableOfContents = false

    init(book: Book) {
        _model = State(initialValue: EPUBReaderModel(book: book))
    }

    var body: some View {
        ZStack {
            content
                .ignoresSafeArea()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.showBookTitleInPageHeader {
                pageHeader
            }
        }
        .overlay(alignment: .topTrailing) {
            if showControls {
                topTrailingBar
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if showControls {
                bottomBar
                    .transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task {
            model.updateSystemAppearance(isDark: colorScheme == .dark)
            model.onToggleControls = toggleControls
            model.onSwipeStart = hideControlsForSwipe
            await model.loadIfNeeded()
        }
        .onChange(of: colorScheme) { _, newColorScheme in
            model.updateSystemAppearance(isDark: newColorScheme == .dark)
        }
        .onDisappear {
            model.onToggleControls = nil
            model.onSwipeStart = nil
            model.flushReadingProgress()
            try? modelContext.save()
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showTableOfContents) { tableOfContentsSheet }
        .alert(
            "阅读失败",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let navigator = model.navigator {
            ReadiumNavigatorView(
                navigator: navigator,
                background: Color(uiColor: model.readerBackgroundUIColor),
                isReflowable: model.isReflowable
            )
        } else if model.isLoading {
            ProgressView("正在打开 EPUB…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
        } else {
            VStack(spacing: 12) {
                ContentUnavailableView(
                    "无法显示内容",
                    systemImage: "book.closed",
                    description: Text(model.errorMessage ?? "EPUB 没有可阅读内容")
                )

                Button("重试") {
                    Task { await model.loadIfNeeded() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }


    private var pageHeader: some View {
        Text(model.title)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color(uiColor: model.readerContentUIColor))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
            .padding(.horizontal, 72)
            .padding(.bottom, 8)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel("页眉书名：\(model.title)")
    }

    private var exitButton: some View {
        controlButton(
            "退出阅读器",
            systemImage: "xmark",
            diameter: ReaderControlMetrics.exitDiameter,
            iconPointSize: ReaderControlMetrics.exitIconPointSize
        ) {
            dismiss()
        }
    }

    private var topTrailingBar: some View {
        exitButton
            .padding(.top, ReaderControlMetrics.exitTopInset)
            .padding(.trailing, ReaderControlMetrics.exitTrailingInset)
    }


    private var bottomBar: some View {
        GeometryReader { geometry in
            let cornerInsets = nagiWindowCornerInsets(for: geometry)
            let leadingCenter = bottomCornerCenter(
                cornerInsets.bottomLeading,
                in: geometry.size,
                isLeading: true
            )
            let trailingCenter = bottomCornerCenter(
                cornerInsets.bottomTrailing,
                in: geometry.size,
                isLeading: false
            )

            NagiGlassEffectContainer(spacing: 12) {
                ZStack {
                    controlButton("目录", systemImage: "list.bullet") {
                        showTableOfContents = true
                    }
                    .position(leadingCenter)

                    controlButton("主题与设置", systemImage: "textformat.size") {
                        showSettings = true
                    }
                    .position(trailingCenter)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bottomCornerCenter(
        _ cornerInset: CGSize,
        in size: CGSize,
        isLeading: Bool
    ) -> CGPoint {
        let horizontalDistance = cornerCenterDistance(cornerInset.width)
        let verticalDistance = cornerCenterDistance(cornerInset.height)
        let x = isLeading
            ? horizontalDistance
            : size.width - horizontalDistance
        let y = size.height - verticalDistance

        return CGPoint(x: x, y: y)
    }

    private func cornerCenterDistance(_ measuredInset: CGFloat) -> CGFloat {
        guard measuredInset > 0 else {
            return ReaderControlMetrics.fallbackCornerCenterInset
        }

        return max(ReaderControlMetrics.diameter / 2, measuredInset)
    }

    private func controlButton(
        _ label: String,
        systemImage: String,
        diameter: CGFloat = ReaderControlMetrics.diameter,
        iconPointSize: CGFloat = ReaderControlMetrics.iconPointSize,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconPointSize, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: diameter, height: diameter)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .nagiGlass(in: .circle, interactive: true)
        .accessibilityLabel(label)
    }


    private var settingsSheet: some View {
        NavigationStack {
            MediumReaderSettingsView(
                model: model,
                onCustomSettings: beginCustomSettings
            )
            .navigationTitle("主题与设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showSettings = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭主题与设置")
                }
            }
        }
        .sheet(isPresented: $showCustomSettings, onDismiss: { customDraft = nil }) {
            customSettingsSheet
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var customSettingsSheet: some View {
        if let customDraft {
            CustomReaderSettingsSheet(
                initialDraft: customDraft,
                previewText: model.previewText,
                previewChapterTitle: model.previewChapterTitle,
                bookTitle: model.title,
                fontScale: model.fontScale,
                previewContentColor: model.readerContentUIColor,
                previewBackgroundColor: model.readerBackgroundUIColor,
                isLoadingPreview: model.isLoadingPreview,
                onCommit: { draft in
                    model.apply(draft)
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private func beginCustomSettings() {
        customDraft = model.makeDraft()
        showCustomSettings = true
    }

    private var tableOfContentsSheet: some View {
        NavigationStack {
            Group {
                if model.tableOfContents.isEmpty {
                    ContentUnavailableView("没有目录", systemImage: "list.bullet")
                } else {
                    ScrollViewReader { proxy in
                        List(model.tableOfContents) { entry in
                            tocRow(entry)
                                .id(entry.id)
                        }
                        .task(id: model.currentTOCEntryID) {
                            guard let currentID = model.currentTOCEntryID else { return }
                            await Task.yield()
                            proxy.scrollTo(currentID, anchor: .center)
                        }
                    }
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showTableOfContents = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func tocRow(_ entry: EPUBTOCEntry) -> some View {
        let isCurrent = model.isCurrent(entry)

        return Button {
            model.go(to: entry)
            showTableOfContents = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bookmark.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .opacity(isCurrent ? 1 : 0)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)

                Text(entry.title)
                    .foregroundStyle(.primary)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(entry.depth) * 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCurrent ? "\(entry.title)，当前阅读章节" : entry.title)
    }

    private func toggleControls() {
        if reduceMotion {
            showControls.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                showControls.toggle()
            }
        }
    }

    private func hideControlsForSwipe() {
        guard showControls else { return }

        if reduceMotion {
            showControls = false
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                showControls = false
            }
        }
    }

    private enum ReaderControlMetrics {
        static let diameter: CGFloat = 44
        static let iconPointSize: CGFloat = 18
        static let exitDiameter: CGFloat = 48
        static let exitIconPointSize: CGFloat = 20
        static let exitTopInset: CGFloat = 0
        static let exitTrailingInset: CGFloat = 12
        static let fallbackCornerCenterInset: CGFloat = 44
    }
}

private struct MediumReaderSettingsView: View {
    @Bindable private var model: EPUBReaderModel
    @AppStorage(NagiAppearanceSettings.readerSettingsUseLiquidGlassKey)
    private var readerSettingsUseLiquidGlass = true

    let onCustomSettings: () -> Void

    init(model: EPUBReaderModel, onCustomSettings: @escaping () -> Void) {
        _model = Bindable(wrappedValue: model)
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
            fontSizeControl
                .layoutPriority(1)

            Spacer(minLength: 0)

            pageTransitionMenu
            appearanceMenu
        }
    }

    private var fontSizeControl: some View {
        NagiGlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                fontSizeButton(
                    title: "小",
                    assetName: "readerFontSizeSmaller",
                    iconPointSize: 20,
                    scale: ReaderControlValues.smallFontScale
                )

                Divider()
                    .frame(height: 24)
                    .opacity(0.5)

                fontSizeButton(
                    title: "大",
                    assetName: "readerFontSizeLarger",
                    iconPointSize: 28,
                    scale: ReaderControlValues.largeFontScale
                )
            }
            .padding(4)
            .nagiGlass(
                in: Capsule(),
                interactive: true,
                enabled: readerSettingsUseLiquidGlass
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("字号")
        .accessibilityValue(model.fontScale >= ReaderControlValues.largeFontScale ? "大" : "小")
    }

    private func fontSizeButton(
        title: String,
        assetName: String,
        iconPointSize: CGFloat,
        scale: Double
    ) -> some View {
        let isSelected = abs(model.fontScale - scale) < 0.01

        return Button {
            model.setFontScale(scale)
        } label: {
            HStack(spacing: 8) {
                Image(assetName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconPointSize, height: iconPointSize)
            }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color("AccentColor"))
                .frame(minWidth: 62, minHeight: 40)
                .background(
                    isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("字号\(title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var pageTransitionMenu: some View {
        Menu {
            Picker(
                "翻页方式",
                selection: Binding(
                    get: { model.pageTransition },
                    set: { model.selectPageTransition($0) }
                )
            ) {
                ForEach(EPUBPageTransitionMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
        } label: {
            Image(systemName: model.pageTransition.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 44, height: 44)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .nagiGlass(
            in: Circle(),
            interactive: true,
            enabled: readerSettingsUseLiquidGlass
        )
        .accessibilityLabel("翻页方式")
        .accessibilityValue(model.pageTransition.label)
    }

    private var appearanceMenu: some View {
        Menu {
            Picker(
                "外观模式",
                selection: Binding(
                    get: { model.appearanceMode },
                    set: { model.selectAppearance($0) }
                )
            ) {
                ForEach(EPUBAppearanceMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
        } label: {
            Image(systemName: model.appearanceMode.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 44, height: 44)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .nagiGlass(
            in: Circle(),
            interactive: true,
            enabled: readerSettingsUseLiquidGlass
        )
        .accessibilityLabel("外观模式")
        .accessibilityValue(model.appearanceMode.label)
    }

    private var brightnessControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.min")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Slider(value: $model.brightness, in: 0.25 ... 1.0, step: 0.01)
                .tint(.accentColor)
                .accessibilityLabel("阅读亮度")
                .accessibilityValue("\(Int(model.brightness * 100))%")

            Image(systemName: "sun.max.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
    }

    private var presetCards: some View {
        NagiGlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(EPUBReaderPreset.allCases) { preset in
                    presetCard(preset)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("主题预设")
    }

    private func presetCard(_ preset: EPUBReaderPreset) -> some View {
        let isSelected = model.selectedPreset == preset

        return Button {
            model.apply(preset: preset)
        } label: {
            VStack(spacing: 7) {
                Image(systemName: preset.systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .symbolRenderingMode(.hierarchical)

                Text(preset.label)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 72)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .nagiGlass(
            in: RoundedRectangle(cornerRadius: 18, style: .continuous),
            interactive: true,
            enabled: readerSettingsUseLiquidGlass
        )
        .accessibilityLabel("主题预设：\(preset.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var customButton: some View {
        Button(action: onCustomSettings) {
            Label("自定义", systemImage: "slider.horizontal.3")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.plain)
        .nagiGlass(
            in: RoundedRectangle(cornerRadius: 18, style: .continuous),
            interactive: true,
            enabled: readerSettingsUseLiquidGlass
        )
        .accessibilityHint("打开更多文字与布局选项")
    }

    private enum ReaderControlValues {
        static let smallFontScale = 0.9
        static let largeFontScale = 1.1
    }
}

private struct CustomReaderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NagiAppearanceSettings.readerSettingsUseLiquidGlassKey)
    private var readerSettingsUseLiquidGlass = true

    let initialDraft: EPUBReaderDraft
    let previewText: String
    let previewChapterTitle: String
    let bookTitle: String
    let fontScale: Double
    let previewContentColor: UIColor
    let previewBackgroundColor: UIColor
    let isLoadingPreview: Bool
    let onCommit: (EPUBReaderDraft) -> Void

    @State private var draft: EPUBReaderDraft
    @State private var showDiscardConfirmation = false
    @State private var didFinish = false

    init(
        initialDraft: EPUBReaderDraft,
        previewText: String,
        previewChapterTitle: String,
        bookTitle: String,
        fontScale: Double,
        previewContentColor: UIColor,
        previewBackgroundColor: UIColor,
        isLoadingPreview: Bool,
        onCommit: @escaping (EPUBReaderDraft) -> Void
    ) {
        self.initialDraft = initialDraft
        self.previewText = previewText
        self.previewChapterTitle = previewChapterTitle
        self.bookTitle = bookTitle
        self.fontScale = fontScale
        self.previewContentColor = previewContentColor
        self.previewBackgroundColor = previewBackgroundColor
        self.isLoadingPreview = isLoadingPreview
        self.onCommit = onCommit
        _draft = State(initialValue: initialDraft)
    }

    private var isDirty: Bool {
        draft != initialDraft
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                previewPanel

                Divider()
                    .padding(.top, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        textSection
                        layoutSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("自定义")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: cancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: commit)
                        .fontWeight(.semibold)
                }
            }
        }
        .interactiveDismissDisabled(isDirty && !didFinish)
        .confirmationDialog(
            "放弃修改？",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("放弃修改", role: .destructive) {
                didFinish = true
                dismiss()
            }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("尚未保存的文字和布局调整将被丢弃。")
        }
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("实时预览", systemImage: "eye")
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                Text(previewChapterTitle.isEmpty ? bookTitle : previewChapterTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Group {
                if isLoadingPreview && previewText.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在载入正文…")
                    }
                    .foregroundStyle(.secondary)
                } else if previewText.isEmpty {
                    Text("暂时无法载入正文预览")
                        .foregroundStyle(.secondary)
                } else {
                    previewParagraphs
                }
            }
            .font(previewFont)
            .fontWeight(draft.boldText ? .bold : .regular)
            .foregroundStyle(Color(uiColor: previewContentColor))
            .kerning(ReaderLayoutMetrics.spacingPoints(for: draft.characterSpacing))
            .lineSpacing(CGFloat(draft.lineHeight - 1.0) * 8)
            .padding(.horizontal, previewHorizontalPadding)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 184, maxHeight: 184, alignment: .top)
        .background(Color(uiColor: previewBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正文实时预览")
    }

    private var previewHorizontalPadding: CGFloat {
        max(ReaderLayoutMetrics.pageBlankInset(for: draft.pageMargins) - 16, 0)
    }

    @ViewBuilder
    private var previewParagraphs: some View {
        let paragraphs = previewText
            .components(separatedBy: "\n\n")
            .filter { !$0.isEmpty }
            .prefix(5)
        let indent = String(
            repeating: "　",
            count: Int(ReaderLayoutMetrics.fixedParagraphIndent.rounded())
        )

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(indent + paragraph)
            }
        }
    }

    private var previewFont: Font {
        let size = CGFloat(
            ReaderFontSize.defaultValue * min(
                max(fontScale, ReaderFontSize.minimumScale),
                ReaderFontSize.maximumScale
            )
        )
        return draft.fontFamily.swiftUIFont(ofSize: size)
    }

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader("文本", systemImage: "textformat")

            VStack(spacing: 0) {
                fontMenuRow

                Divider()

                Toggle(isOn: $draft.boldText) {
                    Label("粗体文本", systemImage: "bold")
                }
                .frame(minHeight: 48)
            }
            .padding(.horizontal, 16)
            .nagiGlass(
                in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                enabled: readerSettingsUseLiquidGlass
            )

            Text("字号在上一级面板调整。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private var fontMenuRow: some View {
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
                Label("字体", systemImage: "textformat")

                Spacer(minLength: 8)

                Text(draft.fontFamily.label)
                    .font(draft.fontFamily.swiftUIFont(ofSize: 16))
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .accessibilityLabel("字体")
        .accessibilityValue(draft.fontFamily.label)
    }

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader("布局选项", systemImage: "rectangle")

            VStack(spacing: 0) {
                sliderRow(
                    title: "行间距",
                    systemImage: "line.3.horizontal",
                    value: $draft.lineHeight,
                    range: ReaderLayoutMetrics.lineHeightRange,
                    step: 0.05,
                    valueText: String(format: "%.2f", draft.lineHeight)
                )
                .disabled(draft.publisherStyles)

                Divider()

                sliderRow(
                    title: "页边空白",
                    systemImage: "arrow.left.and.right",
                    value: $draft.pageMargins,
                    range: ReaderLayoutMetrics.pageMarginsRange,
                    step: ReaderLayoutMetrics.pageMarginsStep,
                    valueText: "\(Int(draft.pageMargins.rounded())) pt"
                )

                Divider()

                sliderRow(
                    title: "字符间距",
                    systemImage: "character",
                    value: $draft.characterSpacing,
                    range: ReaderLayoutMetrics.characterSpacingRange,
                    step: 1,
                    valueText: "\(Int(draft.characterSpacing))%"
                )
                .disabled(draft.publisherStyles)

                Divider()

                sliderRow(
                    title: "词间距",
                    systemImage: "text.word.spacing",
                    value: $draft.wordSpacing,
                    range: ReaderLayoutMetrics.wordSpacingRange,
                    step: 2,
                    valueText: "\(Int(draft.wordSpacing))%"
                )
                .disabled(draft.publisherStyles)

                Divider()

                Toggle(isOn: $draft.publisherStyles) {
                    Label("出版方样式", systemImage: "building.columns")
                }
                .frame(minHeight: 52)
            }
            .padding(.horizontal, 16)
            .nagiGlass(
                in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                enabled: readerSettingsUseLiquidGlass
            )

            Text("正文上下留白由系统安全区、页眉和阅读控件动态决定；首行缩进固定为 2；页边空白为 16–48 pt，默认 24 pt。开启出版方样式后，部分自定义排版可能由书籍本身覆盖。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .padding(.horizontal, 4)
    }

    private func sliderRow(
        title: String,
        systemImage: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label(title, systemImage: systemImage)

                Spacer(minLength: 8)

                Text(valueText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: value, in: range, step: step)
                .tint(.accentColor)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .contain)
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
