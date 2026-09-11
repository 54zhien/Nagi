import Foundation
import Observation
import ReadiumNavigator
import ReadiumShared
import UIKit

struct EPUBTOCEntry: Identifiable {
    let id: String
    let title: String
    let depth: Int
    let link: ReadiumShared.Link
}

@MainActor
@Observable
final class EPUBReaderModel {
    private struct PageTurnLocationTransaction {
        let id: UUID
        let origin: Locator
        let target: Locator
        var deferred: Locator?
    }

    let book: Book

    var navigator: EPUBNavigatorViewController? { session.navigator }
    var isLoading = false
    var errorMessage: String?
    var title: String
    var chapterTitle = ""
    private(set) var currentReadingHref: String?
    private(set) var currentLocatorJSON: String?
    var progress = 0.0
    var tableOfContents: [EPUBTOCEntry] = []

    var currentTOCEntryID: String? {
        guard let currentReadingHref else { return nil }
        let currentResource = EPUBResourcePath.normalize(currentReadingHref)
        return tableOfContents.first {
            EPUBResourcePath.normalize($0.link.href) == currentResource
        }?.id
    }

    func pageHeaderTitle() -> String? {
        guard showBookTitleInPageHeader else { return nil }
        return title
    }

    var fontSizeLevel: Int { didSet { preferencesDidChange() } }
    var fontFamily: ReaderFontFamily { didSet { preferencesDidChange() } }
    var boldText: Bool { didSet { preferencesDidChange() } }
    var lineHeight: Double { didSet { preferencesDidChange() } }
    var pageMargins: Double { didSet { preferencesDidChange() } }
    var paragraphIndent: Double { didSet { preferencesDidChange() } }
    var characterSpacing: Double { didSet { preferencesDidChange() } }
    var wordSpacing: Double { didSet { preferencesDidChange() } }
    var theme: ReaderTheme { didSet { preferencesDidChange() } }
    var appearanceMode: ReaderAppearanceMode { didSet { preferencesDidChange() } }
    var pageTransition: ReaderPageTransition { didSet { persistPreferencesIfNeeded() } }
    var publisherStyles: Bool { didSet { preferencesDidChange() } }
    var showBookTitleInPageHeader: Bool { didSet { persistPreferencesIfNeeded() } }

    private(set) var previewText = ""
    private(set) var previewChapterTitle = ""
    private(set) var isLoadingPreview = false

    var readerContentUIColor: UIColor {
        resolvedAppearance.contentColor
    }

    var readerBackgroundUIColor: UIColor {
        resolvedAppearance.backgroundColor
    }

    var isReflowable: Bool { session.isReflowable }

    var onToggleControls: (() -> Void)?
    var onSwipeStart: (() -> Void)?
    var onPageTurnRequested: ((PageDirection) -> Void)?
    var onStateChange: (() -> Void)?
    @ObservationIgnored private var pageTurnLocationTransaction: PageTurnLocationTransaction?

    @ObservationIgnored
    private let session = ReadiumSession()
    private var publication: Publication? { session.publication }
    // TXT books use their generated EPUB asset here.
    private var activePublicationURL: URL? { session.publicationURL }
    @ObservationIgnored
    private let preferenceCoordinator = ReadiumPreferenceCoordinator()
    @ObservationIgnored
    private let documentStyler = ReadiumDocumentStyler()
    @ObservationIgnored
    private let delegateAdapter = ReadiumNavigatorDelegateAdapter()
    private var previewTask: Task<Void, Never>?
    private var previewResourceHref: String?
    private var hasLoaded = false
    private var suppressPreferenceUpdates = false
    // Keep the host's native page-turn policy across the async navigator
    // creation window. ReaderControllerRepresentable can disable Readium
    // before the navigator exists; applying only to `navigator` would lose
    // that first-open policy.
    private var nativePageTurnInteractionEnabled = true

