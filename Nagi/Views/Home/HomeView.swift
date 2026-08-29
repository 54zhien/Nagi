//
//  HomeView.swift
//  Nagi
//
//  主页：继续阅读入口
//

import SwiftUI
import SwiftData

struct HomeView: View {
    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
    @State private var selectedBook: Book?

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
                                    BookCard(book: book, layout: .home)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(
                                    .regular.interactive(),
                                    in: RoundedRectangle(
                                        cornerRadius: BookCardMetrics.cornerRadius,
                                        style: .continuous
                                    )
                                )
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
                }
            }
            .navigationTitle("主页")
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
