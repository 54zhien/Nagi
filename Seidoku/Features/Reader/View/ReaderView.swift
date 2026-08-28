//
//  ReaderView.swift
//  Seidoku
//
//  阅读器主视图：三种翻页模式 + 工具栏 + 排版设置 + 目录。
//

import SwiftUI
import UIKit

struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var viewModel: ReaderViewModel
    @State private var showControls = true

    init(book: Book) {
        _viewModel = State(initialValue: ReaderViewModel(book: book))
    }

    var body: some View {
        GeometryReader { container in
            ZStack {
                NavigationStack {
                    ZStack {
                        GeometryReader { geo in
                            content
                                .onAppear {
                                    viewModel.pageSize = geo.size
                                    Task { await viewModel.load() }
                                }
                                .onChange(of: geo.size) { _, newSize in
                                    viewModel.pageSize = newSize
                                }
                                // 只让正文响应“显示/隐藏控件”手势，避免点击控件时误触发。
                                .contentShape(Rectangle())
                                .onTapGesture(perform: toggleControls)
                                .accessibilityAction(
                                    named: Text(showControls ? "隐藏阅读控件" : "显示阅读控件"),
                                    toggleControls
                                )
                        }
                    }
                    .navigationBarBackButtonHidden(true)
                    .toolbar(.hidden, for: .navigationBar)
                }

                if showControls {
                    topBar
                        .position(
                            ReaderControlMetrics.topControlCenter(
                                in: container.size,
                                safeAreaInsets: container.safeAreaInsets,
                                cornerInsets: container.containerCornerInsets
                            )
                        )

                    bottomBar
                        .position(
                            ReaderControlMetrics.bottomControlCenter(
                                in: container.size,
                                safeAreaInsets: container.safeAreaInsets,
                                cornerInsets: container.containerCornerInsets
                            )
                        )
                }
            }
            // 阅读正文可以延伸到全屏，控件位置则由外层容器的实际安全区和圆角数据决定。
            .ignoresSafeArea()
        }
        .statusBarHidden(!showControls)
        .toolbar(.hidden, for: .tabBar)
    }

    private func toggleControls() {
        if accessibilityReduceMotion {
            showControls.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls.toggle()
            }
        }
    }

    private func selectChapter(_ chapter: BookChapter) {
        guard chapter.index != viewModel.currentChapterIndex else { return }
        viewModel.currentChapterIndex = chapter.index
        Task { await viewModel.loadCurrentChapter() }
    }

    @ViewBuilder
    private func menuOptionLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private let fontSizeOptions: [Double] = [12, 14, 17, 20, 24, 30]
    private let lineSpacingOptions: [Double] = [0, 4, 6, 8, 12, 16]

    // MARK: - 正文内容（三模式）

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.errorMessage {
            ContentUnavailableView(
                "无法打开",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if viewModel.pages.isEmpty {
            ContentUnavailableView("暂无内容", systemImage: "book")
        } else {
            switch viewModel.transition {
            case .pageCurl:
                PageViewController(
                    pages: viewModel.pages,
                    transitionStyle: .pageCurl,
                    insets: readerInsets,
                    background: viewModel.theme.background,
                    currentPage: $viewModel.currentPageIndex
                )
                // 每个章节拥有独立分页控制器，避免复用上一章的 UIKit 页面缓存。
                .id(viewModel.currentChapter?.id ?? "")
            case .horizontal:
                PageViewController(
                    pages: viewModel.pages,
                    transitionStyle: .scroll,
                    insets: readerInsets,
                    background: viewModel.theme.background,
                    currentPage: $viewModel.currentPageIndex
                )
                .id(viewModel.currentChapter?.id ?? "")
            case .vertical:
                ScrollableTextView(attributedText: viewModel.fullText, insets: readerInsets)
            }
        }
    }

    private var readerInsets: UIEdgeInsets {
        UIEdgeInsets(top: 24, left: viewModel.horizontalInset, bottom: 24, right: viewModel.horizontalInset)
    }

    // MARK: - Liquid Glass 阅读器 chrome

    private var topBar: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .semibold))
        }
        .controlSize(.large)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .frame(
            width: ReaderControlMetrics.diameter,
            height: ReaderControlMetrics.diameter
        )
        .accessibilityLabel("退出阅读器")
        .accessibilityHint("返回上一个页面")
    }

    private var bottomBar: some View {
        Menu {
            Section("阅读") {
                Menu("目录", systemImage: "xmark.triangle.circle.square") {
                    if viewModel.chapters.isEmpty {
                        Text("暂无目录")
                    } else {
                        ForEach(viewModel.chapters) { chapter in
                            Button {
                                selectChapter(chapter)
                            } label: {
                                menuOptionLabel(
                                    chapter.title,
                                    isSelected: chapter.index == viewModel.currentChapterIndex
                                )
                            }
                        }
                    }
                }

                Button {
                    viewModel.goPrevious()
                } label: {
                    Label("上一页", systemImage: "chevron.left")
                }
                .disabled(!viewModel.canGoPrevious)

                Button {
                    viewModel.goNext()
                } label: {
                    Label("下一页", systemImage: "chevron.right")
                }
                .disabled(!viewModel.canGoNext)
            }

            Section("排版") {
                Menu("字号", systemImage: "textformat.size") {
                    ForEach(fontSizeOptions, id: \.self) { size in
                        Button {
                            viewModel.fontSize = size
                        } label: {
                            menuOptionLabel(
                                "\(Int(size)) 磅",
                                isSelected: viewModel.fontSize == size
                            )
                        }
                    }
                }

                Menu("行距", systemImage: "arrow.up.and.down.text.horizontal") {
                    ForEach(lineSpacingOptions, id: \.self) { spacing in
                        Button {
                            viewModel.lineSpacing = spacing
                        } label: {
                            menuOptionLabel(
                                spacing == 0 ? "默认" : "\(Int(spacing)) 磅",
                                isSelected: viewModel.lineSpacing == spacing
                            )
                        }
                    }
                }

                Menu("主题", systemImage: "circle.lefthalf.filled") {
                    ForEach(ReaderTheme.allCases) { theme in
                        Button {
                            viewModel.theme = theme
                        } label: {
                            menuOptionLabel(theme.label, isSelected: viewModel.theme == theme)
                        }
                    }
                }

                Menu("翻页方式", systemImage: "book.pages") {
                    ForEach(PageTransitionMode.allCases) { mode in
                        Button {
                            viewModel.transition = mode
                        } label: {
                            menuOptionLabel(mode.label, isSelected: viewModel.transition == mode)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "xmark.triangle.circle.square")
                .font(.system(size: ReaderControlMetrics.menuIconPointSize, weight: .semibold))
        }
        .controlSize(.large)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .frame(
            width: ReaderControlMetrics.diameter,
            height: ReaderControlMetrics.diameter
        )
        .accessibilityLabel("阅读选项")
        .accessibilityHint("打开目录、翻页和排版设置")
    }

    private enum ReaderControlMetrics {
        static let diameter: CGFloat = 44
        // 当设备没有额外安全区或圆角避让时，仍保留一个最小视觉间距。
        static let minimumEdgeInset: CGFloat = 24
        static let menuIconPointSize: CGFloat = 21

        static func topControlCenter(
            in containerSize: CGSize,
            safeAreaInsets: EdgeInsets,
            cornerInsets: RectangleCornerInsets
        ) -> CGPoint {
            CGPoint(
                x: containerSize.width - edgeInset(
                    safeArea: safeAreaInsets.trailing,
                    corner: cornerInsets.topTrailing.width
                ) - diameter / 2,
                y: edgeInset(
                    safeArea: safeAreaInsets.top,
                    corner: cornerInsets.topTrailing.height
                ) + diameter / 2
            )
        }

        static func bottomControlCenter(
            in containerSize: CGSize,
            safeAreaInsets: EdgeInsets,
            cornerInsets: RectangleCornerInsets
        ) -> CGPoint {
            CGPoint(
                x: containerSize.width - edgeInset(
                    safeArea: safeAreaInsets.trailing,
                    corner: cornerInsets.bottomTrailing.width
                ) - diameter / 2,
                y: containerSize.height - edgeInset(
                    safeArea: safeAreaInsets.bottom,
                    corner: cornerInsets.bottomTrailing.height
                ) - diameter / 2
            )
        }

        private static func edgeInset(safeArea: CGFloat, corner: CGFloat) -> CGFloat {
            // CornerInsets 描述的是屏幕圆角的避让包围盒；圆形控件要与其圆心同心，
            // 控件边缘到屏幕边缘的距离应扣除控件半径，而不是使用完整的 inset 高度。
            let concentricCornerInset = max(0, corner - diameter / 2)
            return max(minimumEdgeInset, safeArea, concentricCornerInset)
        }
    }
}

/// 上下滚动模式：整章文本可滚动。
struct ScrollableTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let insets: UIEdgeInsets

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isScrollEnabled = true
        textView.isEditable = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.textContainer.lineFragmentPadding = 0
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.textContainerInset = insets
        textView.attributedText = attributedText
    }
}

