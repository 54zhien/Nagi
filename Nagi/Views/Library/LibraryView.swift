import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

enum NagiPageHeaderMetrics {
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 8
    static let controlSize: CGFloat = 48
    static let hideThreshold: CGFloat = 8
    static let revealTolerance: CGFloat = 0.5
    static let transitionDuration: Double = 0.25
    static let iconBlurRadius: CGFloat = 6
    static let buttonBlurRadius: CGFloat = 8

    static var contentHeight: CGFloat {
        controlSize + verticalPadding * 2
    }
}

/// 页面级大标题，保持标题和右侧操作控件的视觉与动效一致。
struct NagiPageHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var titleFontSize: CGFloat = 38

    let title: String
    let transitionProgress: CGFloat
    let isHeaderHidden: Bool
    let actionIcon: String?
    let actionAccessibilityLabel: String?
    let action: (() -> Void)?
    let secondaryAction: AnyView?

    init(
        title: String,
        transitionProgress: CGFloat = 0,
        isHeaderHidden: Bool = false,
        actionIcon: String? = nil,
        actionAccessibilityLabel: String? = nil,
        action: (() -> Void)? = nil,
        secondaryAction: AnyView? = nil
    ) {
        self.title = title
        self.transitionProgress = transitionProgress
        self.isHeaderHidden = isHeaderHidden
        self.actionIcon = actionIcon
        self.actionAccessibilityLabel = actionAccessibilityLabel
        self.action = action
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .font(.system(size: titleFontSize, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(minHeight: NagiPageHeaderMetrics.controlSize, alignment: .leading)
                .opacity(titleOpacity)
                .accessibilityHidden(isHeaderHidden)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 12)

            if secondaryAction != nil || (action != nil && actionIcon != nil) {
                HStack(spacing: 8) {
                    if let secondaryAction {
                        secondaryAction
                            .blur(radius: buttonBlurRadius)
                            .opacity(buttonOpacity)
                            .allowsHitTesting(!isHeaderHidden)
                            .accessibilityHidden(isHeaderHidden)
                    }

                    if let action, let actionIcon {
                        Button(action: action) {
                            Image(systemName: actionIcon)
                                .font(.title2.weight(.medium))
                                .blur(radius: iconBlurRadius)
                                .frame(
                                    width: NagiPageHeaderMetrics.controlSize,
                                    height: NagiPageHeaderMetrics.controlSize
                                )
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: Circle())
                        .blur(radius: buttonBlurRadius)
                        .opacity(buttonOpacity)
                        .allowsHitTesting(!isHeaderHidden)
                        .accessibilityHidden(isHeaderHidden)
                        .accessibilityLabel(actionAccessibilityLabel ?? actionIcon)
                    }
                }
            }
        }
        .padding(.horizontal, NagiPageHeaderMetrics.horizontalPadding)
        .padding(.vertical, NagiPageHeaderMetrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var normalizedProgress: CGFloat {
        min(max(transitionProgress, 0), 1)
    }

    private var titleOpacity: Double {
        Double(1 - normalizedProgress)
    }

    private var iconBlurRadius: CGFloat {
        guard !reduceMotion else { return 0 }
        return min(normalizedProgress * 2, 1) * NagiPageHeaderMetrics.iconBlurRadius
    }

    private var buttonTransitionProgress: CGFloat {
        min(max((normalizedProgress - 0.5) * 2, 0), 1)
    }

    private var buttonBlurRadius: CGFloat {
        guard !reduceMotion else { return 0 }
        return buttonTransitionProgress * NagiPageHeaderMetrics.buttonBlurRadius
    }

    private var buttonOpacity: Double {
        Double(1 - buttonTransitionProgress)
    }
}

private enum LibrarySortOption: String, CaseIterable, Identifiable, Hashable {
    case addedAt
    case title

    var id: Self { self }

    var title: String {
        switch self {
        case .addedAt:
            return "导入时间"
        case .title:
            return "名称"
        }
    }
}

struct LibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @AppStorage(NagiAppearanceSettings.bookCardsUseLiquidGlassKey)
    private var bookCardsUseLiquidGlass = true
    @AppStorage("Nagi.library.sortOption")
    private var storedSortOption = LibrarySortOption.addedAt.rawValue
    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
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
                            ForEach(sortedBooks) { book in
                                Button {
                                    switch book.importState {
                                    case .ready:
                                        selectedBook = book
                                    case .importing:
                                        break
                                    case .failed:
                                        viewModel.errorMessage = book.importErrorMessage
                                            ?? "导入失败，请重新导入这本书"
                                    }
                                } label: {
                                    BookCardButtonLabel(
                                        book: book,
                                        layout: .library,
                                        usesLiquidGlass: bookCardsUseLiquidGlass
                                    )
                                }
                                .buttonStyle(
                                    BookCardContextMenuButtonStyle(
                                        usesLiquidGlass: bookCardsUseLiquidGlass,
                                        reduceMotion: reduceMotion
                                    )
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.interaction, BookCardMetrics.cardShape)
                                .contentShape(.contextMenuPreview, BookCardMetrics.cardShape)
                                .accessibilityLabel(book.title)
                                .accessibilityHint(accessibilityHint(for: book))
                                .contextMenu {
                                    if book.importState == .failed {
                                        Button {
                                            viewModel.retryImport(book, in: modelContext)
                                        } label: {
                                            Label("重试导入", systemImage: "arrow.clockwise")
                                        }
                                    }
                                    Button {
                                        bookToRename = book
                                        renameText = book.title
                                    } label: {
                                        Label("重命名", systemImage: "pencil")
                                    }
                                    .disabled(book.importState != .ready)
                                    Button {
                                        if let sourceURL = BookFileLocator.resolve(book.sourceURL),
                                           FileManager.default.fileExists(atPath: sourceURL.path) {
                                            SharePresenter.present(items: [sourceURL])
                                        } else {
                                            viewModel.errorMessage = "源文件已丢失，请重新导入这本书"
                                        }
                                    } label: {
                                        Label("分享", systemImage: "square.and.arrow.up")
                                    }
                                    .disabled(book.importState != .ready)
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
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        max(geometry.contentOffset.y + geometry.contentInsets.top, 0)
                    } action: { _, scrollOffset in
                        updateHeaderVisibility(for: scrollOffset)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaBar(edge: .top, spacing: 0) {
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
        .fullScreenCover(item: $selectedBook) { book in
            ReaderView(book: book)
        }
    }

    private var libraryHeader: some View {
        NagiPageHeader(
            title: "书库",
            transitionProgress: headerTransitionProgress,
            isHeaderHidden: isHeaderHidden,
            actionIcon: "plus",
            actionAccessibilityLabel: "导入小说",
            action: presentImportPicker,
            secondaryAction: AnyView(librarySortMenu)
        )
    }

    private var sortOption: LibrarySortOption {
        LibrarySortOption(rawValue: storedSortOption) ?? .addedAt
    }

    private var sortedBooks: [Book] {
        guard sortOption == .title else { return books }

        return books.sorted { left, right in
            let titleComparison = left.title.localizedStandardCompare(right.title)
            if titleComparison != .orderedSame {
                return titleComparison == .orderedAscending
            }

            if left.addedAt != right.addedAt {
                return left.addedAt > right.addedAt
            }

            return left.id.uuidString < right.id.uuidString
        }
    }

    private var librarySortMenu: some View {
        Menu {
            Section("排序方式") {
                ForEach(LibrarySortOption.allCases) { option in
                    Button {
                        selectSortOption(option)
                    } label: {
                        if sortOption == option {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.title2.weight(.medium))
                .frame(
                    width: NagiPageHeaderMetrics.controlSize,
                    height: NagiPageHeaderMetrics.controlSize
                )
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .disabled(books.isEmpty)
        .accessibilityLabel("排序方式")
        .accessibilityValue(Text(sortOption.title))
    }

    private func selectSortOption(_ option: LibrarySortOption) {
        guard option != sortOption else { return }

        if reduceMotion {
            storedSortOption = option.rawValue
        } else {
            withAnimation(.snappy(duration: 0.25)) {
                storedSortOption = option.rawValue
            }
        }
    }

    private func updateHeaderVisibility(for rawScrollOffset: CGFloat) {
        let scrollOffset = max(rawScrollOffset, 0)
        let shouldHide = isHeaderHidden
            ? scrollOffset > NagiPageHeaderMetrics.revealTolerance
            : scrollOffset > NagiPageHeaderMetrics.hideThreshold

        guard shouldHide != isHeaderHidden else { return }
        isHeaderHidden = shouldHide

        let targetProgress: CGFloat = shouldHide ? 1 : 0
        if reduceMotion {
            headerTransitionProgress = targetProgress
        } else {
            withAnimation(.easeInOut(duration: NagiPageHeaderMetrics.transitionDuration)) {
                headerTransitionProgress = targetProgress
            }
        }
    }

    private func accessibilityHint(for book: Book) -> String {
        switch book.importState {
        case .ready:
            return "打开阅读"
        case .importing:
            return "正在导入"
        case .failed:
            return "导入失败，轻点查看原因"
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
    static let cardCornerRadius: CGFloat = 20
    static let coverCornerRadius: CGFloat = 12
    static let coverWidth: CGFloat = 84
    static let coverHeight: CGFloat = 112
    static let contentSpacing: CGFloat = 12
    static let cardPadding: CGFloat = 10

    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    static var coverShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: coverCornerRadius, style: .continuous)
    }

    static var contentHeight: CGFloat {
        coverHeight + cardPadding * 2
    }
}

struct BookCardSurfaceModifier: ViewModifier {
    let usesLiquidGlass: Bool
    var isInteractive = true

    func body(content: Content) -> some View {
        if usesLiquidGlass {
            if isInteractive {
                content.glassEffect(
                    .regular.interactive(),
                    in: BookCardMetrics.cardShape
                )
            } else {
                content.glassEffect(
                    .regular,
                    in: BookCardMetrics.cardShape
                )
            }
        } else {
            content.background(
                Color(uiColor: .secondarySystemBackground),
                in: BookCardMetrics.cardShape
            )
        }
    }
}

/// 保留系统 Button 的点击取消与滚动协调，只补充整卡一致的即时按压反馈。
struct BookCardButtonStyle: ButtonStyle {
    let usesLiquidGlass: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(
                BookCardSurfaceModifier(
                    usesLiquidGlass: usesLiquidGlass
                )
            )
            .scaleEffect(
                configuration.isPressed && !reduceMotion ? 0.985 : 1
            )
            .brightness(configuration.isPressed ? -0.025 : 0)
            .opacity(configuration.isPressed ? 0.96 : 1)
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.14),
                value: configuration.isPressed
            )
    }
}

/// 上下文菜单交互由系统负责，卡片表面保持稳定，仅增加轻量按压覆盖色。
struct BookCardContextMenuButtonStyle: ButtonStyle {
    let usesLiquidGlass: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(
                BookCardSurfaceModifier(
                    usesLiquidGlass: usesLiquidGlass,
                    isInteractive: false
                )
            )
            .overlay {
                BookCardMetrics.cardShape
                    .fill(.primary.opacity(configuration.isPressed ? 0.045 : 0))
                    .allowsHitTesting(false)
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.1),
                value: configuration.isPressed
            )
    }
}

@MainActor
private final class BookCoverImageCache {
    static let shared = BookCoverImageCache()

    private let cache: NSCache<NSData, UIImage>

    private init() {
        cache = NSCache<NSData, UIImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 48 * 1_024 * 1_024
    }

    func image(for data: Data) -> UIImage? {
        let key = data as NSData
        if let cachedImage = cache.object(forKey: key) {
            return cachedImage
        }

        guard let image = UIImage(data: data) else { return nil }
        let decodedCost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
        cache.setObject(image, forKey: key, cost: decodedCost)
        return image
    }
}

struct BookCoverView: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = BookCoverImageCache.shared.image(for: data) {
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
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(BookCardMetrics.coverShape)
        .overlay {
            BookCardMetrics.coverShape
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

struct BookCard: View {
    let book: Book
    let layout: BookCardLayout
    let usesLiquidGlass: Bool

    init(book: Book, layout: BookCardLayout, usesLiquidGlass: Bool = true) {
        self.book = book
        self.layout = layout
        self.usesLiquidGlass = usesLiquidGlass
    }

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
                    VStack(alignment: .leading, spacing: 5) {
                        Text(book.title)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        switch layout {
                        case .library:
                            HStack(spacing: 8) {
                                Text(authorText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Label(chapterText, systemImage: "bookmark.fill")
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        case .home:
                            Text(authorText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        case .list:
                            EmptyView()
                        }
                    }

                    Spacer(minLength: 6)

                    importStatusIndicator
                }

                if case .home = layout {
                    Label(chapterText, systemImage: "bookmark.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.top, 10)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(progressText)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)

                    progressBar
                }
                .padding(.top, 12)
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

    @ViewBuilder
    private var progressBar: some View {
        let progressView = ProgressView(value: progress)
            .progressViewStyle(
                BookCardProgressViewStyle(
                    usesLiquidGlass: usesLiquidGlass
                )
            )
            .frame(maxWidth: .infinity)
            .frame(height: BookCardProgressMetrics.height)
            .accessibilityLabel("阅读进度")
            .accessibilityValue(Text(progressText))

        progressView
    }

    private var authorText: String {
        let author = book.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return author.isEmpty ? "未知作者" : author
    }

    private var chapterText: String {
        switch book.importState {
        case .importing:
            return "正在导入…"
        case .failed:
            return "导入失败"
        case .ready:
            break
        }
        guard book.lastReadAt != nil else { return "尚未阅读" }

        let title = book.currentChapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "尚未阅读" : title
    }

    @ViewBuilder
    private var importStatusIndicator: some View {
        switch book.importState {
        case .importing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("正在导入")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("导入失败")
        case .ready:
            EmptyView()
        }
    }

    private var formatLabel: String {
        let formatName = book.format == .epub ? "EPUB" : "TXT"
        if book.chapterCount > 0 {
            return "\(formatName) · \(book.chapterCount) 章"
        }
        return formatName
    }
}

private enum BookCardProgressMetrics {
    static let height: CGFloat = 8
    static let minimumVisibleFillWidth: CGFloat = 12
    static let animationDuration: Double = 0.24
}

private struct BookCardProgressViewStyle: ProgressViewStyle {
    let usesLiquidGlass: Bool

    func makeBody(configuration: Configuration) -> some View {
        BookCardProgressTrack(
            progress: configuration.fractionCompleted ?? 0,
            usesLiquidGlass: usesLiquidGlass
        )
    }
}

private struct BookCardProgressTrack: View {
    let progress: Double
    let usesLiquidGlass: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    private var hasVisibleProgress: Bool {
        clampedProgress > 0
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                track

                if hasVisibleProgress {
                    progressFill(
                        width: fillWidth(for: geometry.size.width)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: BookCardProgressMetrics.height)
        .animation(
            reduceMotion
                ? nil
                : .smooth(duration: BookCardProgressMetrics.animationDuration),
            value: clampedProgress
        )
    }

    private func fillWidth(for totalWidth: CGFloat) -> CGFloat {
        let measuredWidth = totalWidth * clampedProgress
        return min(
            totalWidth,
            max(measuredWidth, BookCardProgressMetrics.minimumVisibleFillWidth)
        )
    }

    @ViewBuilder
    private var track: some View {
        if usesLiquidGlass {
            Color.clear
                .glassEffect(.regular, in: Capsule())
        } else {
            Capsule()
                .fill(Color(uiColor: .secondarySystemFill))
                .overlay {
                    Capsule()
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                }
        }
    }

    @ViewBuilder
    private func progressFill(width: CGFloat) -> some View {
        if usesLiquidGlass {
            Color.clear
                .frame(
                    width: width,
                    height: BookCardProgressMetrics.height
                )
                .glassEffect(
                    .regular.tint(.accentColor),
                    in: Capsule()
                )
        } else {
            Capsule()
                .fill(.tint)
                .frame(
                    width: width,
                    height: BookCardProgressMetrics.height
                )
        }
    }
}

/// 给主页和书库页的整卡按钮提供一个真正占满卡片的标签区域。
struct BookCardButtonLabel: View {
    let book: Book
    let layout: BookCardLayout
    let usesLiquidGlass: Bool

    init(book: Book, layout: BookCardLayout, usesLiquidGlass: Bool = true) {
        self.book = book
        self.layout = layout
        self.usesLiquidGlass = usesLiquidGlass
    }

    var body: some View {
        BookCard(
            book: book,
            layout: layout,
            usesLiquidGlass: usesLiquidGlass
        )
        .frame(
            maxWidth: .infinity,
            minHeight: BookCardMetrics.contentHeight,
            alignment: .leading
        )
        .contentShape(.interaction, BookCardMetrics.cardShape)
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
