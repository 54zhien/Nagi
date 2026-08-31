//
//  EPUBReaderModel.swift
//  Nagi
//
//  Readium EPUB 阅读状态、用户偏好、目录与稳定阅读位置。
//

import Foundation
import Observation
import ReadiumNavigator
import ReadiumShared
import UIKit
import WebKit

enum EPUBReaderTheme: String, CaseIterable, Identifiable, Equatable {
    case light, quiet, sepia, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "白色"
        case .quiet: return "安静"
        case .sepia: return "米黄"
        case .dark: return "深色"
        }
    }

    /// 与 Readium CSS 内置主题使用的正文色保持一致，供嵌入式页眉复用。
    var contentUIColor: UIColor {
        switch self {
        case .light:
            return ReaderThemePalette.originalLightContent
        case .quiet:
            return ReaderThemePalette.quietContent
        case .sepia:
            return ReaderThemePalette.paperLightContent
        case .dark:
            return ReaderThemePalette.originalDarkContent
        }
    }

    var backgroundUIColor: UIColor {
        switch self {
        case .light:
            return ReaderThemePalette.originalLightBackground
        case .quiet:
            return ReaderThemePalette.quietBackground
        case .sepia:
            return ReaderThemePalette.paperLightBackground
        case .dark:
            return ReaderThemePalette.originalDarkBackground
        }
    }

    func readerBackgroundUIColor(isDarkAppearance: Bool) -> UIColor {
        switch self {
        case .light:
            return isDarkAppearance
                ? ReaderThemePalette.originalDarkBackground
                : ReaderThemePalette.originalLightBackground
        case .quiet:
            return isDarkAppearance
                ? ReaderThemePalette.quietDarkBackground
                : ReaderThemePalette.quietBackground
        case .sepia:
            return isDarkAppearance
                ? ReaderThemePalette.paperDarkBackground
                : ReaderThemePalette.paperLightBackground
        case .dark:
            return ReaderThemePalette.originalDarkBackground
        }
    }

    func readerContentUIColor(isDarkAppearance: Bool) -> UIColor {
        switch self {
        case .light:
            return isDarkAppearance
                ? ReaderThemePalette.originalDarkContent
                : ReaderThemePalette.originalLightContent
        case .quiet:
            return ReaderThemePalette.quietContent
        case .sepia:
            return isDarkAppearance
                ? ReaderThemePalette.paperDarkContent
                : ReaderThemePalette.paperLightContent
        case .dark:
            return ReaderThemePalette.originalDarkContent
        }
    }

    func readiumTheme(isDarkAppearance: Bool) -> ReadiumNavigator.Theme {
        switch self {
        case .light: return .light
        case .quiet: return .dark
        case .sepia: return isDarkAppearance ? .dark : .sepia
        case .dark: return .dark
        }
    }

    /// Compatibility entry points for older renderer code. Brightness is now
    /// controlled by the device and never changes these reader colors.
    func adjustedBackgroundUIColor(brightness _: Double) -> UIColor {
        readerBackgroundUIColor(isDarkAppearance: false)
    }

    func adjustedContentUIColor(brightness _: Double) -> UIColor {
        readerContentUIColor(isDarkAppearance: false)
    }
}

enum EPUBAppearanceMode: String, CaseIterable, Identifiable, Equatable {
    case light, dark, system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "浅色"
        case .dark: return "深色"
        case .system: return "匹配设备"
        }
    }

    var systemImage: String {
        switch self {
        case .light: return "sunrise.fill"
        case .dark: return "sunset.fill"
        case .system: return "circle.lefthalf.filled"
        }
    }
}

enum EPUBReaderPreset: String, CaseIterable, Identifiable, Equatable {
    case original, quiet, paper

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "原始"
        case .quiet: return "安静"
        case .paper: return "纸张"
        }
    }

    var systemImage: String {
        switch self {
        case .original: return "textformat"
        case .quiet: return "moon.zzz"
        case .paper: return "doc.text"
        }
    }
}

