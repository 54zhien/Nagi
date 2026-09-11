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
    var currentReadingHref: String? { navigation.currentHref }
    var currentLocatorJSON: String? { navigation.currentLocatorJSON }
    var progress: Double { navigation.progress }
    var tableOfContents: [EPUBTOCEntry] { navigation.tableOfContents }

    var currentTOCEntryID: String? { navigation.currentTOCEntryID }

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

    var previewText: String { preview.text }
    var previewChapterTitle: String { preview.chapterTitle }
    var isLoadingPreview: Bool { preview.isLoading }

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
    @ObservationIgnored
    private let navigation = ReadiumNavigationController()
    private var publication: Publication? { session.publication }
    // TXT books use their generated EPUB asset here.
    private var activePublicationURL: URL? { session.publicationURL }
    @ObservationIgnored
    private let preferenceCoordinator = ReadiumPreferenceCoordinator()
    @ObservationIgnored
    private let documentStyler = ReadiumDocumentStyler()
    @ObservationIgnored
    private let delegateAdapter = ReadiumNavigatorDelegateAdapter()
    @ObservationIgnored
    private let preview = EPUBPreviewProvider()
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
        let restoredLocatorJSON: String?
        if let locatorJSON = book.readerLocatorJSON,
           let locator = try? Locator(jsonString: locatorJSON) {
            restoredLocatorJSON = try? locator.jsonString()
        } else {
            // Ignore malformed or old locator data.
            restoredLocatorJSON = nil
        }
        navigation.restore(
            locatorJSON: restoredLocatorJSON,
            progress: book.progressPercent
        )

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
            navigation.clearLocatorJSON()
            return await publication.locate(progression: progress)
        }
        navigation.clearLocatorJSON()
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
            navigation.attach(navigator)
            preview.didChange = { [weak self] in self?.onStateChange?() }
            applyVisibleReaderBaseAppearance()
            refreshVisibleReaderOverrides()
            hasLoaded = true

            if currentReadingHref == nil, initialLocation == nil {
                navigation.seedCurrentHref(publication.readingOrder.first?.href)
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
        navigation.go(to: entry)
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
        preview.cancel()
        navigator?.delegate = nil
        onToggleControls = nil
        onSwipeStart = nil
        onPageTurnRequested = nil
    }

    private func loadTableOfContents(from publication: Publication) async {
        await navigation.loadTableOfContents(from: publication)
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
        preview.loadIfNeeded(
            href: currentReadingHref ?? publication?.readingOrder.first?.href,
            sourceURL: activePublicationURL ?? BookFileLocator.resolve(book.sourceURL),
            currentChapterTitle: { [weak self] in self?.chapterTitle ?? "" }
        )
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
        let update = navigation.apply(locator: locator)

        chapterTitle = update.locatorTitle ?? chapterTitle
        if update.locatorTitle == nil, update.chapterChanged {
            chapterTitle = ""
        }
        loadPreviewIfNeeded()
        if let locatorJSON = update.locatorJSON {
            book.readerLocatorJSON = locatorJSON
        }
        synchronizeStoredChapterMetadata(preferredTitle: update.locatorTitle)
        book.progressPercent = navigation.progress
        book.lastReadAt = .now
        onStateChange?()
    }

    private func synchronizeStoredChapterMetadata(preferredTitle: String? = nil) {
        if let currentIndex = navigation.currentTOCIndex {
            book.currentChapterIndex = currentIndex
            let normalizedTitle = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if let preferredTitle {
                chapterTitle = preferredTitle
            } else if normalizedTitle.isEmpty {
                chapterTitle = navigation.tableOfContents[currentIndex].title
            }
        } else if let preferredTitle {
            chapterTitle = preferredTitle
        }

        let normalizedTitle = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        book.currentChapterTitle = normalizedTitle.isEmpty ? nil : normalizedTitle
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

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
