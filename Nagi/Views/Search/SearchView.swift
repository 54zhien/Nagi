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
    @State private var queryTask: Task<Void, Never>?

    var body: some View {
        Group {
            if searchTerms.isEmpty {
                Color.clear
                    .ignoresSafeArea()
            } else {
                activeSearchContent
            }
        }
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
            scheduleQueryUpdate(for: newValue)
        }
        .onDisappear {
            queryTask?.cancel()
            queryTask = nil
        }
    }

    @ViewBuilder
    private var activeSearchContent: some View {
        ZStack {
            if matchingBooks.isEmpty {
                ContentUnavailableView {
                    searchUnavailableLabel("未找到书籍")
                } description: {
                    Text("没有找到书名中包含“\(effectiveQuery)”的书籍")
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
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .background(Color.clear)
        .safeAreaBar(edge: .top, spacing: 0) {
            searchHeader
        }
        .transaction { transaction in
            transaction.animation = nil
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

    private func scheduleQueryUpdate(for query: String) {
        queryTask?.cancel()

        guard !query.isEmpty else {
            queryTask = nil
            effectiveQuery = ""
            return
        }

        queryTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            effectiveQuery = query
        }
    }
}

#Preview {
    SearchView(searchText: .constant(""))
        .modelContainer(Persistence.container)
}