enum EPUBFlowMode: String, CaseIterable, Identifiable, Equatable {
    case paged, scroll

    var id: String { rawValue }
    var label: String { self == .paged ? "横向分页" : "上下滚动" }
}

enum EPUBPageTransitionMode: String, CaseIterable, Identifiable, Equatable {
    case slide, pageCurl, fade, scroll

    var id: String { rawValue }

    var label: String {
        switch self {
        case .slide: return "滑动"
        case .pageCurl: return "卷页"
        case .fade: return "淡化"
        case .scroll: return "滚动"
        }
    }

    var systemImage: String {
        switch self {
        case .slide:
            return ReaderSystemSymbol.name(
                "arrow.left.page.on.rectangle",
                fallback: "arrow.left.arrow.right"
            )
        case .pageCurl:
            return ReaderSystemSymbol.name("book.pages", fallback: "book")
        case .fade:
            return ReaderSystemSymbol.name(
                "rectangle.on.rectangle.transition",
                fallback: "rectangle.on.rectangle"
            )
        case .scroll:
            return ReaderSystemSymbol.name(
                "arrow.up.and.down.text.horizontal",
                fallback: "arrow.up.and.down"
            )
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "slide": self = .slide
        case "pageCurl": self = .pageCurl
        case "fade": self = .fade
        case "scroll": self = .scroll
        // Preserve values written by the earlier settings screen.
        case "cover": self = .pageCurl
        default: return nil
        }
    }
}

/// Legacy name kept so the older EPUB view continues to share the exact same
/// five-option catalogue as the active reader settings screen.
typealias EPUBFontFamily = ReaderFontFamily

private extension ReaderFontFamily {
    var readiumFontFamily: FontFamily {
        FontFamily(rawValue: readiumFamilyName)
    }

    /// Readium converts 1.0 to CSS 400 and 1.75 to CSS 700.  Use CSS 300 for
    /// the lighter system-font choice while preserving the existing bold
    /// switch below.
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

struct EPUBReaderDraft: Equatable {
    var fontFamily: EPUBFontFamily
    var boldText: Bool
    var lineHeight: Double
    var pageMargins: Double
    var paragraphIndent: Double
    var characterSpacing: Double
    var wordSpacing: Double
    var publisherStyles: Bool
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
    var fontFamily: EPUBFontFamily { didSet { preferencesDidChange() } }
    var boldText: Bool { didSet { preferencesDidChange() } }
    var lineHeight: Double { didSet { preferencesDidChange() } }
    var pageMargins: Double { didSet { preferencesDidChange() } }
    var paragraphIndent: Double { didSet { preferencesDidChange() } }
    var characterSpacing: Double { didSet { preferencesDidChange() } }
    var wordSpacing: Double { didSet { preferencesDidChange() } }
    var theme: EPUBReaderTheme { didSet { preferencesDidChange() } }
    var appearanceMode: EPUBAppearanceMode { didSet { preferencesDidChange() } }
    /// Retained only for migration compatibility. Device brightness is
    /// managed by ReaderView and is never applied to the EPUB palette.
    var brightness: Double
    var flowMode: EPUBFlowMode { didSet { preferencesDidChange() } }
    var pageTransition: EPUBPageTransitionMode { didSet { persistPreferencesIfNeeded() } }
    var publisherStyles: Bool { didSet { preferencesDidChange() } }
    var showBookTitleInPageHeader: Bool { didSet { persistPreferencesIfNeeded() } }

    /// Nil means the current settings are a custom combination rather than a preset.
    var selectedPreset: EPUBReaderPreset? { didSet { persistPreferencesIfNeeded() } }

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
    /// 当前 Readium 打开的文件。TXT 会指向派生 EPUB，预览不能再读取原始 TXT。
    private var activePublicationURL: URL?
    private var preferenceUpdateTask: Task<Void, Never>?
    private var readerOverrideRefreshTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewResourceHref: String?
    private var hasLoaded = false
    private var suppressPreferenceUpdates = false

