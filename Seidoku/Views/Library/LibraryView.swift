//
//  LibraryView.swift
//  Seidoku
//
//  书库：书架列表 + 导入入口（右上角 + 导入 EPUB/TXT）
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
    @State private var viewModel = LibraryViewModel()
    @State private var isImporterPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    ContentUnavailableView(
                        "书库是空的",
                        systemImage: "books.vertical",
                        description: Text("点右上角 + 导入 TXT / EPUB 小说")
                    )
                } else {
                    List {
                        ForEach(books) { book in
                            NavigationLink {
                                ReaderView(book: book)
                            } label: {
                                BookRow(book: book)
                            }
                        }
                    }
                }
            }
            .navigationTitle("书库")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("导入小说")
                }
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.plainText, .epub],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let files):
                    viewModel.importAndParse(files, into: modelContext)
                case .failure(let error):
                    viewModel.errorMessage = error.localizedDescription
                }
            }
            .alert(
                "导入失败",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }
}

// MARK: - 书籍行

private struct BookRow: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(book.title)
                .font(.headline)
                .lineLimit(1)
            if let author = book.author, !author.isEmpty {
                Text(author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(formatLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var formatLabel: String {
        let formatName = book.format == .epub ? "EPUB" : "TXT"
        if book.chapterCount > 0 {
            return "\(formatName) · \(book.chapterCount) 章"
        }
        return formatName
    }
}

extension UTType {
    /// EPUB 的标准 UTI（IDPF），conformingTo 数据。
    static let epub = UTType(exportedAs: "org.idpf.epub-container", conformingTo: .data)
}

#Preview {
    LibraryView()
        .modelContainer(Persistence.container)
}
