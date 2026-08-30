//
//  ReaderChrome.swift
//  Nagi
//
//  EPUB 与 TXT 共用的沉浸式阅读页 chrome：页眉、退出、目录和主题控件。
//

import SwiftUI

struct ReaderChrome<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let content: Content
    let title: String
    let titleColor: Color
    let readerBackground: Color
    let showsTitle: Bool
    @Binding var showControls: Bool
    @Binding var interactionRevision: Int
    let onDismiss: () -> Void
    let onTableOfContents: () -> Void
    let onSettings: () -> Void
    let onSwipeStart: (() -> Void)?

    init(
        title: String,
        titleColor: Color,
        readerBackground: Color,
        showsTitle: Bool,
        showControls: Binding<Bool>,
        interactionRevision: Binding<Int>,
        onDismiss: @escaping () -> Void,
        onTableOfContents: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onSwipeStart: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.title = title
        self.titleColor = titleColor
        self.readerBackground = readerBackground
        self.showsTitle = showsTitle
        self._showControls = showControls
        self._interactionRevision = interactionRevision
        self.onDismiss = onDismiss
        self.onTableOfContents = onTableOfContents
        self.onSettings = onSettings
        self.onSwipeStart = onSwipeStart
    }

    var body: some View {
        // 正文表面独立铺满容器；页眉和控件仍由下方的 safe-area/overlay 层定位。
        GeometryReader { geometry in
            ZStack {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .all)
            }
            // 页眉是正文的一部分，不属于阅读控件；滑动收起 chrome 时保持显示。
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsTitle {
                    ReaderPageHeader(title: title, color: titleColor)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showControls {
                    exitButton
                        .padding(.top, ReaderControlMetrics.exitTopInset)
                        .padding(.trailing, ReaderControlMetrics.exitTrailingInset)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if showControls {
                    bottomBar(in: geometry)
                        .transition(.opacity)
                }
            }
            // UIKit 阅读器会自行处理分页手势；这个 simultaneous 手势只负责统一收起控件。
            .simultaneousGesture(
                DragGesture(minimumDistance: ReaderControlMetrics.swipeMinimumDistance)
                    .onChanged { _ in
                        noteInteraction()
                        onSwipeStart?()
                    }
            )
        }
        // 保留顶部安全区，同时让 GeometryReader 继续覆盖底部和横向区域；
        // 因此底栏仍使用同一套全屏圆角几何，不改变其位置计算。
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        // 阅读容器统一绘制主题背景，覆盖顶部安全区、页眉宿主和 UIKit 阅读器外层空白。
        // 正文视图不再单独绘制一层背景，避免出现颜色不同的矩形色块。
        .background(readerBackground, ignoresSafeAreaEdges: .all)
        // The status-bar toolbar placement is not present in the Xcode 26.3 SDK
        // used by CI. Keep the reader edge-to-edge with the compatible API.
        .statusBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onChange(of: showControls) { _, isVisible in
            guard isVisible else { return }
            interactionRevision &+= 1
        }
        .task(id: interactionRevision) {
            guard showControls else { return }

            do {
                try await Task.sleep(nanoseconds: ReaderControlMetrics.autoHideNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled, showControls else { return }
            if reduceMotion {
                showControls = false
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    showControls = false
                }
            }
        }
    }

    private var exitButton: some View {
        controlButton(
            "退出阅读器",
            systemImage: "xmark",
            diameter: ReaderControlMetrics.exitDiameter,
            iconPointSize: ReaderControlMetrics.exitIconPointSize,
            action: {
                noteInteraction()
                onDismiss()
            }
        )
    }

    private func bottomBar(in geometry: GeometryProxy) -> some View {
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

        return GlassEffectContainer(spacing: 12) {
            ZStack {
                controlButton(
                    "目录",
                    systemImage: "list.bullet",
                    action: {
                        noteInteraction()
                        onTableOfContents()
                    }
                )
                .position(leadingCenter)

                controlButton(
                    "主题与排版",
                    systemImage: "xmark.triangle.circle.square",
                    action: {
                        noteInteraction()
                        onSettings()
                    }
                )
                .position(trailingCenter)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
    }

    private func bottomCornerCenter(
        _ cornerInset: CGSize,
        in size: CGSize,
        isLeading: Bool
    ) -> CGPoint {
        let radius = ReaderControlMetrics.diameter / 2
        let horizontalDistance = cornerCenterDistance(
            cornerInset.width,
            maximum: max(radius, size.width - radius),
            radius: radius
        )
        let verticalDistance = cornerCenterDistance(
            cornerInset.height,
            maximum: max(radius, size.height - radius),
            radius: radius
        )

        return CGPoint(
            x: isLeading ? horizontalDistance : size.width - horizontalDistance,
            y: size.height - verticalDistance
        )
    }

    private func cornerCenterDistance(
        _ measuredInset: CGFloat,
        maximum: CGFloat,
        radius: CGFloat
    ) -> CGFloat {
        // containerCornerInsets 的宽高分别代表对应圆角在两个轴上的动态偏移。
        // 分轴计算可保留不对称窗口、系统 UI 和横竖屏布局的真实几何关系；
        // 没有圆角数据时至少保留半个控件直径，确保整个圆形控件仍在屏幕内。
        min(max(radius, measuredInset), maximum)
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

    private func noteInteraction() {
        interactionRevision &+= 1
    }
}

private struct ReaderPageHeader: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(color.opacity(0.55))
            .lineLimit(1)
            .padding(.horizontal, 72)
            .frame(maxWidth: .infinity, alignment: .center)
            // 与右上角退出按钮共用同一高度，使书名基线区域的中心线一致。
            .frame(height: ReaderControlMetrics.exitDiameter, alignment: .center)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel("页眉书名：\(title)")
    }
}

private enum ReaderControlMetrics {
    // 底栏控件比最小触控尺寸略大，提升沉浸式阅读中的可发现性和点击舒适度。
    static let diameter: CGFloat = 48
    static let iconPointSize: CGFloat = 20
    static let exitDiameter: CGFloat = 48
    static let exitIconPointSize: CGFloat = 20
    static let exitTopInset: CGFloat = 0
    static let exitTrailingInset: CGFloat = 24
    static let swipeMinimumDistance: CGFloat = 10
    // 计时任务以 showControls 变为 true 的状态更新为起点，显示 7 秒后自动收起。
    static let autoHideNanoseconds: UInt64 = 7_000_000_000
}

struct ReaderTOCItem: Identifiable, Hashable {
    let id: String
    let title: String
    let depth: Int
}

struct ReaderTableOfContentsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let entries: [ReaderTOCItem]
    let currentID: String?
    let onSelect: (ReaderTOCItem) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("没有目录", systemImage: "list.bullet")
                } else {
                    ScrollViewReader { proxy in
                        List(entries) { entry in
                            tocRow(entry)
                                .id(entry.id)
                        }
                        .task(id: currentID) {
                            guard let currentID else { return }
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
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func tocRow(_ entry: ReaderTOCItem) -> some View {
        let isCurrent = entry.id == currentID

        return Button {
            onSelect(entry)
            dismiss()
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
}

struct ReaderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var showBookTitleInPageHeader: Bool
    @Binding var flowMode: ReaderFlowMode
    @Binding var pageTransition: ReaderPageTransitionMode
    @Binding var fontFamily: ReaderFontFamily
    @Binding var boldText: Bool
    @Binding var fontScale: Double
    @Binding var lineHeight: Double
    @Binding var paragraphIndent: Double
    @Binding var pageMargins: Double
    @Binding var contentTopInset: Double
    @Binding var contentBottomInset: Double
    @Binding var theme: ReaderTheme

    let publisherStyles: Binding<Bool>?
    let onReset: () -> Void

    init(
        showBookTitleInPageHeader: Binding<Bool>,
        flowMode: Binding<ReaderFlowMode>,
        pageTransition: Binding<ReaderPageTransitionMode>,
        fontFamily: Binding<ReaderFontFamily>,
        boldText: Binding<Bool>,
        fontScale: Binding<Double>,
        lineHeight: Binding<Double>,
        paragraphIndent: Binding<Double>,
        pageMargins: Binding<Double>,
        contentTopInset: Binding<Double>,
        contentBottomInset: Binding<Double>,
        theme: Binding<ReaderTheme>,
        publisherStyles: Binding<Bool>? = nil,
        onReset: @escaping () -> Void
    ) {
        self._showBookTitleInPageHeader = showBookTitleInPageHeader
        self._flowMode = flowMode
        self._pageTransition = pageTransition
        self._fontFamily = fontFamily
        self._boldText = boldText
        self._fontScale = fontScale
        self._lineHeight = lineHeight
        self._paragraphIndent = paragraphIndent
        self._pageMargins = pageMargins
        self._contentTopInset = contentTopInset
        self._contentBottomInset = contentBottomInset
        self._theme = theme
        self.publisherStyles = publisherStyles
        self.onReset = onReset
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("在页眉显示书名", isOn: $showBookTitleInPageHeader)
                } header: {
                    Text("界面")
                } footer: {
                    Text("书名只显示在阅读页页眉，不会出现在顶栏或底栏。")
                }

                Section("阅读方式") {
                    Picker("阅读方式", selection: $flowMode) {
                        ForEach(ReaderFlowMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if flowMode == .paged {
                        Picker("翻页方式", selection: $pageTransition) {
                            ForEach(ReaderPageTransitionMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("文字") {
                    Picker("字体", selection: $fontFamily) {
                        ForEach(ReaderFontFamily.options) { family in
                            Text(family.label)
                                .font(family.swiftUIFont(ofSize: 17))
                                .tag(family)
                        }
                    }

                    Toggle("粗体文字", isOn: $boldText)

                    LabeledContent("字号", value: "\(Int(fontScale * 100))%")
                    Slider(value: $fontScale, in: 0.8 ... 2.0, step: 0.05)

                    LabeledContent("行高", value: lineHeight.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $lineHeight, in: 1.0 ... 2.0, step: 0.1)

                    LabeledContent("首行缩进", value: paragraphIndent.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $paragraphIndent, in: 0 ... 3.0, step: 0.5)
                }

                Section {
                    LabeledContent("页边距", value: pageMargins.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $pageMargins, in: 0.5 ... 2.0, step: 0.1)

                    LabeledContent("上边距", value: "\(Int(contentTopInset)) pt")
                    Slider(value: $contentTopInset, in: 0 ... 160, step: 4)
                        .accessibilityLabel("正文上边距")

                    LabeledContent("下边距", value: "\(Int(contentBottomInset)) pt")
                    Slider(value: $contentBottomInset, in: 0 ... 160, step: 4)
                        .accessibilityLabel("正文下边距")
                } header: {
                    Text("页面与正文间距")
                } footer: {
                    Text("最小值仍会遵守设备安全区，避免正文被刘海、动态岛或 Home Indicator 遮挡。")
                }

                Section("背景色") {
                    Picker("背景色", selection: $theme) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if let publisherStyles {
                    Section {
                        Toggle("保留出版方样式", isOn: publisherStyles)
                    } footer: {
                        Text("关闭后，字号、行高和缩进等个性化设置会更稳定。")
                    }
                }

                Section {
                    Button("恢复默认排版", action: onReset)
                }
            }
            .navigationTitle("主题与排版")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