    private var systemIsDark = false

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
        static let brightness = "reader.epub.brightness"
        static let flowMode = "reader.epub.flowMode"
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
            // Older TXT versions stored a different location payload in this
            // field.  Keep it out of the Readium position channel.
            currentLocatorJSON = nil
        }
        progress = min(max(book.progressPercent, 0), 1)

        let defaults = UserDefaults.standard
        let savedFontScale = defaults.object(forKey: PreferenceKey.fontScale) as? Double ?? 1.0
        fontScale = min(
            max(savedFontScale, ReaderFontSize.minimumScale),
            ReaderFontSize.maximumScale
        )
        fontFamily = defaults.string(forKey: PreferenceKey.fontFamily).flatMap(EPUBFontFamily.init) ?? .original
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
        theme = defaults.string(forKey: PreferenceKey.theme).flatMap(EPUBReaderTheme.init) ?? .light
        appearanceMode = defaults.string(forKey: PreferenceKey.appearanceMode)
            .flatMap(EPUBAppearanceMode.init) ?? .system
        brightness = 1
        let storedFlowMode = defaults.string(forKey: PreferenceKey.flowMode)
            .flatMap(EPUBFlowMode.init) ?? .paged
        let storedPageTransition = defaults.string(forKey: PreferenceKey.pageTransition)
            .flatMap(EPUBPageTransitionMode.init)
            ?? (storedFlowMode == .scroll ? .scroll : .slide)
        if storedPageTransition == .scroll || storedFlowMode == .scroll {
            flowMode = .scroll
            pageTransition = .scroll
        } else {
            flowMode = .paged
            pageTransition = storedPageTransition
        }
        publisherStyles = defaults.object(forKey: PreferenceKey.publisherStyles) as? Bool ?? false
        showBookTitleInPageHeader = defaults.object(forKey: PreferenceKey.showBookTitleInPageHeader) as? Bool ?? false
        selectedPreset = defaults.string(forKey: PreferenceKey.selectedPreset).flatMap(EPUBReaderPreset.init)
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
                // 兼容切换架构前已经读过的 TXT：旧版本只有总进度，没有 Readium Locator。
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

    /// Waits until the current Readium document reflects the target theme and
    /// app-owned reflowable overrides. Readium's public submitPreferences API
    /// does not expose a completion callback in this version, so the document
    /// state itself is used as the completion signal.
    func waitForVisualUpdate() async {
        guard let navigator, isReflowable else { return }

        if let overrideTask = readerOverrideRefreshTask {
            await overrideTask.value
        }

        let retryDelays: [UInt64] = [
            0,
            24_000_000,
            48_000_000,
            96_000_000,
            192_000_000,
            320_000_000,
        ]
        let script = makeVisualReadinessScript()

        for delay in retryDelays {
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else { return }

            let result = await navigator.evaluateJavaScript(script)
            guard case let .success(value) = result,
                  let readiness = value as? String,
                  readiness == "ready"
            else {
                continue
            }

            return
        }
    }

    /// Re-applies the complete Readium preference set after WebKit returns
    /// from the background. This path is intentionally unconditional: the
    /// navigator may need its CSS state restored even when no preference value
    /// changed while the app was inactive.
    func restoreFromForeground(isDark: Bool) async {
        guard !Task.isCancelled, hasLoaded, let navigator else { return }

        systemIsDark = isDark
        preferenceUpdateTask?.cancel()
        navigator.submitPreferences(makePreferences())
        applyVisibleReaderBaseAppearance()
        refreshVisibleReaderOverrides()

        if let refreshTask = readerOverrideRefreshTask {
            await refreshTask.value
        }
        guard !Task.isCancelled else { return }
        await waitForVisualUpdate()
    }

    /// Commits the latest in-memory EPUB location before the reader is
    /// dismissed.  The view owns the SwiftData save because this model also
    /// handles Readium state and should not own a ModelContext.
    func flushReadingProgress() {
        guard hasLoaded else { return }
        synchronizeStoredChapterMetadata()
        book.progressPercent = min(max(progress, 0), 1)
        book.lastReadAt = .now
    }

