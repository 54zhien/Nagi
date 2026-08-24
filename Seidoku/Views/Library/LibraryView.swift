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
    @State private var pickerCoordinator: DocumentPickerCoordinator?
    @State private var bookToRename: Book?
    @State private var renameText = ""
    @State private var bookToDelete: Book?
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    ContentUnavailableView(
                        "书库是空的",
                        systemImage: "books.vertical"
                    )
                } else {
                    List {
                        ForEach(books) { book in
                            NavigationLink {
                                ReaderView(book: book)
                            } label: {
                                BookRow(book: book)
                            }
                            .contextMenu {
                                Button {
                                    bookToRename = book
                                    renameText = book.title
                                } label: {
                                    Label("重命名", systemImage: "pencil")
                                }
                                Button {
                                    SharePresenter.present(items: [URL(fileURLWithPath: book.sourceURL)])
                                } label: {
                                    Label("分享", systemImage: "square.and.arrow.up")
                                }
                                Button(role: .destructive) {
                                    bookToDelete = book
                                    showDeleteConfirm = true
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .scrollEdgeEffectStyle(.automatic, for: .all)
                }
            }
            .navigationTitle("书库")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        pickerCoordinator = DocumentPickerPresenter.present(
                            allowedContentTypes: [.plainText, .epub],
                            allowsMultipleSelection: true,
                            onPick: { files in
                                viewModel.importAndParse(files, into: modelContext)
                            }
                        )
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("导入小说")
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
            .alert("重命名", isPresented: Binding(
                get: { bookToRename != nil },
                set: { if !$0 { bookToRename = nil } }
            )) {
                TextField("新名称", text: $renameText)
                Button("确定") {
                    if let book = bookToRename {
                        viewModel.rename(book, to: renameText, context: modelContext)
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .alert("删除", isPresented: $showDeleteConfirm) {
                Button("删除", role: .destructive) {
                    if let book = bookToDelete {
                        viewModel.delete(book, context: modelContext)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("确定删除「\(bookToDelete?.title ?? "")」吗？此操作不可撤销。")
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
