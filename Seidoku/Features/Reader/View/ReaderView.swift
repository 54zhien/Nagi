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
            ZStack(alignment: .topLeading) {
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
            }
            // 先把阅读器内容固定为外层 GeometryReader 的全屏坐标系。
            .frame(width: container.size.width, height: container.size.height, alignment: .topLeading)
            // 控件直接挂在同一个全屏 frame 的右上/右下角，不再依赖 offset 的父布局原点。
            .overlay(alignment: .topTrailing) {
                if showControls {
                    topBar
                        .padding(.top, ReaderControlMetrics.edgeInset)
                        .padding(.trailing, ReaderControlMetrics.edgeInset)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showControls {
                    bottomBar
                        .padding(.bottom, ReaderControlMetrics.edgeInset)
                        .padding(.trailing, ReaderControlMetrics.edgeInset)
                }
            }
            // 阅读正文与两个固定控件都使用这一个全屏坐标系。
            .ignoresSafeArea(.all)
        }
        // fullScreenCover 的根 GeometryReader 也必须覆盖系统安全区，
        // 否则 bottomTrailing overlay 会以安全区底部而不是屏幕底部为基准。
        .ignoresSafeArea(.all)
        // 阅读页始终沉浸显示，避免退出控件与系统状态栏重叠。
        // 当前项目使用的 Xcode 26.3 SDK 尚未提供 ToolbarPlacement.statusBar，
        // 因此使用已在本项目 GitHub 构建中验证可用的兼容 API。
        .statusBarHidden(true)
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
        // 控件边缘距屏幕边缘 22pt，加上半径 22pt，圆心固定在 44pt。
        // 不使用 containerCornerInsets：它还可能包含状态栏、Home Indicator、
        // window presentation 等系统 UI 的重叠区域，并不等于硬件屏幕圆角圆心。
        static let edgeInset: CGFloat = 22
        static let menuIconPointSize: CGFloat = 21
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