    private var systemIsDark = false
    private var viewportSize = CGSize.zero
    private var viewportSafeAreaInsets: UIEdgeInsets?
    private var viewportDisplayScale: CGFloat = 0
    init(book: Book) {
        self.book = book
        title = book.title
        chapterTitle = book.currentChapterTitle ?? ""
        if let locatorJSON = book.readerLocatorJSON,
           let locator = try? Locator(jsonString: locatorJSON) {
            currentLocatorJSON = try? locator.jsonString()
        } else {
            // Ignore malformed or old locator data.
            currentLocatorJSON = nil
        }
        progress = min(max(book.progressPercent, 0), 1)

        // Preferences come from the shared store; the legacy `reader.epub.*`
        // keys are only ever read once, by the store's migration.
        let preferences = ReaderPreferencesStore.load() ?? ReaderPreferences()
        fontSizeLevel = ReaderFontSize.clampedLevel(preferences.fontSizeLevel)
        fontFamily = preferences.fontFamily
        boldText = preferences.boldText
        lineHeight = ReaderLayoutMetrics.clampLineHeight(preferences.lineHeight)
        pageMargins = ReaderLayoutMetrics.clampPageMargins(preferences.pageMargins)
        paragraphIndent = ReaderLayoutMetrics.fixedParagraphIndent
        characterSpacing = ReaderLayoutMetrics.clampCharacterSpacing(preferences.characterSpacing)
        wordSpacing = ReaderLayoutMetrics.clampWordSpacing(preferences.wordSpacing)
        theme = preferences.themePreset.paletteTheme
        appearanceMode = preferences.appearanceMode
        pageTransition = preferences.pageTransition
        publisherStyles = preferences.publisherStyles
        showBookTitleInPageHeader = preferences.showBookTitleInPageHeader
    }

    /// The stored reading position, resolved once the publication is open.
    private func initialReadingLocation(for publication: Publication) async -> Locator? {
        if let locatorJSON = book.readerLocatorJSON,
           let locator = try? Locator(jsonString: locatorJSON) {
            return locator
        }
        if book.format == .txt, progress > 0 {
            // Restore progress from TXT records created before Readium.
            currentLocatorJSON = nil
            return await publication.locate(progression: progress)
        }
        currentLocatorJSON = nil
        return nil
    }

    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let opened = try await session.open(
                book: book,
                preferences: { [weak self] in
                    guard let self else { return EPUBPreferences() }
                    return ReadiumPreferenceMapper.makePreferences(
                        from: self.readerPreferences,
                        appearance: self.resolvedAppearance,
                        isReflowable: self.isReflowable
                    )
                },
                initialLocation: { [weak self] publication in
                    await self?.initialReadingLocation(for: publication)
                }
            )
            guard let publication = session.publication else { return }
            let navigator = opened.navigator
            let initialLocation = opened.initialLocation
            // The library title is user-editable and is the source of truth for
            // reader chrome. Publication metadata must not restore the imported
            // title after the user renames a book.
            title = book.title

            delegateAdapter.host = self
            navigator.delegate = delegateAdapter
            navigator.addObserver(.drag(onStart: { [weak self] _ in
                self?.onSwipeStart?()
                return false
            }))
            navigator.isUserPageTurnInteractionEnabled = nativePageTurnInteractionEnabled
            preferenceCoordinator.attach(navigator)
            preferenceCoordinator.didCommit = { [weak self] generation in
                self?.refreshVisibleReaderOverrides(generation: generation)
            }
            documentStyler.attach(navigator)
            applyVisibleReaderBaseAppearance()
            refreshVisibleReaderOverrides()
            hasLoaded = true

            if currentReadingHref == nil, initialLocation == nil {
                currentReadingHref = publication.readingOrder.first?.href
            }
            loadPreviewIfNeeded()

            if let initialLocation {
                updateLocation(initialLocation)
            }

