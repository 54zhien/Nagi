
import SwiftUI
import UIKit

struct ReaderChrome<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let content: Content
    let title: String
    let titleColor: Color
    let readerBackground: Color
    let titleFontFamily: ReaderFontFamily
    let showsTitle: Bool
    @Binding var showControls: Bool
    @Binding var interactionRevision: Int
    let onDismiss: () -> Void
    let onTableOfContents: () -> Void
    let onSettings: () -> Void
    let onSwipeStart: (() -> Void)?
    let transitionCoordinator: ReaderTransitionCoordinator?

    init(
        title: String,
        titleColor: Color,
        readerBackground: Color,
        titleFontFamily: ReaderFontFamily,
        showsTitle: Bool,
        showControls: Binding<Bool>,
        interactionRevision: Binding<Int>,
        onDismiss: @escaping () -> Void,
        onTableOfContents: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onSwipeStart: (() -> Void)? = nil,
        transitionCoordinator: ReaderTransitionCoordinator? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.title = title
        self.titleColor = titleColor
        self.readerBackground = readerBackground
        self.titleFontFamily = titleFontFamily
        self.showsTitle = showsTitle
        self._showControls = showControls
        self._interactionRevision = interactionRevision
        self.onDismiss = onDismiss
        self.onTableOfContents = onTableOfContents
        self.onSettings = onSettings
        self.onSwipeStart = onSwipeStart
        self.transitionCoordinator = transitionCoordinator
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .all)

                if let transitionCoordinator {
                    ReaderSnapshotAnchor(coordinator: transitionCoordinator)
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsTitle {
                    ReaderPageHeader(
                        title: title,
                        color: titleColor,
                        fontFamily: titleFontFamily
                    )
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
            .overlay {
                if let transitionCoordinator {
                    ReaderSnapshotLayer(
                        coordinator: transitionCoordinator,
                        fallbackBackground: readerBackground
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .all)
                    .allowsHitTesting(false)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: ReaderControlMetrics.swipeMinimumDistance)
                    .onChanged { _ in
                        noteInteraction()
                        onSwipeStart?()
                    }
            )
        }
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        .background(readerBackground, ignoresSafeAreaEdges: .all)
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

        return NagiGlassEffectContainer(spacing: 12) {
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
        .nagiGlass(in: .circle, interactive: true)
        .accessibilityLabel(label)
    }

    private func noteInteraction() {
        interactionRevision &+= 1
    }
}

private struct ReaderPageHeader: View {
    let title: String
    let color: Color
    let fontFamily: ReaderFontFamily

    var body: some View {
        Text(title)
            .font(fontFamily.swiftUIFont(ofSize: 15))
            .foregroundStyle(color.opacity(0.55))
            .lineLimit(1)
            .padding(.horizontal, 72)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: CGFloat(ReaderLayoutMetrics.pageHeaderHeight), alignment: .center)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel("页眉书名：\(title)")
    }
}

private enum ReaderControlMetrics {
    static let diameter: CGFloat = 48
    static let iconPointSize: CGFloat = 20
    static let exitDiameter: CGFloat = 48
    static let exitIconPointSize: CGFloat = 20
    static let exitTopInset: CGFloat = 0
    static let exitTrailingInset: CGFloat = 24
    static let swipeMinimumDistance: CGFloat = 10
    static let autoHideNanoseconds: UInt64 = 7_000_000_000
}

@MainActor
final class ReaderTransitionCoordinator {
    private static let settleNanoseconds: UInt64 = 40_000_000
    private static let maximumTransitionNanoseconds: UInt64 = 500_000_000
    private static let fadeDuration: TimeInterval = 0.15

    private weak var captureAnchor: UIView?
    private weak var snapshotHost: ReaderSnapshotHostView?
    private var activeCover: UIView?

    private var finishTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var transitionToken = 0
    private var isTransitionActive = false
    private var activeMutationKind: ReaderVisualMutationKind = .full
    private var reduceMotion = false

    func register(captureAnchor: UIView) {
        self.captureAnchor = captureAnchor
    }

    func register(snapshotHost: ReaderSnapshotHostView) {
        self.snapshotHost = snapshotHost
    }

    func begin(kind: ReaderVisualMutationKind, reduceMotion: Bool) {
        transitionToken &+= 1
        cancelTasks()
        removeSnapshot()

        activeMutationKind = kind
        self.reduceMotion = reduceMotion
        isTransitionActive = false

        guard kind == .theme || kind == .font || kind == .full else { return }
        guard let host = snapshotHost else { return }

        host.layoutIfNeeded()
        guard host.bounds.width > 0, host.bounds.height > 0 else { return }

        let cover = UIView(frame: host.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = host.fallbackBackgroundColor
        cover.isOpaque = true
        cover.clipsToBounds = true
        cover.isUserInteractionEnabled = false
        cover.accessibilityElementsHidden = true
        cover.isAccessibilityElement = false

        if let source = captureSurface,
           source.bounds.width > 0,
           source.bounds.height > 0 {
            source.layoutIfNeeded()
            if let snapshot = source.snapshotView(afterScreenUpdates: false) {
                snapshot.frame = host.convert(source.bounds, from: source)
                snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                snapshot.isUserInteractionEnabled = false
                snapshot.accessibilityElementsHidden = true
                snapshot.isAccessibilityElement = false
                snapshot.alpha = 1
                cover.addSubview(snapshot)
            }
        }

        host.addSubview(cover)

        activeCover = cover
        isTransitionActive = true

        let token = transitionToken
        fallbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.maximumTransitionNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            self?.finish(token: token)
        }
    }

