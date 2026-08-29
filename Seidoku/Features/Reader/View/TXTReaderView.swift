//
//  TXTReaderView.swift
//  Seidoku
//
//  TXT 阅读界面：TextKit 分页/滚动渲染，chrome 与 EPUB 完全共用。
//

import SwiftUI
import UIKit

struct TXTReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: TXTReaderModel
    @State private var showControls = true
    @State private var showSettings = false
    @State private var showTableOfContents = false

    init(book: Book) {
        _model = State(initialValue: TXTReaderModel(book: book))
    }

    var body: some View {
        ReaderChrome(
            title: model.title,
            titleColor: model.theme.foreground,
            readerBackground: model.theme.background,
            showsTitle: model.showBookTitleInPageHeader,
            showControls: $showControls,
            onDismiss: { dismiss() },
            onTableOfContents: { showTableOfContents = true },
            onSettings: { showSettings = true },
            onSwipeStart: hideControlsForSwipe
        ) {
            content
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        toggleControls()
                    }
                )
                .accessibilityAction(
                    named: Text(showControls ? "隐藏阅读控件" : "显示阅读控件"),
                    toggleControls
                )
        }
        .task {
            await model.load()
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(
                showBookTitleInPageHeader: $model.showBookTitleInPageHeader,
                flowMode: $model.flowMode,
                pageTransition: $model.pageTransition,
                fontFamily: $model.fontFamily,
                fontScale: $model.fontScale,
                lineHeight: $model.lineHeight,
                paragraphIndent: $model.paragraphIndent,
                pageMargins: $model.pageMargins,
                contentTopInset: $model.contentTopInset,
                contentBottomInset: $model.contentBottomInset,
                theme: $model.theme,
                onReset: { model.resetTypography() }
            )
        }
        .sheet(isPresented: $showTableOfContents) {
            ReaderTableOfContentsSheet(
                entries: model.chapters.map {
                    ReaderTOCItem(id: $0.id, title: $0.title, depth: 0)
                },
                currentID: model.currentChapterID
            ) { item in
                guard let chapter = model.chapters.first(where: { $0.id == item.id }) else { return }
                model.selectChapter(chapter)
            }
        }
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
        if model.isLoading {
            ProgressView("正在打开 TXT…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(model.theme.background)
        } else if let error = model.errorMessage {
            ContentUnavailableView(
                "无法显示内容",
                systemImage: "doc.text",
                description: Text(error)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(model.theme.background)
        } else if model.pages.isEmpty && model.fullText.length == 0 {
            ContentUnavailableView("暂无内容", systemImage: "doc.text")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(model.theme.background)
        } else {
            GeometryReader { geometry in
                let safeAreaInsets = Self.uiEdgeInsets(from: geometry.safeAreaInsets)

                readerSurface
                    .background(model.theme.background)
                    .onAppear {
                        model.updateViewport(size: geometry.size, safeAreaInsets: safeAreaInsets)
                    }
                    .onChange(of: geometry.size) { _, newSize in
                        model.updateViewport(
                            size: newSize,
                            safeAreaInsets: Self.uiEdgeInsets(from: geometry.safeAreaInsets)
                        )
                    }
                    .onChange(of: geometry.safeAreaInsets) { _, newInsets in
                        model.updateViewport(
                            size: geometry.size,
                            safeAreaInsets: Self.uiEdgeInsets(from: newInsets)
                        )
                    }
            }
        }
    }

    @ViewBuilder
    private var readerSurface: some View {
        switch model.flowMode {
        case .paged:
            if model.pages.isEmpty {
                ProgressView("正在排版…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PageViewController(
                    pages: model.pages,
                    transitionStyle: model.pageTransition.uiKitTransitionStyle,
                    insets: model.readerInsets,
                    background: model.theme.background,
                    currentPage: $model.currentPageIndex,
                    onSwipeStart: hideControlsForSwipe
                )
                .id("\(model.layoutGeneration)-\(model.pageTransition.rawValue)")
            }

        case .scroll:
            ScrollableTextView(
                attributedText: model.fullText,
                insets: model.readerInsets,
                background: model.theme.background,
                revision: model.layoutGeneration,
                positionID: model.currentChapterID ?? "txt-\(model.currentChapterIndex)",
                onSwipeStart: hideControlsForSwipe,
                onProgress: model.updateScrollProgress
            )
        }
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

    private static func uiEdgeInsets(from edgeInsets: EdgeInsets) -> UIEdgeInsets {
        UIEdgeInsets(
            top: edgeInsets.top,
            left: edgeInsets.leading,
            bottom: edgeInsets.bottom,
            right: edgeInsets.trailing
        )
    }
}

private extension ReaderPageTransitionMode {
    var uiKitTransitionStyle: UIPageViewController.TransitionStyle {
        switch self {
        case .pageCurl: return .pageCurl
        case .cover: return .scroll
        }
    }
}
