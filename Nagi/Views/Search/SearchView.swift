import SwiftUI
import SwiftData

enum SearchHistoryStorage {
    static let key = "Nagi.search.history"
    static let maximumCount = 10

    static func record(_ query: String, defaults: UserDefaults = .standard) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        var entries = history(from: defaults)
        entries.removeAll { $0.compare(normalized, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame }
        entries.insert(normalized, at: 0)
        entries = Array(entries.prefix(maximumCount))
        defaults.set(encoded(entries), forKey: key)
    }

    static func history(from defaults: UserDefaults = .standard) -> [String] {
        guard let value = defaults.string(forKey: key),
              let data = value.data(using: .utf8),
              let entries = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return entries
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.set(encoded([]), forKey: key)
    }

    private static func encoded(_ entries: [String]) -> String {
        guard let data = try? JSONEncoder().encode(entries) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct SearchView: View {
    @Query(sort: \Book.title) private var books: [Book]
    @Binding var searchText: String
    @State private var selectedBook: Book?
    @State private var effectiveQuery = ""
    @State private var queryTask: Task<Void, Never>?
    @AppStorage(SearchHistoryStorage.key) private var storedSearchHistory = "[]"

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
        .onChange(of: searchText, initial: true) { _, newValue in
            scheduleQueryUpdate(for: newValue)
        }
        .onDisappear {
            queryTask?.cancel()
            queryTask = nil
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        Group {
            if searchTerms.isEmpty {
                if searchHistory.isEmpty {
                    ContentUnavailableView {
                        searchUnavailableLabel("搜索书库")
                    }
                    .safeAreaBar(edge: .top, spacing: 0) {
                        searchHeader
                    }
                } else {
                    searchHistoryView
                        .safeAreaBar(edge: .top, spacing: 0) {
                            searchHeader
                        }
                }
            } else if matchingBooks.isEmpty {
                ContentUnavailableView {
                    searchUnavailableLabel("未找到书籍")
                } description: {
                    Text("没有找到书名中包含“\(effectiveQuery)”的书籍")
                }
                .safeAreaBar(edge: .top, spacing: 0) {
                    searchHeader
                }
            } else {
                List {
                    ForEach(matchingBooks) { book in
                        Button {
                            guard book.importState == .ready else { return }
                            SearchHistoryStorage.record(effectiveQuery)
                            selectedBook = book
                        } label: {
                            BookRow(book: book)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .safeAreaBar(edge: .top, spacing: 0) {
                    searchHeader
                }
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var searchHistoryView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("最近搜索")
                        .font(.title2.bold())

                    Spacer()

                    Button("清除") {
                        SearchHistoryStorage.clear()
                    }
                    .font(.body.weight(.medium))
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 10)

                Divider()

                ForEach(searchHistory, id: \.self) { query in
                    Button {
                        SearchHistoryStorage.record(query)
                        searchText = query
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.secondary)

                            Text(query)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    Divider()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 24)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var searchHeader: some View {
        NagiPageHeader(title: "搜索")
            .padding(.bottom, 24)
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

    private var searchHistory: [String] {
        guard let data = storedSearchHistory.data(using: .utf8),
              let entries = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return entries
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
