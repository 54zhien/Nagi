//
//  TXTReaderView.swift
//  Nagi
//
//  TXT 阅读界面：TextKit 分页/滚动渲染，chrome 与 EPUB 完全共用。
//

import SwiftUI
import SwiftData
import UIKit

struct TXTReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @State private var model: TXTReaderModel
    @State private var showControls = true
    @State private var interactionRevision = 0
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
            interactionRevision: $interactionRevision,
            onDismiss: { dismiss() },
            onTableOfContents: { showTableOfContents = true },
            onSettings: { showSettings = true },
            onSwipeStart: hideControlsForSwipe
        ) {
            content
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        registerInteraction()
                        toggleControls()
                    }
                )
                .accessibilityAction(
                    named: Text(showControls ? "隐藏阅读控件" : "显示阅读控件"),
                    {
                        registerInteraction()
                        toggleControls()
                    }
                )
        }
        .task {
            await model.load()
        }
        .onDisappear {
            model.cancelPendingLayout()
            model.flushReadingProgress()
            try? modelContext.save()
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(
                showBookTitleInPageHeader: $model.showBookTitleInPageHeader,
                flowMode: $model.flowMode,
                pageTransition: $model.pageTransition,
                fontFamily: $model.fontFamily,
                boldText: $model.boldText,
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
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView("正在打开 TXT…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(model.theme.background)
        } else if let error = model.errorMessage {
            VStack(spacing: 16) {
                ContentUnavailableView(
                    "无法显示内容",
                    systemImage: "doc.text",
                    description: Text(error)
                )

                Button {
                    Task { await model.retry() }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityLabel("重试打开 TXT")
                .accessibilityHint("重新加载当前文本文件")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(model.theme.background)
        } else if model.pages.isEmpty && model.fullText.length == 0 {
            if model.chapters.isEmpty {
                ContentUnavailableView("暂无内容", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(model.theme.background)
            } else {
                ProgressView("正在排版…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(model.theme.background)
            }
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
                    pageRanges: model.pageRanges,
                    transitionStyle: model.pageTransition.uiKitTransitionStyle,
                    insets: model.readerInsets,
                    background: model.theme.background,
                    currentPage: $model.currentPageIndex,
                    onSwipeStart: handleContentSwipeStart,
                    onNeedNextPages: { model.requestNextPageBatch() },
                    onNeedPreviousPages: { model.requestPreviousPageBatch() }
                )
                .id("\(model.layoutGeneration)-\(model.pageTransition.rawValue)")
            }

        case .scroll:
            ScrollableTextView(
                attributedText: model.fullText,
                insets: model.readerInsets,
                background: model.theme.background,
                revision: model.layoutGeneration,
                positionID: model.scrollPositionID,
                initialCharacterOffset: model.initialScrollCharacterOffset,
                initialProgress: model.initialScrollProgress,
                onSwipeStart: handleContentSwipeStart,
                onCharacterOffset: model.updateScrollCharacterOffset,
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

    private func handleContentSwipeStart() {
        registerInteraction()
        hideControlsForSwipe()
    }

    private func registerInteraction() {
        interactionRevision &+= 1
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
