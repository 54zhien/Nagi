//
//  EPUBReaderView.swift
//  Seidoku
//
//  Readium EPUB 阅读界面：正文优先、Liquid Glass 控件和集中式排版设置。
//

import SwiftUI

struct EPUBReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: EPUBReaderModel
    @State private var showControls = true
    @State private var showSettings = false
    @State private var showTableOfContents = false

    init(book: Book) {
        _model = State(initialValue: EPUBReaderModel(book: book))
    }

    var body: some View {
        ZStack {
            content
                .ignoresSafeArea()
        }
        // 页眉是正文布局的一部分，不属于阅读控件；滑动收起 chrome 时保持显示。
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
        // 阅读页始终沉浸显示，状态栏不随阅读控件显隐而重新出现。
        .statusBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task {
            model.onToggleControls = toggleControls
            model.onSwipeStart = hideControlsForSwipe
            await model.loadIfNeeded()
        }
        .onDisappear {
            model.onToggleControls = nil
            model.onSwipeStart = nil
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
            ReadiumNavigatorView(navigator: navigator)
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

    // MARK: - 阅读页页眉

    // 书名嵌入正文上方，独立于 showControls 的显隐状态。
    private var pageHeader: some View {
        Text(model.title)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color(uiColor: model.theme.contentUIColor))
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

    // MARK: - Liquid Glass 阅读器 chrome

    private var bottomBar: some View {
        GeometryReader { geometry in
            let cornerInsets = geometry.containerCornerInsets
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

            GlassEffectContainer(spacing: 12) {
                ZStack {
                    controlButton("目录", systemImage: "list.bullet") {
                        showTableOfContents = true
                    }
                    .position(leadingCenter)

                    controlButton("主题与排版", systemImage: "xmark.triangle.circle.square") {
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
        // containerCornerInsets 是 iOS 26 根据当前窗口形状和系统 UI
        // 计算出的动态值。优先使用系统测量值，让按钮圆心随真实屏幕
        // 圆角向下对齐；只有平直窗口（例如部分 iPad 场景）返回 0 时，
        // 才使用回退值，并确保圆形控件不会越过容器边界。
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
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    // MARK: - 主题与排版

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("在页眉显示书名", isOn: $model.showBookTitleInPageHeader)
                } header: {
                    Text("界面")
                } footer: {
                    Text("书名只显示在阅读页页眉，不会出现在顶栏或底栏。")
                }

                Section("阅读方式") {
                    Picker("阅读方式", selection: $model.flowMode) {
                        ForEach(EPUBFlowMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if model.flowMode == .paged {
                        Picker("翻页方式", selection: $model.pageTransition) {
                            ForEach(EPUBPageTransitionMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("文字") {
                    Picker("字体", selection: $model.fontFamily) {
                        ForEach(EPUBFontFamily.allCases) { family in
                            Text(family.label).tag(family)
                        }
                    }

                    LabeledContent("字号", value: "\(Int(model.fontScale * 100))%")
                    Slider(value: $model.fontScale, in: 0.8 ... 2.0, step: 0.05)

                    LabeledContent("行高", value: model.lineHeight.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $model.lineHeight, in: 1.0 ... 2.0, step: 0.1)

                    LabeledContent("首行缩进", value: model.paragraphIndent.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $model.paragraphIndent, in: 0 ... 3.0, step: 0.5)
                }

                Section("页面") {
                    LabeledContent("页边距", value: model.pageMargins.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $model.pageMargins, in: 0.5 ... 2.0, step: 0.1)

                    Picker("主题", selection: $model.theme) {
                        ForEach(EPUBReaderTheme.allCases) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    LabeledContent("上边距", value: "\(Int(model.contentTopInset)) pt")
                    Slider(value: $model.contentTopInset, in: 0 ... 160, step: 4)
                        .accessibilityLabel("正文上边距")

                    LabeledContent("下边距", value: "\(Int(model.contentBottomInset)) pt")
                    Slider(value: $model.contentBottomInset, in: 0 ... 160, step: 4)
                        .accessibilityLabel("正文下边距")
                } header: {
                    Text("正文与屏幕边距")
                } footer: {
                    Text("最小值仍会遵守设备安全区，避免正文被刘海、动态岛或 Home Indicator 遮挡。")
                }

                Section {
                    Toggle("保留出版方样式", isOn: $model.publisherStyles)
                } footer: {
                    Text("关闭后，字号、行高和缩进等个性化设置会更稳定。")
                }

                Section {
                    Button("恢复默认排版") { model.resetTypography() }
                }
            }
            .navigationTitle("主题与排版")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showSettings = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
