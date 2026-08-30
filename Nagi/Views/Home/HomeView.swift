//
//  HomeView.swift
//  Nagi
//
//  主页：继续阅读入口
//

import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(NagiAppearanceSettings.bookCardsUseLiquidGlassKey)
    private var bookCardsUseLiquidGlass = true
    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
    @State private var selectedBook: Book?
    @State private var isHeaderHidden = false
    @State private var headerTransitionProgress: CGFloat = 0

    var body: some View {
        NavigationStack {
            Group {
                if readingBooks.isEmpty {
                    ContentUnavailableView(
                        "还没有书",
                        systemImage: "book"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            Text("继续阅读")
                                .font(.title2.weight(.semibold))

                            ForEach(readingBooks) { book in
                                Button {
                                    selectedBook = book
                                } label: {
                                    BookCardButtonLabel(
                                        book: book,
                                        layout: .home,
                                        usesLiquidGlass: bookCardsUseLiquidGlass
                                    )
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .modifier(
                                    BookCardSurfaceModifier(
                                        isLiquidGlassEnabled: bookCardsUseLiquidGlass
                                    )
                                )
                                .contentShape(.interaction, BookCardMetrics.cardShape)
                                .accessibilityLabel(book.title)
                                .accessibilityHint("打开阅读")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.automatic)
                    .scrollEdgeEffectStyle(.automatic, for: .all)
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        max(geometry.contentOffset.y + geometry.contentInsets.top, 0)
                    } action: { _, scrollOffset in
                        updateHeaderVisibility(for: scrollOffset)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear
                    .frame(height: NagiPageHeaderMetrics.contentHeight)
            }
            .overlay(alignment: .top) {
                NagiPageHeader(
                    title: "主页",
                    transitionProgress: headerTransitionProgress,
                    isHeaderHidden: isHeaderHidden
                )
            }
        }
        .overlay(alignment: .top) {
            NagiStatusBarBlurLayer()
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { selectedBook != nil },
                set: { if !$0 { selectedBook = nil } }
            )
        ) {
            if let selectedBook {
                ReaderView(book: selectedBook)
            }
        }
    }

    private func updateHeaderVisibility(for rawScrollOffset: CGFloat) {
        let scrollOffset = max(rawScrollOffset, 0)
        let shouldHide = isHeaderHidden
            ? scrollOffset > NagiPageHeaderMetrics.revealTolerance
            : scrollOffset > NagiPageHeaderMetrics.hideThreshold

        guard shouldHide != isHeaderHidden else { return }
        isHeaderHidden = shouldHide

        let targetProgress: CGFloat = shouldHide ? 1 : 0
        if reduceMotion {
            headerTransitionProgress = targetProgress
        } else {
            withAnimation(.easeInOut(duration: NagiPageHeaderMetrics.transitionDuration)) {
                headerTransitionProgress = targetProgress
            }
        }
    }

    private var readingBooks: [Book] {
        books
            .filter { $0.lastReadAt != nil }
            .sorted { left, right in
                guard let leftDate = left.lastReadAt,
                      let rightDate = right.lastReadAt else {
                    return left.addedAt > right.addedAt
                }
                return leftDate > rightDate
            }
    }
}

#Preview {
    HomeView()
        .modelContainer(Persistence.container)
}
