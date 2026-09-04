import Foundation
import Observation
import ReadiumNavigator
import ReadiumShared
import UIKit
import WebKit

private extension ReaderTheme {
    func readiumTheme(isDarkAppearance: Bool) -> ReadiumNavigator.Theme {
        switch self {
        case .light:
            return .light
        case .quiet:
            return .dark
        case .sepia:
            return isDarkAppearance ? .dark : .sepia
        case .dark:
            return .dark
        }
    }
}

private extension ReaderFontFamily {
    var readiumFontFamily: FontFamily {
        FontFamily(rawValue: readiumFamilyName)
    }

    /// Readium's weight scale for the lighter system font.
    var readiumFontWeight: Double {
        self == .pingFang ? 0.75 : 1.0
    }
}

struct EPUBTOCEntry: Identifiable {
    let id: String
    let title: String
    let depth: Int
    let link: ReadiumShared.Link
}

@MainActor
@Observable
final class EPUBReaderModel {
    let book: Book

    var navigator: EPUBNavigatorViewController?
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
        let currentResource = normalizedResourceHref(currentReadingHref)
        return tableOfContents.first {
            normalizedResourceHref($0.link.href) == currentResource
        }?.id
    }

    var fontScale: Double { didSet { preferencesDidChange() } }
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

    /// Nil means the current settings are custom.
    var selectedPreset: ReaderThemePreset? { didSet { persistPreferencesIfNeeded() } }

    private(set) var previewText = ""
    private(set) var previewChapterTitle = ""
    private(set) var isLoadingPreview = false

    var readerContentUIColor: UIColor {
        resolvedTheme.readerContentUIColor(isDarkAppearance: isDarkAppearance)
    }

    var readerBackgroundUIColor: UIColor {
        resolvedTheme.readerBackgroundUIColor(isDarkAppearance: isDarkAppearance)
    }

    var isReflowable: Bool {
        guard let publication else { return false }
        return publication.metadata.layout != .fixed
    }

    var onToggleControls: (() -> Void)?
    var onSwipeStart: (() -> Void)?
    var onStateChange: (() -> Void)?

    private var publication: Publication?
    // TXT books use their generated EPUB asset here.
    private var activePublicationURL: URL?
    @ObservationIgnored
    private lazy var mutationScheduler = ReaderMutationScheduler<EPUBPreferences>(
        delayNanoseconds: 16_000_000
    ) { [weak self] preferences, generation in
        self?.commitPreferences(preferences, generation: generation)
    }
    private var readerOverrideRefreshTask: Task<Void, Never>?
    private var preloadedReaderOverrideTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewResourceHref: String?
    private var hasLoaded = false
    private var suppressPreferenceUpdates = false

    private var systemIsDark = false
    private var viewportSize = CGSize.zero
    private var viewportSafeAreaInsets: UIEdgeInsets?
    private var viewportDisplayScale: CGFloat = 0
    private var latestPreferenceGeneration: UInt64 = 0
    private var latestOverrideRequestGeneration: UInt64 = 0
    private var pendingVisualMutationKind: ReaderVisualMutationKind?
    private var latestCommittedVisualMutationKind: ReaderVisualMutationKind = .full

    private enum PreferenceKey {
        static let fontScale = "reader.epub.fontScale"
        static let fontFamily = "reader.epub.fontFamily"
        static let boldText = "reader.epub.boldText"
        static let lineHeight = "reader.epub.lineHeight"
        static let pageMargins = "reader.epub.pageMargins"
        static let pageMarginAdjustment = "reader.epub.pageMarginAdjustment"
        static let pageMarginPoints = "reader.epub.pageMarginPoints"
        static let paragraphIndent = "reader.epub.paragraphIndent"
        static let characterSpacing = "reader.epub.characterSpacing"
        static let wordSpacing = "reader.epub.wordSpacing"
        static let theme = "reader.epub.theme"
        static let appearanceMode = "reader.epub.appearanceMode"
        static let pageTransition = "reader.epub.pageTransition"
        static let publisherStyles = "reader.epub.publisherStyles"
        static let showBookTitleInPageHeader = "reader.epub.showBookTitleInPageHeader"
        static let selectedPreset = "reader.epub.selectedPreset"
    }

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

        let defaults = UserDefaults.standard
        let savedFontScale = defaults.object(forKey: PreferenceKey.fontScale) as? Double ?? 1.0
        fontScale = min(
            max(savedFontScale, ReaderFontSize.minimumScale),
            ReaderFontSize.maximumScale
        )
        fontFamily = defaults.string(forKey: PreferenceKey.fontFamily).flatMap(ReaderFontFamily.init) ?? .original
        boldText = defaults.object(forKey: PreferenceKey.boldText) as? Bool ?? false
        lineHeight = ReaderLayoutMetrics.clampLineHeight(
            defaults.object(forKey: PreferenceKey.lineHeight) as? Double
                ?? ReaderLayoutMetrics.defaultLineHeight
        )
        if let pageMargin = defaults.object(forKey: PreferenceKey.pageMarginPoints) as? Double {
            pageMargins = ReaderLayoutMetrics.clampPageMargins(pageMargin)
        } else if let adjustment = defaults.object(forKey: PreferenceKey.pageMarginAdjustment) as? Double {
            pageMargins = ReaderLayoutMetrics.migrateLegacyPageMarginAdjustment(adjustment)
        } else {
            pageMargins = ReaderLayoutMetrics.migrateLegacyPageMargins(
                defaults.object(forKey: PreferenceKey.pageMargins) as? Double
            )
        }
        paragraphIndent = ReaderLayoutMetrics.fixedParagraphIndent
        characterSpacing = ReaderLayoutMetrics.clampCharacterSpacing(
            defaults.object(forKey: PreferenceKey.characterSpacing) as? Double
                ?? ReaderLayoutMetrics.defaultCharacterSpacing
        )
        wordSpacing = ReaderLayoutMetrics.clampWordSpacing(
            defaults.object(forKey: PreferenceKey.wordSpacing) as? Double
                ?? ReaderLayoutMetrics.defaultWordSpacing
        )
        theme = defaults.string(forKey: PreferenceKey.theme).flatMap(ReaderTheme.init) ?? .light
        appearanceMode = defaults.string(forKey: PreferenceKey.appearanceMode)
            .flatMap(ReaderAppearanceMode.init) ?? .system
        pageTransition = defaults.string(forKey: PreferenceKey.pageTransition)
            .flatMap(ReaderPageTransition.init) ?? .slide
        publisherStyles = defaults.object(forKey: PreferenceKey.publisherStyles) as? Bool ?? false
        showBookTitleInPageHeader = defaults.object(forKey: PreferenceKey.showBookTitleInPageHeader) as? Bool ?? false
        selectedPreset = defaults.string(forKey: PreferenceKey.selectedPreset).flatMap(ReaderThemePreset.init)
        if selectedPreset == nil {
            selectedPreset = theme == .sepia ? .paper : (theme == .quiet ? .quiet : (theme == .light ? .original : nil))
        }
    }

    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let readingURL = try await ReaderAssetResolver.resolve(book: book)
            try Task.checkCancellation()
            let publication = try await ReadiumService.shared.openEPUB(
                at: readingURL
            )
            try Task.checkCancellation()
            activePublicationURL = readingURL
            self.publication = publication
            title = publication.metadata.title ?? book.title

            let initialLocation: Locator?
            if let locatorJSON = book.readerLocatorJSON,
               let locator = try? Locator(jsonString: locatorJSON) {
                initialLocation = locator
            } else if book.format == .txt, progress > 0 {
                // Restore progress from TXT records created before Readium.
                currentLocatorJSON = nil
                initialLocation = await publication.locate(progression: progress)
            } else {
                currentLocatorJSON = nil
                initialLocation = nil
            }
            try Task.checkCancellation()
            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initialLocation,
                config: .init(
                    preferences: makePreferences(),
                    disablePageTurnsWhileScrolling: true,
                    preloadPreviousPositionCount: 2,
                    preloadNextPositionCount: 6,
                    fontFamilyDeclarations: EPUBFontResources.declarations(),
                    readiumCSSRSProperties: CSSRSProperties(
                        pageGutter: CSSPxLength(ReaderLayoutMetrics.pageMarginBase)
                    )
                )
            )
            navigator.delegate = self
            navigator.addObserver(.drag(onStart: { [weak self] _ in
                self?.onSwipeStart?()
                return false
            }))
            self.navigator = navigator
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
        guard let navigator, isReflowable else { return }

        _ = await mutationScheduler.waitForPendingCommit()
        guard !Task.isCancelled else { return }

        let effectiveKind = kind == .full ? latestCommittedVisualMutationKind : kind

        let generation = latestPreferenceGeneration

        if let overrideTask = readerOverrideRefreshTask {
            await overrideTask.value
        }

        guard generation == latestPreferenceGeneration, !Task.isCancelled else { return }

        guard effectiveKind != .geometry else {
            await Task.yield()
            return
        }

        let readinessScript = makeVisualReadinessScript(for: effectiveKind)
        await navigator.waitForNagiReaderReadiness(readinessScript)
    }

    /// Re-applies Readium state after returning from the background.
    func restoreFromForeground(isDark: Bool) async {
        guard !Task.isCancelled, hasLoaded, navigator != nil else { return }

        systemIsDark = isDark
        applyVisibleReaderBaseAppearance()
        enqueuePreferencesMutation(kind: .full)
        mutationScheduler.flush()
        guard !Task.isCancelled else { return }

        if let refreshTask = readerOverrideRefreshTask {
            await refreshTask.value
        }
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

    private func goLeft() {
        guard let navigator else { return }
        Task { await navigator.goLeft(options: .animated) }
    }

    private func goRight() {
        guard let navigator else { return }
        Task { await navigator.goRight(options: .animated) }
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

    func apply(preset: ReaderThemePreset) {
        withPreferenceUpdatesSuspended {
            selectedPreset = preset
            theme = preset.paletteTheme
        }
        persistPreferences()
        schedulePreferencesCommit(kind: .theme, commitBehavior: .immediate)
    }

    var readerPreferences: ReaderPreferences {
        ReaderPreferences(
            fontSize: ReaderFontSize.defaultValue * fontScale,
            fontFamily: fontFamily,
            boldText: boldText,
            lineHeight: lineHeight,
            paragraphSpacing: 10,
            pageMargins: pageMargins,
            paragraphIndent: ReaderLayoutMetrics.fixedParagraphIndent,
            characterSpacing: characterSpacing,
            wordSpacing: wordSpacing,
            publisherStyles: publisherStyles,
            themePreset: Self.themePreset(for: theme),
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
            fontScale = min(
                max(preferences.fontSize / ReaderFontSize.defaultValue, ReaderFontSize.minimumScale),
                ReaderFontSize.maximumScale
            )
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
            selectedPreset = nil
        }
        persistPreferences()
        schedulePreferencesCommit(
            kind: Self.visualMutationKind(from: previousPreferences, to: readerPreferences),
            commitBehavior: commitBehavior
        )
        onStateChange?()
    }

    func tearDown() {
        mutationScheduler.cancel()
        readerOverrideRefreshTask?.cancel()
        readerOverrideRefreshTask = nil
        preloadedReaderOverrideTask?.cancel()
        preloadedReaderOverrideTask = nil
        previewTask?.cancel()
        previewTask = nil
        navigator?.delegate = nil
        onToggleControls = nil
        onSwipeStart = nil
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

    private var resolvedTheme: ReaderTheme {
        switch appearanceMode {
        case .light:
            return theme == .dark ? .light : theme
        case .dark:
            return theme == .light ? .dark : theme
        case .system:
            return systemIsDark
                ? (theme == .light ? .dark : theme)
                : (theme == .dark ? .light : theme)
        }
    }

    private var isDarkAppearance: Bool {
        switch appearanceMode {
        case .light:
            return false
        case .dark:
            return true
        case .system:
            return systemIsDark
        }
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
            mutationScheduler.flush()
        }
    }

    /// Queues an immutable preference snapshot.
    private func enqueuePreferencesMutation(kind: ReaderVisualMutationKind? = nil) {
        guard navigator != nil else { return }
        if let kind {
            pendingVisualMutationKind = pendingVisualMutationKind?.merged(with: kind) ?? kind
        }
        mutationScheduler.enqueue(makePreferences())
    }

    private func commitPreferences(_ preferences: EPUBPreferences, generation: UInt64) {
        guard let navigator else { return }
        let mutationKind = pendingVisualMutationKind ?? .full
        pendingVisualMutationKind = nil
        latestCommittedVisualMutationKind = mutationKind
        latestPreferenceGeneration = generation
        navigator.submitPreferences(preferences)
        refreshVisibleReaderOverrides(generation: generation)
    }

    private static func visualMutationKind(
        from previous: ReaderPreferences,
        to next: ReaderPreferences
    ) -> ReaderVisualMutationKind {
        var kind: ReaderVisualMutationKind?

        func include(_ candidate: ReaderVisualMutationKind) {
            kind = kind?.merged(with: candidate) ?? candidate
        }

        if previous.themePreset != next.themePreset
            || previous.appearanceMode != next.appearanceMode {
            include(.theme)
        }

        if previous.fontSize != next.fontSize
            || previous.fontFamily != next.fontFamily
            || previous.boldText != next.boldText {
            include(.font)
        }

        if previous.lineHeight != next.lineHeight
            || previous.characterSpacing != next.characterSpacing
            || previous.wordSpacing != next.wordSpacing
            || previous.publisherStyles != next.publisherStyles {
            include(.typography)
        }

        if previous.pageMargins != next.pageMargins
            || previous.paragraphIndent != next.paragraphIndent
            || previous.pageTransition != next.pageTransition
            || previous.showBookTitleInPageHeader != next.showBookTitleInPageHeader {
            include(.geometry)
        }

        return kind ?? .full
    }

    private func makePreferences() -> EPUBPreferences {
        let effectiveTheme = resolvedTheme
        let navigatorBackgroundColor: ReadiumNavigator.Color? = isReflowable
            ? nil
            : ReadiumNavigator.Color(
                uiColor: effectiveTheme.readerBackgroundUIColor(isDarkAppearance: isDarkAppearance)
            )
        let preferences = EPUBPreferences(
            // ReaderChrome owns reflowable backgrounds.
            backgroundColor: navigatorBackgroundColor,
            // Publisher styles only disable the app-owned typography rules.
            fontFamily: fontFamily.readiumFontFamily,
            fontSize: fontScale,
            fontWeight: boldText ? 1.75 : fontFamily.readiumFontWeight,
            letterSpacing: nil,
            lineHeight: nil,
            pageMargins: ReaderLayoutMetrics.pageMarginFactor(for: pageMargins),
            paragraphIndent: ReaderLayoutMetrics.fixedParagraphIndent,
            publisherStyles: publisherStyles,
            scroll: pageTransition == .scroll,
            spread: .auto,
            textColor: ReadiumNavigator.Color(
                uiColor: effectiveTheme.readerContentUIColor(isDarkAppearance: isDarkAppearance)
            ),
            textNormalization: !publisherStyles,
            theme: effectiveTheme.readiumTheme(isDarkAppearance: isDarkAppearance),
            wordSpacing: nil
        )
        return preferences
    }

    private func applyVisibleReaderBaseAppearance() {
        guard let navigator else { return }
        navigator.applyNagiReaderBaseAppearance(
            isReflowable: isReflowable,
            fallbackBackground: readerBackgroundUIColor
        )
    }

    /// Updates the visible spread before preloaded pages.
    private func refreshVisibleReaderOverrides(
        generation: UInt64? = nil
    ) {
        readerOverrideRefreshTask?.cancel()
        preloadedReaderOverrideTask?.cancel()
        preloadedReaderOverrideTask = nil
        guard let navigator, isReflowable else { return }

        latestOverrideRequestGeneration &+= 1
        let requestGeneration = latestOverrideRequestGeneration
        let script = makeReaderOverrideScript(requestGeneration: requestGeneration)
        readerOverrideRefreshTask = Task { @MainActor [weak self, weak navigator] in
            guard let self, let navigator else { return }
            guard self.latestOverrideRequestGeneration == requestGeneration else { return }
            if let generation {
                guard self.latestPreferenceGeneration == generation else { return }
            }
            await navigator.applyNagiReaderOverridesToVisible(script)
            if let generation {
                guard !Task.isCancelled,
                      self.latestOverrideRequestGeneration == requestGeneration,
                      self.latestPreferenceGeneration == generation else { return }
            } else {
                guard !Task.isCancelled,
                      self.latestOverrideRequestGeneration == requestGeneration else { return }
            }

            self.preloadedReaderOverrideTask = Task { @MainActor [weak self, weak navigator] in
                // Let the visible document render before touching preloaded pages.
                await Task.yield()
                guard let self, let navigator,
                      !Task.isCancelled,
                      self.latestOverrideRequestGeneration == requestGeneration else { return }
                if let generation {
                    guard self.latestPreferenceGeneration == generation else { return }
                }
                await navigator.applyNagiReaderOverridesToPreloaded(script)
            }

        }
    }

    private func makeReaderOverrideScript(requestGeneration: UInt64) -> String {
        let publisherFontFamily = Self.javascriptStringLiteral(
            Self.cssFontFamilyValue(for: fontFamily)
        )
        let lineHeightValue = Self.javascriptStringLiteral(
            Self.cssDecimal(ReaderLayoutMetrics.clampLineHeight(lineHeight))
        )
        let letterSpacingValue = Self.javascriptStringLiteral(
            Self.cssEmSpacing(for: characterSpacing, range: ReaderLayoutMetrics.characterSpacingRange)
        )
        let wordSpacingValue = Self.javascriptStringLiteral(
            Self.cssEmSpacing(for: wordSpacing, range: ReaderLayoutMetrics.wordSpacingRange)
        )
        let typographyEnabled = publisherStyles ? "false" : "true"
        let themeMarker = Self.javascriptStringLiteral(readiumThemeAppearanceMarker ?? "light")
        let overrideGeneration = String(requestGeneration)
        return """
        (() => {
            const styleID = "nagi-reader-reader-overrides";
            const styleVersion = "2";
            const requestGeneration = \(overrideGeneration);
            const appFontFamily = \(publisherFontFamily);
            const lineHeight = \(lineHeightValue);
            const letterSpacing = \(letterSpacingValue);
            const wordSpacing = \(wordSpacingValue);
            const typographyEnabled = \(typographyEnabled);
            const themeMarker = \(themeMarker);
            const root = document.documentElement;

            if (!root || !document.body) {
                return;
            }

            const appliedGeneration = Number(
                root.getAttribute("data-nagi-reader-override-generation") || "0"
            );
            if (requestGeneration > 0 && appliedGeneration > requestGeneration) {
                return;
            }
            if (requestGeneration > 0) {
                root.setAttribute(
                    "data-nagi-reader-override-generation",
                    String(requestGeneration)
                );
            }

            root.setAttribute("data-nagi-reader-overrides", "true");
            root.setAttribute("data-nagi-reader-theme-marker", themeMarker);
            root.style.setProperty("--nagi-line-height", lineHeight);
            root.style.setProperty("--nagi-letter-spacing", letterSpacing);
            root.style.setProperty("--nagi-word-spacing", wordSpacing);
            root.style.setProperty("--nagi-font-family", appFontFamily);

            if (typographyEnabled) {
                root.setAttribute("data-nagi-reader-typography", "app");
            } else {
                root.removeAttribute("data-nagi-reader-typography");
            }
            root.setAttribute("data-nagi-reader-font", "app");

            let style = document.getElementById(styleID);
            if (!style || style.getAttribute("data-nagi-reader-style-version") !== styleVersion) {
                if (style) style.remove();
                style = document.createElement("style");
                style.id = styleID;
                style.setAttribute("data-nagi-reader-style-version", styleVersion);

                const rootSelector = ":root[data-nagi-reader-overrides]";
                const bodySelector = rootSelector + " body";
                const excludedSubtreeSelector = [
                    ":not(code)", ":not(code *)",
                    ":not(pre)", ":not(pre *)",
                    ":not(kbd)", ":not(kbd *)",
                    ":not(samp)", ":not(samp *)",
                    ":not(svg)", ":not(svg *)",
                    ":not(math)", ":not(math *)",
                    ":not([data-nagi-reader-preserve])",
                    ":not([data-nagi-reader-special])",
                    ":not(.icon)", ":not(.iconfont)", ":not(.icon-font)",
                    ":not([class^='icon-'])",
                    ":not([class*=' icon-'])"
                ].join("");
                const contentSelectors = [
                    "body",
                    "body *"
                ].map(selector => selector + excludedSubtreeSelector);
                const appFontSelectors = contentSelectors.map(
                    selector => rootSelector + "[data-nagi-reader-font='app'] " + selector
                );
                const appTypographySelectors = contentSelectors.map(
                    selector => rootSelector + "[data-nagi-reader-typography='app'] " + selector
                );

                style.textContent = [
                    [rootSelector, bodySelector].join(", ")
                        + " { background: transparent !important; background-image: none !important; }",
                    rootSelector + " {"
                        + " --nagi-line-height: 1;"
                        + " --nagi-letter-spacing: 0em;"
                        + " --nagi-word-spacing: 0em;"
                        + " --nagi-font-family: -apple-system, sans-serif;"
                        + " }",
                    appFontSelectors.join(", ")
                        + " { font-family: var(--nagi-font-family) !important; }",
                    appTypographySelectors.join(", ")
                        + " { line-height: var(--nagi-line-height) !important;"
                        + " letter-spacing: var(--nagi-letter-spacing) !important;"
                        + " word-spacing: var(--nagi-word-spacing) !important; }"
                ].join("\\n");
                (document.head || root).appendChild(style);
            }
        })();
        """
    }

    private func makeVisualReadinessScript(for kind: ReaderVisualMutationKind) -> String {
        let expectedTextColor = Self.javascriptStringLiteral(
            Self.cssColorLiteral(readerContentUIColor)
        )
        let expectedThemeMarker = Self.javascriptStringLiteral(
            readiumThemeAppearanceMarker ?? "light"
        )
        let expectedFontFamily = Self.javascriptStringLiteral(fontFamily.readiumFamilyName)
        let expectedLineHeight = Self.cssDecimal(
            ReaderLayoutMetrics.clampLineHeight(lineHeight)
        )
        let expectedLetterSpacing = Self.cssDecimal(
            min(max(characterSpacing, ReaderLayoutMetrics.characterSpacingRange.lowerBound),
                ReaderLayoutMetrics.characterSpacingRange.upperBound) / 100
        )
        let expectedWordSpacing = Self.cssDecimal(
            min(max(wordSpacing, ReaderLayoutMetrics.wordSpacingRange.lowerBound),
                ReaderLayoutMetrics.wordSpacingRange.upperBound) / 100
        )
        let typographyEnabled = publisherStyles ? "false" : "true"
        let mutationKind: String
        switch kind {
        case .theme: mutationKind = "theme"
        case .typography: mutationKind = "typography"
        case .font: mutationKind = "font"
        case .geometry: mutationKind = "geometry"
        case .full: mutationKind = "full"
        }

        return """
        (() => {
            const root = document.documentElement;
            const body = document.body;
            if (!root || !body) {
                return "";
            }

            const rootStyle = getComputedStyle(root);
            const bodyStyle = getComputedStyle(body);
            const sample = body.querySelector(
                "p, li, div, dt, dd, blockquote, section, article, span, td, th"
            ) || body;
            const sampleStyle = getComputedStyle(sample);
            const expectedThemeMarker = \(expectedThemeMarker);
            const expectedTextColor = \(expectedTextColor);
            const expectedFontFamily = \(expectedFontFamily);
            const expectedLineHeight = \(expectedLineHeight);
            const expectedLetterSpacing = \(expectedLetterSpacing);
            const expectedWordSpacing = \(expectedWordSpacing);
            const typographyEnabled = \(typographyEnabled);
            const mutationKind = "\(mutationKind)";

            const isTransparent = (value) => {
                const normalized = value.replace(/\\s+/g, "").toLowerCase();
                return normalized === "transparent" || normalized === "rgba(0,0,0,0)";
            };

            const normalizeColor = (value) => {
                const probe = document.createElement("span");
                probe.style.color = value;
                probe.style.position = "fixed";
                probe.style.visibility = "hidden";
                document.body.appendChild(probe);
                const normalized = getComputedStyle(probe).color;
                probe.remove();
                return normalized.replace(/\\s+/g, "").toLowerCase();
            };

            const approximately = (value, expected, tolerance) => {
                const number = parseFloat(value);
                return Number.isFinite(number) && Math.abs(number - expected) <= tolerance;
            };

            const fontReady = [
                rootStyle.fontFamily,
                bodyStyle.fontFamily,
                sampleStyle.fontFamily
            ].some(value => value.toLowerCase().includes(expectedFontFamily.toLowerCase()));

            const expectedColor = normalizeColor(expectedTextColor);
            const textReady = [bodyStyle.color, sampleStyle.color]
                .every(value => normalizeColor(value) === expectedColor);

            const themeReady = root.getAttribute("data-nagi-reader-theme-marker")
                === expectedThemeMarker;

            const sampleFontSize = parseFloat(sampleStyle.fontSize)
                || parseFloat(bodyStyle.fontSize)
                || 16;
            const lineHeightReady = approximately(sampleStyle.lineHeight, expectedLineHeight, 0.02)
                || approximately(
                    sampleStyle.lineHeight,
                    expectedLineHeight * sampleFontSize,
                    0.5
                );
            const letterSpacingReady = approximately(
                sampleStyle.letterSpacing,
                expectedLetterSpacing * sampleFontSize,
                0.25
            );
            const wordSpacingReady = approximately(
                sampleStyle.wordSpacing,
                expectedWordSpacing * sampleFontSize,
                0.25
            );
            const typographyReady = !typographyEnabled || (
                root.getAttribute("data-nagi-reader-typography") === "app"
                    && lineHeightReady
                    && letterSpacingReady
                    && wordSpacingReady
            );
            const appFontReady = root.getAttribute("data-nagi-reader-font") === "app"
                && fontReady;
            const surfaceReady = root.getAttribute("data-nagi-reader-overrides") === "true"
                && isTransparent(rootStyle.backgroundColor)
                && isTransparent(bodyStyle.backgroundColor)
                && rootStyle.backgroundImage === "none"
                && bodyStyle.backgroundImage === "none";

            if (!surfaceReady) return "";
            if (mutationKind === "theme") return themeReady && textReady ? "ready" : "";
            if (mutationKind === "font") return appFontReady ? "ready" : "";
            if (mutationKind === "typography") return typographyReady ? "ready" : "";
            return themeReady && textReady && appFontReady && typographyReady
                ? "ready"
                : "";
        })();
        """
    }

    private var readiumThemeAppearanceMarker: String? {
        switch resolvedTheme.readiumTheme(isDarkAppearance: isDarkAppearance) {
        case .light:
            return nil
        case .dark:
            return "readium-night-on"
        case .sepia:
            return "readium-sepia-on"
        }
    }

    private static func cssDecimal(_ value: Double) -> String {
        String(format: "%.4f", value).replacingOccurrences(of: ",", with: ".")
    }

    private static func cssEmSpacing(
        for value: Double,
        range: ClosedRange<Double>
    ) -> String {
        let clampedValue = min(max(value, range.lowerBound), range.upperBound)
        return "\(cssDecimal(clampedValue / 100))em"
    }

    private static func cssFontFamilyValue(for family: ReaderFontFamily) -> String {
        switch family {
        case .original, .pingFang:
            return "-apple-system, BlinkMacSystemFont, sans-serif"
        case .song, .kai, .yuan:
            return "\(family.readiumFamilyName), -apple-system, sans-serif"
        }
    }

    private static func cssColorLiteral(_ color: UIColor) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1

        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            let components = [red, green, blue].map { Int((min(max($0, 0), 1) * 255).rounded()) }
            let redValue = components[0]
            let greenValue = components[1]
            let blueValue = components[2]
            if alpha >= 0.999 {
                return "rgb(\(redValue), \(greenValue), \(blueValue))"
            }
            return "rgba(\(redValue), \(greenValue), \(blueValue), \(cssDecimal(Double(alpha))))"
        }

        var white: CGFloat = 0
        if color.getWhite(&white, alpha: &alpha) {
            let value = Int((min(max(white, 0), 1) * 255).rounded())
            if alpha >= 0.999 {
                return "rgb(\(value), \(value), \(value))"
            }
            return "rgba(\(value), \(value), \(value), \(cssDecimal(Double(alpha))))"
        }

        return "rgb(18, 18, 18)"
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [value]),
            let encoded = String(data: data, encoding: .utf8),
            encoded.count >= 2
        else {
            return "\"\""
        }
        return String(encoded.dropFirst().dropLast())
    }

    private func loadPreviewIfNeeded() {
        let fallbackHref = publication?.readingOrder.first?.href
        guard let href = currentReadingHref ?? fallbackHref else {
            previewText = "暂时无法载入正文预览"
            return
        }

        let normalizedHref = normalizedResourceHref(href)
        guard previewResourceHref != normalizedHref else { return }
        previewResourceHref = normalizedHref
        previewTask?.cancel()
        isLoadingPreview = true

        let sourceURL = activePublicationURL ?? URL(fileURLWithPath: book.sourceURL)
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
        let defaults = UserDefaults.standard
        defaults.set(fontScale, forKey: PreferenceKey.fontScale)
        defaults.set(fontFamily.rawValue, forKey: PreferenceKey.fontFamily)
        defaults.set(boldText, forKey: PreferenceKey.boldText)
        defaults.set(lineHeight, forKey: PreferenceKey.lineHeight)
        defaults.set(pageMargins, forKey: PreferenceKey.pageMarginPoints)
        defaults.set(ReaderLayoutMetrics.fixedParagraphIndent, forKey: PreferenceKey.paragraphIndent)
        defaults.set(characterSpacing, forKey: PreferenceKey.characterSpacing)
        defaults.set(wordSpacing, forKey: PreferenceKey.wordSpacing)
        defaults.set(theme.rawValue, forKey: PreferenceKey.theme)
        defaults.set(appearanceMode.rawValue, forKey: PreferenceKey.appearanceMode)
        defaults.set(pageTransition.rawValue, forKey: PreferenceKey.pageTransition)
        defaults.set(publisherStyles, forKey: PreferenceKey.publisherStyles)
        defaults.set(showBookTitleInPageHeader, forKey: PreferenceKey.showBookTitleInPageHeader)
        defaults.set(selectedPreset?.rawValue, forKey: PreferenceKey.selectedPreset)
    }

    private static func themePreset(for theme: ReaderTheme) -> ReaderThemePreset {
        switch theme {
        case .quiet: return .quiet
        case .sepia: return .paper
        case .light, .dark: return .original
        }
    }

    private func updateLocation(_ locator: Locator) {
        let locatorTitle = locator.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let nextHref = locator.href.path
        let chapterChanged = currentReadingHref.map {
            normalizedResourceHref($0) != normalizedResourceHref(nextHref)
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
        let currentResource = normalizedResourceHref(currentReadingHref)
        return tableOfContents.firstIndex {
            normalizedResourceHref($0.link.href) == currentResource
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
            if showBookTitleInPageHeader {
                fallbackSystemInsets.top += CGFloat(ReaderLayoutMetrics.pageHeaderHeight)
            }
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

private func normalizedResourceHref(_ href: String) -> String {
    let resource = href.split(whereSeparator: { $0 == "#" || $0 == "?" }).first.map(String.init) ?? href
    var decoded = resource.removingPercentEncoding ?? resource
    while decoded.hasPrefix("/") {
        decoded.removeFirst()
    }
    return decoded
}

extension EPUBReaderModel: EPUBNavigatorDelegate {
    func navigator(_ navigator: VisualNavigator, presentationDidChange presentation: VisualNavigatorPresentation) {
        applyVisibleReaderBaseAppearance()
        refreshVisibleReaderOverrides()
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        updateLocation(locator)
    }

    func navigator(_ navigator: Navigator, didJumpTo locator: Locator) {
        updateLocation(locator)
    }

    func navigator(
        _ navigator: EPUBNavigatorViewController,
        setupUserScripts userContentController: WKUserContentController
    ) {
        guard publication?.metadata.layout != .fixed else { return }
        if latestOverrideRequestGeneration == 0 {
            latestOverrideRequestGeneration = 1
        }
        userContentController.addUserScript(
            WKUserScript(
                source: makeReaderOverrideScript(
                    requestGeneration: latestOverrideRequestGeneration
                ),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        errorMessage = "阅读器发生错误：\(error.localizedDescription)"
        onStateChange?()
    }

    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        let width = self.navigator?.view.bounds.width ?? 0
        guard width > 0 else { return }

        switch point.x / width {
        case ..<0.25:
            goLeft()
        case 0.75...:
            goRight()
        default:
            onToggleControls?()
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
