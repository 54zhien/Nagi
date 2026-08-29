//
//  ReaderView.swift
//  Seidoku
//
//  阅读器入口。EPUB 使用 Readium，TXT 使用独立的原生分页链路。
//

import SwiftData
import SwiftUI
import UIKit

struct ReaderView: View {
    let book: Book

    var body: some View {
        switch book.format {
        case .epub:
            EPUBReaderView(book: book)
        case .txt:
            TXTReaderView(book: book)
        }
    }
}

struct TXTReaderView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.modelContext) private var modelContext

    @State private var model: TXTReaderModel
    @State private var showControls = true

    init(book: Book) {
        _model = State(initialValue: TXTReaderModel(book: book))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                model.theme.background
                    .ignoresSafeArea()

                GeometryReader { geometry in
                    content
                        .onAppear {
                            updateViewport(geometry)
                            Task { await model.loadIfNeeded() }
                        }
                        .onChange(of: geometry.size) { _, _ in
                            updateViewport(geometry)
                        }
                        .onChange(of: geometry.safeAreaInsets.top) { _, _ in
                            updateViewport(geometry)
                        }
                        .onChange(of: geometry.safeAreaInsets.bottom) { _, _ in
                            updateViewport(geometry)
                        }
                        .simultaneousGesture(
                            TapGesture().onEnded(toggleControls)
                        )
                        .accessibilityAction(
                            named: Text(showControls ? "隐藏阅读控件" : "显示阅读控件"),
                            toggleControls
                        )
                }
                .ignoresSafeArea()
            }
            .overlay(alignment: .topTrailing) {
                if showControls {
                    exitButton
                        .padding(.top, ReaderControlMetrics.topInset)
                        .padding(.trailing, ReaderControlMetrics.edgeInset)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showControls {
                    optionsMenu
                        .padding(.bottom, ReaderControlMetrics.bottomInset)
                        .padding(.trailing, ReaderControlMetrics.edgeInset)
                }
            }
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
        }
        .statusBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .onDisappear {
            saveProgress()
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.layout == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage {
            ContentUnavailableView(
                "无法打开",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if let snapshot = model.layout, !snapshot.pages.isEmpty {
            switch model.transition {
            case .horizontal:
                TXTPageCollectionView(
                    snapshot: snapshot,
                    background: UIColor(model.theme.background),
                    currentPage: model.currentPageIndex,
                    onPageChanged: handlePageChanged
                )
                .id(snapshot.key.identifier)
            case .pageCurl:
                TXTPageCurlView(
                    snapshot: snapshot,
                    background: UIColor(model.theme.background),
                    currentPage: model.currentPageIndex,
                    onPageChanged: handlePageChanged
                )
                .id(snapshot.key.identifier)
            case .vertical:
                TXTScrollableTextView(
                    attributedText: snapshot.attributedText,
                    layoutKey: snapshot.key,
                    insets: model.readerInsets,
                    background: UIColor(model.theme.background),
                    restoreTextOffset: model.currentTextOffset,
                    initialContentOffset: model.verticalOffset,
                    onLocationChanged: handleVerticalLocation
                )
                .id(snapshot.key.identifier)
            }
        } else if model.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("暂无内容", systemImage: "book")
        }
    }

    private func updateViewport(_ geometry: GeometryProxy) {
        model.updateViewport(
            size: geometry.size,
            safeAreaInsets: UIEdgeInsets(
                top: geometry.safeAreaInsets.top,
                left: geometry.safeAreaInsets.leading,
                bottom: geometry.safeAreaInsets.bottom,
                right: geometry.safeAreaInsets.trailing
            ),
            displayScale: displayScale
        )
    }

    private func handlePageChanged(_ page: Int) {
        model.setCurrentPage(page)
        saveProgress()
    }

    private func handleVerticalLocation(_ offset: CGFloat, _ textOffset: Int) {
        model.updateVerticalLocation(contentOffset: offset, textOffset: textOffset)
    }

    private func saveProgress() {
        model.saveProgress()
        try? modelContext.save()
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

    private var exitButton: some View {
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
    }

    private var optionsMenu: some View {
        Menu {
            Section("阅读") {
                Menu("目录", systemImage: "list.bullet") {
                    if model.chapters.isEmpty {
                        Text("暂无目录")
                    } else {
                        ForEach(model.chapters) { chapter in
                            Button {
                                model.selectChapter(chapterIndex(chapter))
                            } label: {
                                menuOptionLabel(
                                    chapter.title,
                                    isSelected: chapter.id == model.currentChapter?.id
                                )
                            }
                        }
                    }
                }

                Button {
                    model.goPrevious()
                    saveProgress()
                } label: {
                    Label("上一页", systemImage: "chevron.left")
                }
                .disabled(model.transition == .vertical || !model.canGoPrevious)

                Button {
                    model.goNext()
                    saveProgress()
                } label: {
                    Label("下一页", systemImage: "chevron.right")
                }
                .disabled(model.transition == .vertical || !model.canGoNext)
            }

            Section("排版") {
                Menu("字号", systemImage: "textformat.size") {
                    ForEach([12.0, 14.0, 17.0, 20.0, 24.0, 30.0], id: \.self) { size in
                        Button {
                            model.fontSize = size
                        } label: {
                            menuOptionLabel(
                                "\(Int(size)) 磅",
                                isSelected: model.fontSize == size
                            )
                        }
                    }
                }

                Menu("行距", systemImage: "arrow.up.and.down.text.horizontal") {
                    ForEach([0.0, 4.0, 6.0, 8.0, 12.0, 16.0], id: \.self) { spacing in
                        Button {
                            model.lineSpacing = spacing
                        } label: {
                            menuOptionLabel(
                                spacing == 0 ? "默认" : "\(Int(spacing)) 磅",
                                isSelected: model.lineSpacing == spacing
                            )
                        }
                    }
                }

                Menu("主题", systemImage: "circle.lefthalf.filled") {
                    ForEach(ReaderTheme.allCases) { theme in
                        Button {
                            model.theme = theme
                        } label: {
                            menuOptionLabel(theme.label, isSelected: model.theme == theme)
                        }
                    }
                }

                Menu("翻页方式", systemImage: "book.pages") {
                    ForEach(PageTransitionMode.allCases) { mode in
                        Button {
                            model.transition = mode
                        } label: {
                            menuOptionLabel(mode.label, isSelected: model.transition == mode)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
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
    }

    private func chapterIndex(_ chapter: TXTChapter) -> Int {
        model.chapters.firstIndex(of: chapter) ?? 0
    }

    @ViewBuilder
    private func menuOptionLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private enum ReaderControlMetrics {
        static let diameter: CGFloat = 44
        static let edgeInset: CGFloat = 24
        static let topInset: CGFloat = 8
        static let bottomInset: CGFloat = 16
        static let menuIconPointSize: CGFloat = 21
    }
}
