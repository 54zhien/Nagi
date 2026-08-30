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

private enum LibraryHeaderMetrics {
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 8
    static let controlSize: CGFloat = 48
    static let hideThreshold: CGFloat = 8
    static let revealTolerance: CGFloat = 0.5
    static let transitionDuration: Double = 0.25
    static let iconBlurRadius: CGFloat = 6
    static let buttonBlurRadius: CGFloat = 8
}

struct LibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
    @ScaledMetric(relativeTo: .largeTitle) private var libraryTitleFontSize: CGFloat = 38
    @State private var viewModel = LibraryViewModel()
    @State private var pickerCoordinator: DocumentPickerCoordinator?
    @State private var bookToRename: Book?
    @State private var renameText = ""
    @State private var bookToDelete: Book?
    @State private var showDeleteConfirm = false
    @State private var selectedBook: Book?
    @State private var isHeaderHidden = false
    @State private var headerTransitionProgress: CGFloat = 0

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
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        max(geometry.contentOffset.y + geometry.contentInsets.top, 0)
                    } action: { _, scrollOffset in
                        updateHeaderVisibility(for: scrollOffset)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                libraryHeader
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

    private var libraryHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("书库")
                .font(.system(size: libraryTitleFontSize, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(minHeight: LibraryHeaderMetrics.controlSize, alignment: .leading)
                .opacity(titleOpacity)
                .accessibilityHidden(isHeaderHidden)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 12)

            Button(action: presentImportPicker) {
                Image(systemName: "plus")
                    .font(.title2.weight(.medium))
                    .blur(radius: iconBlurRadius)
                    .frame(width: LibraryHeaderMetrics.controlSize, height: LibraryHeaderMetrics.controlSize)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .blur(radius: buttonBlurRadius)
            .opacity(buttonOpacity)
            .allowsHitTesting(!isHeaderHidden)
            .accessibilityHidden(isHeaderHidden)
            .accessibilityLabel("导入小说")
        }
        .padding(.horizontal, LibraryHeaderMetrics.horizontalPadding)
        .padding(.vertical, LibraryHeaderMetrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            statusBarBlurLayer
        }
    }

    private var statusBarBlurLayer: some View {
        GeometryReader { geometry in
            let topInset = max(geometry.frame(in: .global).minY, 0)

            Group {
                if reduceTransparency {
                    Color(uiColor: .systemBackground)
                } else {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: topInset)
            .offset(y: -topInset)
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
        }
    }

    private var titleOpacity: Double {
        Double(1 - headerTransitionProgress)
    }

    private var iconBlurRadius: CGFloat {
        guard !reduceMotion else { return 0 }
        return min(headerTransitionProgress * 2, 1) * LibraryHeaderMetrics.iconBlurRadius
    }

    private var buttonTransitionProgress: CGFloat {
        min(max((headerTransitionProgress - 0.5) * 2, 0), 1)
    }

    private var buttonBlurRadius: CGFloat {
        guard !reduceMotion else { return 0 }
        return buttonTransitionProgress * LibraryHeaderMetrics.buttonBlurRadius
    }

    private var buttonOpacity: Double {
        Double(1 - buttonTransitionProgress)
    }

    private func updateHeaderVisibility(for rawScrollOffset: CGFloat) {
        let scrollOffset = max(rawScrollOffset, 0)
        let shouldHide = isHeaderHidden
            ? scrollOffset > LibraryHeaderMetrics.revealTolerance
            : scrollOffset > LibraryHeaderMetrics.hideThreshold

        guard shouldHide != isHeaderHidden else { return }
        isHeaderHidden = shouldHide

        let targetProgress: CGFloat = shouldHide ? 1 : 0
        if reduceMotion {
            headerTransitionProgress = targetProgress
        } else {
            withAnimation(.easeInOut(duration: LibraryHeaderMetrics.transitionDuration)) {
                headerTransitionProgress = targetProgress
            }
        }
    }

    private func presentImportPicker() {
        pickerCoordinator = DocumentPickerPresenter.present(
            allowedContentTypes: [.plainText, .epub],
            allowsMultipleSelection: true,
            onPick: { files in
                viewModel.importAndParse(files, into: modelContext)
            }
        )
    }
}

// MARK: - 书籍控件

enum BookCardLayout {
    case library
    case home
    case list
}

enum BookCardMetrics {
    static let cornerRadius: CGFloat = 14
    static let coverWidth: CGFloat = 92
    static let coverHeight: CGFloat = 138
    static let contentSpacing: CGFloat = 12
    static let cardPadding: CGFloat = 12
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
        .clipShape(RoundedRectangle(cornerRadius: BookCardMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BookCardMetrics.cornerRadius, style: .continuous)
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
        HStack(alignment: .top, spacing: BookCardMetrics.contentSpacing) {
            BookCoverView(data: book.coverData)
                .frame(width: BookCardMetrics.coverWidth, height: BookCardMetrics.coverHeight)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(authorText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    Text(progressText)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 46, minHeight: 26)
                        .glassEffect(.clear, in: .capsule)
                        .accessibilityLabel("阅读进度")
                        .accessibilityValue(Text(progressText))
                }

                Label(chapterText, systemImage: "bookmark.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 10)

                Spacer(minLength: 0)

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .accessibilityLabel("阅读进度")
                    .accessibilityValue(Text(progressText))
            }
            .frame(maxWidth: .infinity, minHeight: BookCardMetrics.coverHeight, alignment: .topLeading)
        }
        .padding(BookCardMetrics.cardPadding)
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
