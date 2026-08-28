//
//  EPUBReaderView.swift
//  Seidoku
//
//  Readium EPUB 阅读界面：正文优先，阅读页 chrome 与 TXT 共用。
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
        ReaderChrome(
            title: model.title,
            titleColor: Color(uiColor: model.theme.contentUIColor),
            showsTitle: model.showBookTitleInPageHeader,
            showControls: $showControls,
            onDismiss: { dismiss() },
            onTableOfContents: { showTableOfContents = true },
            onSettings: { showSettings = true },
            onSwipeStart: hideControlsForSwipe
        ) {
            content
        }
        .task {
            model.onToggleControls = toggleControls
            model.onSwipeStart = hideControlsForSwipe
            await model.loadIfNeeded()
        }
        .onDisappear {
            model.onToggleControls = nil
            model.onSwipeStart = nil
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
                publisherStyles: $model.publisherStyles,
                onReset: { model.resetTypography() }
            )
        }
        .sheet(isPresented: $showTableOfContents) {
            ReaderTableOfContentsSheet(
                entries: model.tableOfContents.map {
                    ReaderTOCItem(id: $0.id, title: $0.title, depth: $0.depth)
                },
                currentID: model.currentTOCEntryID
            ) { item in
                guard let entry = model.tableOfContents.first(where: { $0.id == item.id }) else { return }
                model.go(to: entry)
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
}
