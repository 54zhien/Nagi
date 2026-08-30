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

    var body: some View {
        NavigationStack {
            searchContent
                .toolbar(.hidden, for: .navigationBar)
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

    @ViewBuilder
    private var searchContent: some View {
        if searchTerms.isEmpty {
            ContentUnavailableView {
                searchUnavailableLabel("搜索书库")
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                searchHeader
            }
        } else if matchingBooks.isEmpty {
            ContentUnavailableView {
                searchUnavailableLabel("未找到书籍")
            } description: {
                Text("没有找到书名中包含“\(searchText)”的书籍")
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                searchHeader
            }
        } else {
            List {
                ForEach(matchingBooks) { book in
                    Button {
                        selectedBook = book
                    } label: {
                        BookRow(book: book)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .scrollEdgeEffectStyle(.automatic, for: .top)
            .safeAreaBar(edge: .top, spacing: 0) {
                searchHeader
            }
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
        searchText
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
