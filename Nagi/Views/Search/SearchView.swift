import SwiftUI
import SwiftData
import UIKit

private enum SearchHeaderMetrics {
    static let fadeExtension: CGFloat = 72
}

struct SearchView: View {
    @Query(sort: \Book.title) private var books: [Book]
    @Binding var searchText: String
    @State private var selectedBook: Book?
    @State private var effectiveQuery = ""
    @State private var queryTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            NavigationStack {
                searchContent(topInset: geometry.safeAreaInsets.top)
                    .toolbar(.hidden, for: .navigationBar)
            }
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
    private func searchContent(topInset: CGFloat) -> some View {
        Group {
            if searchTerms.isEmpty {
                ContentUnavailableView {
                    searchUnavailableLabel("搜索书库")
                }
                .safeAreaBar(edge: .top, spacing: 0) {
                    searchHeader(topInset: topInset)
                }
            } else if matchingBooks.isEmpty {
                ContentUnavailableView {
                    searchUnavailableLabel("未找到书籍")
                } description: {
                    Text("没有找到书名中包含“\(effectiveQuery)”的书籍")
                }
                .safeAreaBar(edge: .top, spacing: 0) {
                    searchHeader(topInset: topInset)
                }
            } else {
                List {
                    ForEach(matchingBooks) { book in
                        Button {
                            guard book.importState == .ready else { return }
                            selectedBook = book
                        } label: {
                            BookRow(book: book)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
                .safeAreaBar(edge: .top, spacing: 0) {
                    searchHeader(topInset: topInset)
                }
            }
        }
        .scrollEdgeEffectHidden(true, for: .top)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func searchHeader(topInset: CGFloat) -> some View {
        NagiPageHeader(title: "搜索")
            .background(alignment: .bottom) {
                Rectangle()
                    .fill(.regularMaterial)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.68),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .frame(
                        height: topInset
                            + NagiPageHeaderMetrics.contentHeight
                            + SearchHeaderMetrics.fadeExtension
                    )
                    .offset(y: SearchHeaderMetrics.fadeExtension)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
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
                try await Task.sleep(for: .milliseconds(120))
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
