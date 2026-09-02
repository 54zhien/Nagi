//
//  SearchView.swift
//  Nagi
//
//  搜索：按书名关键词实时过滤书库，并进入阅读页。
//

import SwiftUI
import SwiftData

struct SearchView: View {
    @Query(sort: \Book.title) private var books: [Book]
    @Binding var searchText: String
    @State private var selectedBook: Book?
    @State private var effectiveQuery = ""

    var body: some View {
        searchContent
        .transaction { transaction in
            transaction.animation = nil
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
        .onChange(of: searchText, initial: true) { _, newValue in
            effectiveQuery = newValue
        }
    }

    private var searchContent: some View {
        ZStack {
            searchResultsList
                .opacity(searchTerms.isEmpty ? 0 : 1)
                .allowsHitTesting(!searchTerms.isEmpty)

            searchEmptyState
                .opacity(
                    !searchTerms.isEmpty && matchingBooks.isEmpty
                        ? 1
                        : 0
                )
                .allowsHitTesting(false)
        }
        .background(Color.clear)
        .safeAreaBar(edge: .top, spacing: 0) {
            searchHeader
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var searchResultsList: some View {
        List {
            ForEach(matchingBooks) { book in
                Button {
                    selectedBook = book
                } label: {
                    BookRow(book: book)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var searchEmptyState: some View {
        ContentUnavailableView {
            searchUnavailableLabel("未找到书籍")
        } description: {
            Text("没有找到书名中包含“\(effectiveQuery)”的书籍")
        }
    }

    private var searchHeader: some View {
        NagiPageHeader(title: "搜索")
    }

    @ViewBuilder
    private func searchUnavailableLabel(_ title: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .semibold))
        }
    }

    private var searchTerms: [String] {
        effectiveQuery
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private var matchingBooks: [Book] {
        guard !searchTerms.isEmpty else { return [] }

        return books.filter { book in
            searchTerms.allSatisfy { term in
                book.title.range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: .current
                ) != nil
            }
        }
    }

}

#Preview {
    SearchView(searchText: .constant(""))
        .modelContainer(Persistence.container)
}
