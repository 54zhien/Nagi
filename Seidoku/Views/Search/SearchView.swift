//
//  SearchView.swift
//  Seidoku
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
            Group {
                if searchTerms.isEmpty {
                    ContentUnavailableView(
                        "搜索书库",
                        systemImage: "magnifyingglass",
                        description: Text("输入书名关键词查找书籍")
                    )
                } else if matchingBooks.isEmpty {
                    ContentUnavailableView(
                        "未找到书籍",
                        systemImage: "magnifyingglass",
                        description: Text("没有找到书名中包含“\(searchText)”的书籍")
                    )
                } else {
                    List(matchingBooks) { book in
                        Button {
                            selectedBook = book
                        } label: {
                            BookRow(book: book)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollEdgeEffectStyle(.automatic, for: .all)
            .navigationTitle("搜索")
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