    func saveProgress() {
        flushReadingProgress()
    }

    func goForward() {
        guard let navigator else { return }
        Task { await navigator.goForward(options: .animated) }
    }

    func goBackward() {
        guard let navigator else { return }
        Task { await navigator.goBackward(options: .animated) }
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

    func isCurrent(_ entry: EPUBTOCEntry) -> Bool {
        currentTOCEntryID == entry.id
    }

    func updateSystemAppearance(isDark: Bool) {
        guard systemIsDark != isDark else { return }
        systemIsDark = isDark
        guard appearanceMode == .system else { return }
        submitPreferencesImmediately()
    }

    func selectPageTransition(_ transition: EPUBPageTransitionMode) {
        withPreferenceUpdatesSuspended {
            pageTransition = transition
            flowMode = transition == .scroll ? .scroll : .paged
        }
        persistPreferences()
        submitPreferencesImmediately()
    }

    func selectAppearance(_ appearance: EPUBAppearanceMode) {
        withPreferenceUpdatesSuspended {
            appearanceMode = appearance
        }
        persistPreferences()
        submitPreferencesImmediately()
    }

    func setFontScale(_ scale: Double) {
        withPreferenceUpdatesSuspended {
            fontScale = min(max(scale, ReaderFontSize.minimumScale), ReaderFontSize.maximumScale)
            selectedPreset = nil
        }
        persistPreferences()
        submitPreferencesImmediately()
    }

    func apply(preset: EPUBReaderPreset) {
        withPreferenceUpdatesSuspended {
            selectedPreset = preset
            // Theme cards only select the reading palette. Typography and
            // layout remain the user's current choices.
            theme = Self.readerTheme(for: ReaderThemePreset(rawValue: preset.rawValue) ?? .original)
            brightness = 1
        }
        persistPreferences()
        submitPreferencesImmediately()
    }

    func makeDraft() -> EPUBReaderDraft {
        EPUBReaderDraft(
            fontFamily: fontFamily,
            boldText: boldText,
            lineHeight: lineHeight,
            pageMargins: pageMargins,
            paragraphIndent: paragraphIndent,
            characterSpacing: characterSpacing,
            wordSpacing: wordSpacing,
            publisherStyles: publisherStyles
        )
    }

    func apply(_ draft: EPUBReaderDraft) {
        withPreferenceUpdatesSuspended {
            fontFamily = draft.fontFamily
            boldText = draft.boldText
            lineHeight = ReaderLayoutMetrics.clampLineHeight(draft.lineHeight)
            pageMargins = ReaderLayoutMetrics.clampPageMargins(draft.pageMargins)
            paragraphIndent = ReaderLayoutMetrics.fixedParagraphIndent
            characterSpacing = ReaderLayoutMetrics.clampCharacterSpacing(draft.characterSpacing)
            wordSpacing = ReaderLayoutMetrics.clampWordSpacing(draft.wordSpacing)
            publisherStyles = draft.publisherStyles
            selectedPreset = nil
        }
        persistPreferences()
        submitPreferencesImmediately()
    }

    var readerPreferences: ReaderPreferences {
        ReaderPreferences(
            fontSize: ReaderFontSize.defaultValue * fontScale,
            fontFamily: ReaderFontFamily(rawValue: fontFamily.rawValue) ?? .original,
            boldText: boldText,
            lineHeight: lineHeight,
            paragraphSpacing: 10,
            pageMargins: pageMargins,
            paragraphIndent: ReaderLayoutMetrics.fixedParagraphIndent,
            characterSpacing: characterSpacing,
            wordSpacing: wordSpacing,
            publisherStyles: publisherStyles,
            themePreset: Self.themePreset(for: theme),
            appearanceMode: ReaderAppearanceMode(rawValue: appearanceMode.rawValue) ?? .system,
            brightness: 1,
            pageTransition: Self.pageTransition(for: pageTransition),
            showBookTitleInPageHeader: showBookTitleInPageHeader
        )
    }

    func apply(preferences: ReaderPreferences) {
        withPreferenceUpdatesSuspended {
            fontScale = min(
                max(preferences.fontSize / ReaderFontSize.defaultValue, ReaderFontSize.minimumScale),
                ReaderFontSize.maximumScale
            )
            fontFamily = EPUBFontFamily(rawValue: preferences.fontFamily.rawValue) ?? .original
            boldText = preferences.boldText
            lineHeight = ReaderLayoutMetrics.clampLineHeight(preferences.lineHeight)
            pageMargins = ReaderLayoutMetrics.clampPageMargins(preferences.pageMargins)
            paragraphIndent = ReaderLayoutMetrics.fixedParagraphIndent
            characterSpacing = ReaderLayoutMetrics.clampCharacterSpacing(preferences.characterSpacing)
            wordSpacing = ReaderLayoutMetrics.clampWordSpacing(preferences.wordSpacing)
            publisherStyles = preferences.publisherStyles
            appearanceMode = EPUBAppearanceMode(rawValue: preferences.appearanceMode.rawValue) ?? .system
            brightness = 1
            pageTransition = Self.pageTransition(for: preferences.pageTransition)
            flowMode = pageTransition == .scroll ? .scroll : .paged
            theme = Self.readerTheme(for: preferences.themePreset)
            showBookTitleInPageHeader = preferences.showBookTitleInPageHeader
            selectedPreset = nil
        }
        persistPreferences()
        submitPreferencesImmediately()
        onStateChange?()
    }

    func clearError() {
        errorMessage = nil
    }

    func tearDown() {
        preferenceUpdateTask?.cancel()
        preferenceUpdateTask = nil
        readerOverrideRefreshTask?.cancel()
        readerOverrideRefreshTask = nil
        previewTask?.cancel()
        previewTask = nil
        navigator?.delegate = nil
        onToggleControls = nil
        onSwipeStart = nil
    }

    func resetTypography() {
        withPreferenceUpdatesSuspended {
            fontScale = 1.0
            fontFamily = .original
            boldText = false
            lineHeight = ReaderLayoutMetrics.defaultLineHeight
            pageMargins = ReaderLayoutMetrics.defaultPageMargins
            paragraphIndent = ReaderLayoutMetrics.fixedParagraphIndent
            characterSpacing = ReaderLayoutMetrics.defaultCharacterSpacing
            wordSpacing = ReaderLayoutMetrics.defaultWordSpacing
            publisherStyles = false
            selectedPreset = nil
        }
        persistPreferences()
        submitPreferencesImmediately()
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

    private var resolvedTheme: EPUBReaderTheme {
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
        preferenceUpdateTask?.cancel()
        preferenceUpdateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, let self, let navigator = self.navigator else { return }
            navigator.submitPreferences(self.makePreferences())
            self.applyVisibleReaderBaseAppearance()
            self.refreshVisibleReaderOverrides()
        }
    }

    private func persistPreferencesIfNeeded() {
        guard !suppressPreferenceUpdates else { return }
        persistPreferences()
    }

    private func submitPreferencesImmediately() {
        preferenceUpdateTask?.cancel()
        guard let navigator else { return }
        navigator.submitPreferences(makePreferences())
        applyVisibleReaderBaseAppearance()
        refreshVisibleReaderOverrides()
    }

    private func makePreferences() -> EPUBPreferences {
        let effectiveTheme = resolvedTheme
        let navigatorBackgroundColor: ReadiumNavigator.Color? = isReflowable
            ? nil
            : ReadiumNavigator.Color(
                uiColor: effectiveTheme.readerBackgroundUIColor(isDarkAppearance: isDarkAppearance)
            )
        let preferences = EPUBPreferences(
            // ReaderChrome owns the reflowable surface. Leaving this unset
            // avoids Readium's background preference rule, which clears
            // publisher backgrounds on descendant elements.
            backgroundColor: navigatorBackgroundColor,
            fontFamily: fontFamily.readiumFontFamily,
            fontSize: fontScale,
            fontWeight: boldText ? 1.75 : fontFamily.readiumFontWeight,
            letterSpacing: nil,
            lineHeight: nil,
            pageMargins: ReaderLayoutMetrics.pageMarginFactor(for: pageMargins),
            paragraphIndent: ReaderLayoutMetrics.fixedParagraphIndent,
            publisherStyles: publisherStyles,
            scroll: flowMode == .scroll,
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

    /// Re-applies all app-owned reflowable rules to the currently presented
    /// and already preloaded resources. The font rule remains a publisher-CSS
    /// fallback; the bundled @font-face declarations remain the resource
    /// authority.
    private func refreshVisibleReaderOverrides() {
        readerOverrideRefreshTask?.cancel()
        guard let navigator, isReflowable else { return }

        applyVisibleReaderBaseAppearance()
        let script = makeReaderOverrideScript()
        readerOverrideRefreshTask = Task { @MainActor [weak navigator] in
            guard let navigator else { return }
            await navigator.applyNagiReaderOverrides(script)
        }
    }

    private func makeReaderOverrideScript() -> String {
        let publisherFontFamily = Self.javascriptStringLiteral(fontFamily.readiumFamilyName)
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
        return """
        (() => {
            const styleID = "nagi-reader-reader-overrides";
            const publisherFontFamily = \(publisherFontFamily);
            const lineHeight = \(lineHeightValue);
            const letterSpacing = \(letterSpacingValue);
            const wordSpacing = \(wordSpacingValue);
            const typographyEnabled = \(typographyEnabled);
            const root = document.documentElement;

            if (!root) {
                return;
            }

            const previous = document.getElementById(styleID);
            if (previous) previous.remove();

            const style = document.createElement("style");
            style.id = styleID;
            root.setAttribute("data-nagi-reader-overrides", "true");

            const rootSelector = ":root[data-nagi-reader-overrides]";
            const bodySelector = rootSelector + " body";
            const fontSelectors = [
                rootSelector,
                bodySelector,
                bodySelector + " *"
            ];
            const typographySelectors = [
                bodySelector,
                bodySelector + " p",
                bodySelector + " li",
                bodySelector + " div",
                bodySelector + " dt",
                bodySelector + " dd",
                bodySelector + " blockquote",
                bodySelector + " section",
                bodySelector + " article",
                bodySelector + " span",
                bodySelector + " td",
                bodySelector + " th",
                bodySelector + " h1",
                bodySelector + " h2",
                bodySelector + " h3",
                bodySelector + " h4",
                bodySelector + " h5",
                bodySelector + " h6"
            ];

            const rules = [
                [rootSelector, bodySelector].join(", ")
                    + " { background: transparent !important; }",
                fontSelectors.join(", ")
                    + " { font-family: "
                    + JSON.stringify(publisherFontFamily)
                    + " !important; }"
            ];

            if (typographyEnabled) {
                rules.push(
                    typographySelectors.join(", ")
                        + " { line-height: "
                        + JSON.stringify(lineHeight)
                        + " !important; letter-spacing: "
                        + JSON.stringify(letterSpacing)
                        + " !important; word-spacing: "
                        + JSON.stringify(wordSpacing)
                        + " !important; }"
                );
            }

            style.textContent = rules.join("\\n");
            (document.head || root).appendChild(style);
        })();
        """
    }

    private func makeVisualReadinessScript() -> String {
        let expectedTextColor = Self.javascriptStringLiteral(
            Self.cssColorLiteral(readerContentUIColor)
        )
        let expectedThemeMarker = Self.javascriptStringLiteral(
            readiumThemeAppearanceMarker ?? ""
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

        return """
        (() => {
            if (
                document.readyState !== "complete"
                || !document.documentElement
                || !document.body
            ) {
                return "";
            }

            const root = document.documentElement;
            const body = document.body;
            const rootStyle = getComputedStyle(root);
            const bodyStyle = getComputedStyle(body);
            const sample = body.querySelector(
                "p, li, div, dt, dd, blockquote, section, article, span, td, th"
            ) || body;
            const sampleStyle = getComputedStyle(sample);
            const styleText = root.getAttribute("style") || "";
            const expectedThemeMarker = \(expectedThemeMarker);
            const expectedTextColor = \(expectedTextColor);
            const expectedFontFamily = \(expectedFontFamily);
            const expectedLineHeight = \(expectedLineHeight);
            const expectedLetterSpacing = \(expectedLetterSpacing);
            const expectedWordSpacing = \(expectedWordSpacing);
            const typographyEnabled = \(typographyEnabled);

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
            const textReady = [
                rootStyle.color,
                bodyStyle.color,
                sampleStyle.color
            ].every(value => normalizeColor(value) === expectedColor);

            const themeReady = expectedThemeMarker.length > 0
                ? styleText.includes(expectedThemeMarker)
                : !styleText.includes("readium-night-on")
                    && !styleText.includes("readium-sepia-on");

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
            const typographyReady = !typographyEnabled
                || (lineHeightReady && letterSpacingReady && wordSpacingReady);

            return root.getAttribute("data-nagi-reader-overrides") === "true"
                && themeReady
                && isTransparent(rootStyle.backgroundColor)
                && isTransparent(bodyStyle.backgroundColor)
                && rootStyle.backgroundImage === "none"
                && bodyStyle.backgroundImage === "none"
                && fontReady
                && textReady
                && typographyReady
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
        let contentProvider = EPUBReadingContentProvider()
        previewTask = Task { [weak self] in
            let text = await Task.detached(priority: .userInitiated) {
                try? contentProvider.loadChapterContent(url: sourceURL, href: normalizedHref)
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
        defaults.set(1.0, forKey: PreferenceKey.brightness)
        defaults.set(flowMode.rawValue, forKey: PreferenceKey.flowMode)
        defaults.set(pageTransition.rawValue, forKey: PreferenceKey.pageTransition)
        defaults.set(publisherStyles, forKey: PreferenceKey.publisherStyles)
        defaults.set(showBookTitleInPageHeader, forKey: PreferenceKey.showBookTitleInPageHeader)
        defaults.set(selectedPreset?.rawValue, forKey: PreferenceKey.selectedPreset)
    }

    private static func themePreset(for theme: EPUBReaderTheme) -> ReaderThemePreset {
        switch theme {
        case .quiet: return .quiet
        case .sepia: return .paper
        case .light, .dark: return .original
        }
    }

    private static func readerTheme(for preset: ReaderThemePreset) -> EPUBReaderTheme {
        switch preset {
        case .original: return .light
        case .quiet: return .quiet
        case .paper: return .sepia
        }
    }

    private static func pageTransition(for mode: EPUBPageTransitionMode) -> ReaderPageTransition {
        switch mode {
        case .slide: return .slide
        case .pageCurl: return .pageCurl
        case .fade: return .fade
        case .scroll: return .scroll
        }
    }

    private static func pageTransition(for mode: ReaderPageTransition) -> EPUBPageTransitionMode {
        switch mode {
        case .slide: return .slide
        case .pageCurl: return .pageCurl
        case .fade: return .fade
        case .scroll: return .scroll
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
    /// Let Readium reserve only system-protected areas and the visible page
    /// header's own occupied height. Reading clearance is derived from the
    /// current window and chrome instead of an app-wide fixed margin.
    func navigatorContentInset(_ navigator: VisualNavigator) -> UIEdgeInsets? {
        var safeAreaInsets = navigator.view.window?.safeAreaInsets ?? navigator.view.safeAreaInsets
        if showBookTitleInPageHeader {
            safeAreaInsets.top += CGFloat(ReaderLayoutMetrics.pageHeaderHeight)
        }
        return ReaderContentInsetResolver.resolve(
            safeAreaInsets: safeAreaInsets,
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
        userContentController.addUserScript(
            WKUserScript(
                source: makeReaderOverrideScript(),
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