            await loadTableOfContents(from: publication)
        } catch is CancellationError {
            return
        } catch {
            let formatName = book.format == .txt ? "TXT" : "EPUB"
            errorMessage = "无法打开 \(formatName)：\(error.localizedDescription)"
        }
    }

    /// Waits for the affected visible content to settle.
    func waitForVisualUpdate(for kind: ReaderVisualMutationKind) async {
        guard navigator != nil, isReflowable else { return }

        await preferenceCoordinator.waitForPendingCommit()
        guard !Task.isCancelled else { return }

        let effectiveKind = kind == .full ? preferenceCoordinator.latestCommittedMutationKind : kind

        let generation = preferenceCoordinator.latestGeneration

        await documentStyler.waitForPendingVisibleUpdate()

        guard generation == preferenceCoordinator.latestGeneration, !Task.isCancelled else { return }

        guard effectiveKind != .geometry else {
            await Task.yield()
            return
        }

        await documentStyler.waitForReadiness(snapshot: styleSnapshot, kind: effectiveKind)
    }

    /// Re-applies Readium state after returning from the background.
    func restoreFromForeground(isDark: Bool) async {
        guard !Task.isCancelled, hasLoaded, navigator != nil else { return }

        systemIsDark = isDark
        applyVisibleReaderBaseAppearance()
        enqueuePreferencesMutation(kind: .full)
        preferenceCoordinator.flush()
        guard !Task.isCancelled else { return }

        await documentStyler.waitForPendingVisibleUpdate()
        guard !Task.isCancelled else { return }
        await waitForVisualUpdate(for: .full)
    }

    /// Copies the current position to the SwiftData model before dismissal.
    func flushReadingProgress() {
        guard hasLoaded else { return }
        synchronizeStoredChapterMetadata()
        book.progressPercent = min(max(progress, 0), 1)
        book.lastReadAt = .now
    }

    func saveProgress() {
        flushReadingProgress()
    }

    func go(to entry: EPUBTOCEntry) {
        guard let navigator else { return }
        Task { await navigator.go(to: entry.link, options: .animated) }
    }

    func updateSystemAppearance(isDark: Bool) {
        guard systemIsDark != isDark else { return }
        systemIsDark = isDark
        guard appearanceMode == .system else { return }
        schedulePreferencesCommit(kind: .theme, commitBehavior: .immediate)
    }

    func setNativePageTurnInteractionEnabled(_ enabled: Bool) {
        nativePageTurnInteractionEnabled = enabled
        navigator?.isUserPageTurnInteractionEnabled = enabled
    }

    func apply(preset: ReaderThemePreset) {
        withPreferenceUpdatesSuspended {
            theme = preset.paletteTheme
        }
        persistPreferences()
        schedulePreferencesCommit(kind: .theme, commitBehavior: .immediate)
    }

    var readerPreferences: ReaderPreferences {
        ReaderPreferences(
            fontSizeLevel: fontSizeLevel,
            fontFamily: fontFamily,
            boldText: boldText,
            lineHeight: lineHeight,
            paragraphSpacing: 10,
            pageMargins: pageMargins,
            paragraphIndent: ReaderLayoutMetrics.fixedParagraphIndent,
            characterSpacing: characterSpacing,
            wordSpacing: wordSpacing,
            publisherStyles: publisherStyles,
            themePreset: ReaderThemePreset(theme: theme),
            appearanceMode: appearanceMode,
            pageTransition: pageTransition,
            showBookTitleInPageHeader: showBookTitleInPageHeader
        )
    }

    func apply(
        preferences: ReaderPreferences,
        commitBehavior: ReaderPreferenceCommitBehavior = .coalesced
    ) {
        let previousPreferences = readerPreferences
        withPreferenceUpdatesSuspended {
            fontSizeLevel = ReaderFontSize.clampedLevel(preferences.fontSizeLevel)
            fontFamily = preferences.fontFamily
            boldText = preferences.boldText
            lineHeight = ReaderLayoutMetrics.clampLineHeight(preferences.lineHeight)
            pageMargins = ReaderLayoutMetrics.clampPageMargins(preferences.pageMargins)
            paragraphIndent = ReaderLayoutMetrics.fixedParagraphIndent
            characterSpacing = ReaderLayoutMetrics.clampCharacterSpacing(preferences.characterSpacing)
            wordSpacing = ReaderLayoutMetrics.clampWordSpacing(preferences.wordSpacing)
            publisherStyles = preferences.publisherStyles
            appearanceMode = preferences.appearanceMode
            pageTransition = preferences.pageTransition
            theme = preferences.themePreset.paletteTheme
            showBookTitleInPageHeader = preferences.showBookTitleInPageHeader
        }
        persistPreferences()
        schedulePreferencesCommit(
            kind: ReaderVisualMutationKind.diff(from: previousPreferences, to: readerPreferences),
            commitBehavior: commitBehavior
        )
        onStateChange?()
    }

    func tearDown() {
        preferenceCoordinator.cancel()
        documentStyler.cancel()
        previewTask?.cancel()
        previewTask = nil
        navigator?.delegate = nil
        onToggleControls = nil
        onSwipeStart = nil
        onPageTurnRequested = nil
    }

    private func loadTableOfContents(from publication: Publication) async {
        let links = (try? await publication.tableOfContents().get()) ?? []
        var entries: [EPUBTOCEntry] = []

        func append(_ links: [ReadiumShared.Link], depth: Int) {
            for (index, link) in links.enumerated() {
                let fallback = link.href.split(separator: "/").last.map(String.init) ?? "未命名章节"
                entries.append(EPUBTOCEntry(
                    id: "\(depth)-\(index)-\(link.href)",
                    title: link.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? fallback,
                    depth: depth,
                    link: link
                ))
                append(link.children, depth: depth + 1)
            }
        }

        append(links.isEmpty ? publication.readingOrder : links, depth: 0)
        tableOfContents = entries
        synchronizeStoredChapterMetadata()
    }

    /// Everything the injected scripts depend on.
    var styleSnapshot: ReadiumStyleSnapshot {
        let appearance = resolvedAppearance
        return ReadiumStyleSnapshot(
            backgroundColor: appearance.backgroundColor,
            contentColor: appearance.contentColor,
            fontFamily: fontFamily,
            lineHeight: lineHeight,
            characterSpacing: characterSpacing,
            wordSpacing: wordSpacing,
            publisherStyles: publisherStyles,
            themeMarker: appearance.readiumThemeMarker
        )
    }

    /// The appearance shared by the chrome, the UIKit host, Readium's
    /// preferences and the injected CSS.
    private var resolvedAppearance: ResolvedReaderAppearance {
        ReaderAppearanceResolver.resolve(
            theme: theme,
            appearanceMode: appearanceMode,
            systemIsDark: systemIsDark
        )
    }

    private func withPreferenceUpdatesSuspended(_ action: () -> Void) {
        suppressPreferenceUpdates = true
        action()
        suppressPreferenceUpdates = false
    }

    private func preferencesDidChange() {
        guard !suppressPreferenceUpdates else { return }
        persistPreferences()
        enqueuePreferencesMutation(kind: .full)
    }

    private func persistPreferencesIfNeeded() {
        guard !suppressPreferenceUpdates else { return }
        persistPreferences()
    }

    private func schedulePreferencesCommit(
        kind: ReaderVisualMutationKind = .full,
        commitBehavior: ReaderPreferenceCommitBehavior = .coalesced
    ) {
        enqueuePreferencesMutation(kind: kind)
        if commitBehavior == .immediate {
            preferenceCoordinator.flush()
        }
    }

    /// Queues an immutable preference snapshot.
    private func enqueuePreferencesMutation(kind: ReaderVisualMutationKind? = nil) {
        guard navigator != nil else { return }
        preferenceCoordinator.enqueue(
            ReadiumPreferenceMapper.makePreferences(
                from: readerPreferences,
                appearance: resolvedAppearance,
                isReflowable: isReflowable
            ),
            kind: kind
        )
    }

    private func applyVisibleReaderBaseAppearance() {
        documentStyler.applyBaseAppearance(
            snapshot: styleSnapshot,
            isReflowable: isReflowable
        )
    }

    /// Updates the visible spread before preloaded pages.
    private func refreshVisibleReaderOverrides(
        generation: UInt64? = nil
    ) {
        documentStyler.refreshOverrides(
            snapshot: styleSnapshot,
            isReflowable: isReflowable,
            isStillCurrent: { [weak self] in
                guard let generation else { return true }
                return self?.preferenceCoordinator.latestGeneration == generation
            }
        )
    }

    private func loadPreviewIfNeeded() {
        let fallbackHref = publication?.readingOrder.first?.href
        guard let href = currentReadingHref ?? fallbackHref else {
            previewText = "暂时无法载入正文预览"
            return
        }

        let normalizedHref = EPUBResourcePath.normalize(href)
        guard previewResourceHref != normalizedHref else { return }
        previewResourceHref = normalizedHref
        previewTask?.cancel()
        isLoadingPreview = true

        guard let sourceURL = activePublicationURL ?? BookFileLocator.resolve(book.sourceURL) else {
            isLoadingPreview = false
            previewText = "暂时无法载入正文预览"
            onStateChange?()
            return
        }
        previewTask = Task { [weak self] in
            let text = await Task.detached(priority: .userInitiated) {
                try? EPUBParser().loadChapterContent(url: sourceURL, href: normalizedHref)
            }.value

            guard !Task.isCancelled, let self else { return }
            self.isLoadingPreview = false
            guard let text, !text.isEmpty else {
                self.previewText = "暂时无法载入正文预览"
                self.onStateChange?()
                return
            }
            self.previewText = Self.previewExcerpt(from: text)
            self.previewChapterTitle = self.chapterTitle.isEmpty ? "当前章节" : self.chapterTitle
            self.onStateChange?()
        }
    }

    private static func previewExcerpt(from text: String) -> String {
        let paragraphs = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let cleaned = (paragraphs.isEmpty ? text : paragraphs.joined(separator: "\n\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 280 else { return cleaned }
        return String(cleaned.prefix(280)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func persistPreferences() {
        ReaderPreferencesStore.save(readerPreferences)
    }

    private static func themePreset(for theme: ReaderTheme) -> ReaderThemePreset {
        switch theme {
        case .quiet: return .quiet
        case .sepia: return .paper
        case .light, .dark: return .original
        }
    }

    @discardableResult
    func beginPageTurnLocationTransaction(origin: Locator, target: Locator) -> UUID {
        let id = UUID()
        pageTurnLocationTransaction = PageTurnLocationTransaction(
            id: id,
            origin: origin,
            target: target,
            deferred: nil
        )
        return id
    }

    func finishPageTurnLocationTransaction(
        id: UUID,
        result: NavigatorPageCommitResult?
    ) {
        guard let transaction = pageTurnLocationTransaction,
              transaction.id == id else { return }
        pageTurnLocationTransaction = nil
        let resolved: Locator?
        switch result {
        case .committed:
            resolved = transaction.target
        case .restored:
            resolved = transaction.origin
        case .indeterminate, nil:
            resolved = transaction.deferred
        }
        if let resolved {
            applyLocation(resolved)
        }
    }

    func cancelPageTurnLocationTransaction() {
        pageTurnLocationTransaction = nil
    }

    private func updateLocation(_ locator: Locator) {
        if pageTurnLocationTransaction != nil {
            pageTurnLocationTransaction?.deferred = locator
            return
        }
        applyLocation(locator)
    }

    private func applyLocation(_ locator: Locator) {
        let locatorTitle = locator.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let nextHref = locator.href.path
        let chapterChanged = currentReadingHref.map {
            EPUBResourcePath.normalize($0) != EPUBResourcePath.normalize(nextHref)
        } ?? true
        chapterTitle = locatorTitle ?? chapterTitle
        if locatorTitle == nil, chapterChanged {
            chapterTitle = ""
        }
        currentReadingHref = nextHref
        if let totalProgression = locator.locations.totalProgression {
            progress = min(max(totalProgression, 0), 1)
        }
        loadPreviewIfNeeded()
        if let locatorJSON = try? locator.jsonString() {
            currentLocatorJSON = locatorJSON
            book.readerLocatorJSON = locatorJSON
        }
        synchronizeStoredChapterMetadata(preferredTitle: locatorTitle)
        book.progressPercent = progress
        book.lastReadAt = .now
        onStateChange?()
    }

    private func synchronizeStoredChapterMetadata(preferredTitle: String? = nil) {
        if let currentIndex = currentTOCIndex {
            book.currentChapterIndex = currentIndex
            let normalizedTitle = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if let preferredTitle {
                chapterTitle = preferredTitle
            } else if normalizedTitle.isEmpty {
                chapterTitle = tableOfContents[currentIndex].title
            }
        } else if let preferredTitle {
            chapterTitle = preferredTitle
        }

        let normalizedTitle = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        book.currentChapterTitle = normalizedTitle.isEmpty ? nil : normalizedTitle
    }

    private var currentTOCIndex: Int? {
        guard let currentReadingHref else { return nil }
        let currentResource = EPUBResourcePath.normalize(currentReadingHref)
        return tableOfContents.firstIndex {
            EPUBResourcePath.normalize($0.link.href) == currentResource
        }
    }
}

extension EPUBReaderModel {
    /// Updates the cached host geometry and asks the navigator to relayout.
    @discardableResult
    func updateViewport(
        size: CGSize,
        safeAreaInsets: UIEdgeInsets,
        displayScale: CGFloat
    ) -> Bool {
        guard viewportSize != size
            || viewportSafeAreaInsets != safeAreaInsets
            || viewportDisplayScale != displayScale else {
            return false
        }

        viewportSize = size
        viewportSafeAreaInsets = safeAreaInsets
        viewportDisplayScale = displayScale
        navigator?.view.setNeedsLayout()
        return true
    }

    /// Returns the readable inset supplied by the UIKit host.
    func navigatorContentInset(_ navigator: VisualNavigator) -> UIEdgeInsets? {
        let contentInsets: UIEdgeInsets
        if let viewportSafeAreaInsets {
            contentInsets = viewportSafeAreaInsets
        } else {
            var fallbackSystemInsets = navigator.view.window?.safeAreaInsets
                ?? navigator.view.safeAreaInsets
            fallbackSystemInsets.top += CGFloat(
                ReaderLayoutMetrics.pageHeaderHeight
                    + ReaderLayoutMetrics.contentTopSpacing
            )
            let controlRadius = CGFloat(ReaderLayoutMetrics.chromeControlDiameter / 2)
            fallbackSystemInsets.bottom = max(controlRadius, fallbackSystemInsets.bottom)
                + controlRadius
                + CGFloat(ReaderLayoutMetrics.contentBottomControlSpacing)
            contentInsets = fallbackSystemInsets
        }
        return ReaderContentInsetResolver.resolve(
            safeAreaInsets: contentInsets,
            top: 0,
            bottom: 0,
            horizontal: 0
        )
    }
}

extension EPUBReaderModel: ReadiumNavigatorDelegateHost {
    var isFixedLayout: Bool {
        publication?.metadata.layout == .fixed
    }

    var overrideGeneration: UInt64 {
        documentStyler.currentGeneration
    }

    var navigatorViewWidth: CGFloat {
        navigator?.view.bounds.width ?? 0
    }

    func beginOverrideGenerationIfNeeded() {
        documentStyler.startGenerationIfNeeded()
    }

    func navigatorPresentationDidChange() {
        applyVisibleReaderBaseAppearance()
        refreshVisibleReaderOverrides()
        // ReaderViewController must re-evaluate gesture ownership after the
        // asynchronous paginated/continuous presentation switch settles.
        onStateChange?()
    }

    func navigatorLocationDidChange(_ locator: Locator) {
        updateLocation(locator)
    }

    func navigatorDidFail(_ error: NavigatorError) {
        errorMessage = "阅读器发生错误：\(error.localizedDescription)"
        onStateChange?()
    }

    func navigatorDidTap(atX x: CGFloat) {
        let width = navigatorViewWidth
        guard width > 0 else { return }

        switch PageTurnMetrics.edgeHit(atX: x, screenWidth: width) {
        case .left:
            if navigator?.isContinuousScrollEnabled == true {
                onToggleControls?()
            } else {
                let readingDirection: PageTurnReadingDirection = navigator?.pageReadingProgression == .rtl
                    ? .rightToLeft
                    : .leftToRight
                onPageTurnRequested?(
                    PageTurnMetrics.pageDirection(for: .left, readingDirection: readingDirection)
                )
            }
        case .right:
            if navigator?.isContinuousScrollEnabled == true {
                onToggleControls?()
            } else {
                let readingDirection: PageTurnReadingDirection = navigator?.pageReadingProgression == .rtl
                    ? .rightToLeft
                    : .leftToRight
                onPageTurnRequested?(
                    PageTurnMetrics.pageDirection(for: .right, readingDirection: readingDirection)
                )
            }
        case nil:
            onToggleControls?()
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
