//
//  LibraryView.swift
//  Nagi
//
//  书库：书架列表 + 导入入口（右上角 + 导入 EPUB/TXT）
//

import SwiftUI
import SwiftData
import UIKit
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
    @State private var selectedBook: Book?

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    ContentUnavailableView(
                        "书库是空的",
                        systemImage: "books.vertical"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(books) { book in
                                Button {
                                    selectedBook = book
                                } label: {
                                    BookCard(book: book, layout: .library)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.glass)
                                .accessibilityLabel(book.title)
                                .accessibilityHint("打开阅读")
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
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.automatic)
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
        .task(id: books.map(\.id)) {
            viewModel.backfillMissingCovers(for: books, into: modelContext)
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
}

// MARK: - 书籍控件

enum BookCardLayout {
    case library
    case home
    case list
}

struct BookCoverView: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: "book.closed")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

struct BookCard: View {
    let book: Book
    let layout: BookCardLayout

    var body: some View {
        switch layout {
        case .library, .home:
            readingCard
        case .list:
            listCard
        }
    }

    private var readingCard: some View {
        HStack(alignment: .top, spacing: 16) {
            BookCoverView(data: book.coverData)
                .frame(width: 108, height: 162)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(book.title)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(authorText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Text(progressText)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .frame(minWidth: 54, minHeight: 32)
                        .glassEffect(.clear, in: .capsule)
                        .accessibilityLabel("阅读进度")
                        .accessibilityValue(Text(progressText))
                }

                Label(chapterText, systemImage: "bookmark.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 14)

                Spacer(minLength: 0)

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                    .accessibilityLabel("阅读进度")
                    .accessibilityValue(Text(progressText))
            }
            .frame(maxWidth: .infinity, minHeight: 162, alignment: .topLeading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var listCard: some View {
        HStack(alignment: .center, spacing: 12) {
            BookCoverView(data: book.coverData)
                .frame(width: 52)

            metadata
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(book.title)
                .font(.headline)
                .lineLimit(2)

            if let author = book.author, !author.isEmpty {
                Text(author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(formatLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var progress: Double {
        min(max(book.progressPercent, 0), 1)
    }

    private var progressText: String {
        "\(Int((progress * 100).rounded()))%"
    }

    private var authorText: String {
        let author = book.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return author.isEmpty ? "未知作者" : author
    }

    private var chapterText: String {
        guard book.lastReadAt != nil else { return "尚未阅读" }

        let chapterNumber = max(book.currentChapterIndex + 1, 1)
        let title = book.currentChapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return "第\(chapterNumber)章" }
        return "第\(chapterNumber)章 \(title)"
    }

    private var formatLabel: String {
        let formatName = book.format == .epub ? "EPUB" : "TXT"
        if book.chapterCount > 0 {
            return "\(formatName) · \(book.chapterCount) 章"
        }
        return formatName
    }
}

// MARK: - 搜索结果行

struct BookRow: View {
    let book: Book

    var body: some View {
        BookCard(book: book, layout: .list)
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