    func readerStateDidUpdate(
        waitForContent: @escaping @MainActor (ReaderVisualMutationKind) async -> Void
    ) {
        let kind = activeMutationKind
        let shouldWait = isTransitionActive || kind == .typography || kind == .geometry
        guard shouldWait else { return }

        finishTask?.cancel()
        let token = transitionToken
        finishTask = Task { @MainActor [weak self] in
            await waitForContent(kind)

            guard !Task.isCancelled else { return }

            guard self?.isTransitionActive == true else {
                self?.activeMutationKind = .full
                return
            }

            do {
                try await Task.sleep(nanoseconds: Self.settleNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            self?.finish(token: token)
        }
    }

    func cancel() {
        transitionToken &+= 1
        cancelTasks()
        isTransitionActive = false
        activeMutationKind = .full
        removeSnapshot()
    }

    private var captureSurface: UIView? {
        guard let captureAnchor else { return nil }

        var fallback: UIView?
        var current = captureAnchor.superview
        let windowSize = captureAnchor.window?.bounds.size

        while let view = current, !(view is UIWindow) {
            let size = view.bounds.size
            guard size.width > 40, size.height > 40 else {
                current = view.superview
                continue
            }

            fallback = view

            if let windowSize,
               size.width >= windowSize.width * 0.75,
               size.height >= windowSize.height * 0.75 {
                return view
            }

            current = view.superview
        }

        return fallback
    }

    private func finish(token: Int) {
        guard token == transitionToken, isTransitionActive else { return }

        finishTask?.cancel()
        finishTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        isTransitionActive = false

        guard let cover = activeCover else { return }

        if reduceMotion {
            removeSnapshot()
            activeMutationKind = .full
            return
        }

        UIView.animate(
            withDuration: Self.fadeDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
        ) {
            cover.alpha = 0
        } completion: { [weak self, weak cover] _ in
            guard let self, self.transitionToken == token else { return }
            cover?.removeFromSuperview()
            self.activeCover = nil
            self.activeMutationKind = .full
        }
    }

    private func cancelTasks() {
        finishTask?.cancel()
        finishTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
    }

    private func removeSnapshot() {
        activeCover?.removeFromSuperview()
        activeCover = nil
    }
}

struct ReaderSnapshotLayer: UIViewRepresentable {
    let coordinator: ReaderTransitionCoordinator
    let fallbackBackground: Color

    func makeUIView(context: Context) -> ReaderSnapshotHostView {
        let view = ReaderSnapshotHostView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.backgroundColor = .clear
        view.isOpaque = false
        view.fallbackBackgroundColor = UIColor(fallbackBackground)
        view.coordinator = coordinator
        coordinator.register(snapshotHost: view)
        return view
    }

    func updateUIView(_ uiView: ReaderSnapshotHostView, context: Context) {
        uiView.fallbackBackgroundColor = UIColor(fallbackBackground)
        uiView.coordinator = coordinator
        coordinator.register(snapshotHost: uiView)
    }
}

final class ReaderSnapshotHostView: UIView {
    weak var coordinator: ReaderTransitionCoordinator?
    var fallbackBackgroundColor: UIColor = .clear

    override func didMoveToWindow() {
        super.didMoveToWindow()
        coordinator?.register(snapshotHost: self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        coordinator?.register(snapshotHost: self)
    }
}

struct ReaderSnapshotAnchor: UIViewRepresentable {
    let coordinator: ReaderTransitionCoordinator

    func makeUIView(context: Context) -> ReaderSnapshotAnchorView {
        let view = ReaderSnapshotAnchorView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.coordinator = coordinator
        coordinator.register(captureAnchor: view)
        return view
    }

    func updateUIView(_ uiView: ReaderSnapshotAnchorView, context: Context) {
        uiView.coordinator = coordinator
        coordinator.register(captureAnchor: uiView)
    }
}

final class ReaderSnapshotAnchorView: UIView {
    weak var coordinator: ReaderTransitionCoordinator?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        coordinator?.register(captureAnchor: self)
    }
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
    @Binding var characterSpacing: Double
    @Binding var wordSpacing: Double
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
        characterSpacing: Binding<Double>,
        wordSpacing: Binding<Double>,
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
        self._characterSpacing = characterSpacing
        self._wordSpacing = wordSpacing
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

                    LabeledContent("行间距", value: lineHeight.formatted(.number.precision(.fractionLength(2))))
                    Slider(value: $lineHeight, in: ReaderLayoutMetrics.lineHeightRange, step: 0.05)
                        .disabled(publisherStyles?.wrappedValue ?? false)

                    LabeledContent("字符间距", value: "\(Int(characterSpacing))%")
                    Slider(value: $characterSpacing, in: ReaderLayoutMetrics.characterSpacingRange, step: 1)
                        .disabled(publisherStyles?.wrappedValue ?? false)

                    LabeledContent("词间距", value: "\(Int(wordSpacing))%")
                    Slider(value: $wordSpacing, in: ReaderLayoutMetrics.wordSpacingRange, step: 2)
                        .disabled(publisherStyles?.wrappedValue ?? false)
                }

                Section {
                    LabeledContent("页边空白", value: "\(Int(pageMargins.rounded())) pt")
                    Slider(
                        value: $pageMargins,
                        in: ReaderLayoutMetrics.pageMarginsRange,
                        step: ReaderLayoutMetrics.pageMarginsStep
                    )
                } header: {
                    Text("页面与正文间距")
                } footer: {
                    Text("正文上下留白由系统安全区、页眉和阅读控件动态决定；首行缩进固定为 2；页边空白为 16–48 pt，默认 24 pt。")
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
