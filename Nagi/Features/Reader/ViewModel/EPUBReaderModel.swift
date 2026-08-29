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
        case .light, .sepia:
            return UIColor(red: 18 / 255, green: 18 / 255, blue: 18 / 255, alpha: 1)
        case .quiet:
            return UIColor(red: 38 / 255, green: 42 / 255, blue: 48 / 255, alpha: 1)
        case .dark:
            return UIColor(red: 254 / 255, green: 254 / 255, blue: 254 / 255, alpha: 1)
        }
    }

    var backgroundUIColor: UIColor {
        switch self {
        case .light:
            return UIColor.white
        case .quiet:
            return UIColor(red: 242 / 255, green: 243 / 255, blue: 245 / 255, alpha: 1)
        case .sepia:
            return UIColor(red: 250 / 255, green: 244 / 255, blue: 232 / 255, alpha: 1)
        case .dark:
            return UIColor.black
        }
    }

    func adjustedBackgroundUIColor(brightness: Double) -> UIColor {
        let level = CGFloat(min(max(brightness, 0.25), 1))
        switch self {
        case .dark:
            return UIColor(white: 0.12 * level, alpha: 1)
        case .light, .quiet, .sepia:
            return applyingBrightness(
                to: backgroundUIColor,
                multiplier: 0.72 + 0.28 * level
            )
        }
    }

    func adjustedContentUIColor(brightness: Double) -> UIColor {
        let level = CGFloat(min(max(brightness, 0.25), 1))
        switch self {
        case .dark:
            return UIColor(white: 0.66 + 0.34 * level, alpha: 1)
        case .light, .quiet, .sepia:
            return applyingBrightness(
                to: contentUIColor,
                multiplier: 0.72 + 0.28 * level
            )
        }
    }

    var readiumTheme: ReadiumNavigator.Theme {
        switch self {
        case .light: return .light
        case .quiet: return .light
        case .sepia: return .sepia
        case .dark: return .dark
        }
    }

    private func applyingBrightness(to color: UIColor, multiplier: CGFloat) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return color
        }
        return UIColor(
            red: min(max(red * multiplier, 0), 1),
            green: min(max(green * multiplier, 0), 1),
            blue: min(max(blue * multiplier, 0), 1),
            alpha: alpha
        )
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
        case .light: return "sun.max"
        case .dark: return "moon.fill"
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
        case .fade: return "快速淡入淡出"
        case .scroll: return "滚动"
        }
    }

    var systemImage: String {
        switch self {
        case .slide: return "arrow.left.arrow.right"
        case .pageCurl: return "book.pages"
        case .fade: return "rectangle.on.rectangle"
        case .scroll: return "arrow.up.and.down"
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

enum EPUBFontFamily: String, CaseIterable, Identifiable, Equatable {
    case systemSerif
    case systemSansSerif
    case palatino
    case athelas
    case openDyslexic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .systemSerif: return "系统衬线"
        case .systemSansSerif: return "系统无衬线"
        case .palatino: return "Palatino"
        case .athelas: return "Athelas"
        case .openDyslexic: return "OpenDyslexic"
        }
    }

    var readiumFontFamily: FontFamily {
        switch self {
        case .systemSerif: return .serif
        case .systemSansSerif: return .sansSerif
        case .palatino: return .palatino
        case .athelas: return .athelas
        case .openDyslexic: return .openDyslexic
        }
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
    var contentTopInset: Double
    var contentBottomInset: Double
    var pageMargins: Double
    var paragraphIndent: Double
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
    var contentTopInset: Double { didSet { preferencesDidChange() } }
    var contentBottomInset: Double { didSet { preferencesDidChange() } }
    var theme: EPUBReaderTheme { didSet { preferencesDidChange() } }
    var appearanceMode: EPUBAppearanceMode { didSet { preferencesDidChange() } }
    var brightness: Double { didSet { preferencesDidChange() } }
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
        resolvedTheme.adjustedContentUIColor(brightness: brightness)
    }

    var readerBackgroundUIColor: UIColor {
        resolvedTheme.adjustedBackgroundUIColor(brightness: brightness)
    }

    var onToggleControls: (() -> Void)?
    var onSwipeStart: (() -> Void)?
    var onStateChange: (() -> Void)?

    private var publication: Publication?
    private var preferenceUpdateTask: Task<Void, Never>?
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
        static let paragraphIndent = "reader.epub.paragraphIndent"
        static let contentTopInset = "reader.epub.contentTopInset"
        static let contentBottomInset = "reader.epub.contentBottomInset"
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
        currentLocatorJSON = book.readerLocatorJSON
        progress = min(max(book.progressPercent, 0), 1)

        let defaults = UserDefaults.standard
        fontScale = defaults.object(forKey: PreferenceKey.fontScale) as? Double ?? 1.0
        fontFamily = defaults.string(forKey: PreferenceKey.fontFamily).flatMap(EPUBFontFamily.init) ?? .systemSerif
        boldText = defaults.object(forKey: PreferenceKey.boldText) as? Bool ?? false
        lineHeight = defaults.object(forKey: PreferenceKey.lineHeight) as? Double ?? 1.5
        pageMargins = defaults.object(forKey: PreferenceKey.pageMargins) as? Double ?? 1.0
        paragraphIndent = defaults.object(forKey: PreferenceKey.paragraphIndent) as? Double ?? 2.0
        contentTopInset = defaults.object(forKey: PreferenceKey.contentTopInset) as? Double ?? 56
        contentBottomInset = defaults.object(forKey: PreferenceKey.contentBottomInset) as? Double ?? 32
        theme = defaults.string(forKey: PreferenceKey.theme).flatMap(EPUBReaderTheme.init) ?? .light
        appearanceMode = defaults.string(forKey: PreferenceKey.appearanceMode)
            .flatMap(EPUBAppearanceMode.init) ?? .system
        brightness = defaults.object(forKey: PreferenceKey.brightness) as? Double ?? 0.82
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
            let publication = try await ReadiumService.shared.openEPUB(
                at: URL(fileURLWithPath: book.sourceURL)
            )
            self.publication = publication
            title = publication.metadata.title ?? book.title

            let initialLocation = book.readerLocatorJSON.flatMap {
                try? Locator(jsonString: $0)
            }
            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initialLocation,
                config: .init(
                    preferences: makePreferences(),
                    disablePageTurnsWhileScrolling: true,
                    contentInset: [
                        // 给正文顶部留出稳定的呼吸空间，避免贴近屏幕边缘；
                        // 该 inset 也包含 Readium 要求的安全区预留。
                        .compact: (top: 56, bottom: 32),
                        .regular: (top: 64, bottom: 48),
                    ],
                    preloadPreviousPositionCount: 2,
                    preloadNextPositionCount: 6
                )
            )
            navigator.delegate = self
            navigator.addObserver(.drag(onStart: { [weak self] _ in
                self?.onSwipeStart?()
                return false
            }))
            self.navigator = navigator
            hasLoaded = true

            if currentReadingHref == nil {
                currentReadingHref = initialLocation?.href.path
            }
            loadPreviewIfNeeded()

            if let initialLocation {
                updateLocation(initialLocation)
            }

            await loadTableOfContents(from: publication)
        } catch {
            errorMessage = "无法打开 EPUB：\(error.localizedDescription)"
        }
    }

    /// Commits the latest in-memory EPUB location before the reader is
    /// dismissed.  The view owns the SwiftData save because this model also
    /// handles Readium state and should not own a ModelContext.
    func flushReadingProgress() {
        guard hasLoaded else { return }
        book.progressPercent = min(max(progress, 0), 1)
        book.lastReadAt = .now
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
            fontScale = min(max(scale, 0.8), 2.0)
            selectedPreset = nil
        }
        persistPreferences()
        submitPreferencesImmediately()
    }

    func apply(preset: EPUBReaderPreset) {
        withPreferenceUpdatesSuspended {
            selectedPreset = preset
            switch preset {
            case .original:
                theme = .light
                brightness = 0.82
                fontScale = 1.0
                fontFamily = .systemSerif
                boldText = false
                lineHeight = 1.5
                pageMargins = 1.0
                paragraphIndent = 2.0
                publisherStyles = false
            case .quiet:
                theme = .quiet
                brightness = 0.72
                fontScale = 1.0
                fontFamily = .systemSerif
                boldText = false
                lineHeight = 1.65
                pageMargins = 1.1
                paragraphIndent = 2.0
                publisherStyles = false
            case .paper:
                theme = .sepia
                brightness = 0.84
                fontScale = 1.0
                fontFamily = .systemSerif
                boldText = false
                lineHeight = 1.55
                pageMargins = 1.0
                paragraphIndent = 2.0
                publisherStyles = false
            }
        }
        persistPreferences()
        submitPreferencesImmediately()
    }

    func makeDraft() -> EPUBReaderDraft {
        EPUBReaderDraft(
            fontFamily: fontFamily,
            boldText: boldText,
            lineHeight: lineHeight,
            contentTopInset: contentTopInset,
            contentBottomInset: contentBottomInset,
            pageMargins: pageMargins,
            paragraphIndent: paragraphIndent,
            publisherStyles: publisherStyles
        )
    }

    func apply(_ draft: EPUBReaderDraft) {
        withPreferenceUpdatesSuspended {
            fontFamily = draft.fontFamily
            boldText = draft.boldText
            lineHeight = draft.lineHeight
            contentTopInset = draft.contentTopInset
            contentBottomInset = draft.contentBottomInset
            pageMargins = draft.pageMargins
            paragraphIndent = draft.paragraphIndent
            publisherStyles = draft.publisherStyles
            selectedPreset = nil
        }
        persistPreferences()
        submitPreferencesImmediately()
    }

    var readerPreferences: ReaderPreferences {
        ReaderPreferences(
            fontSize: 17 * fontScale,
            fontFamily: ReaderFontFamily(fontFamily.rawValue) ?? .systemSerif,
            boldText: boldText,
            lineHeight: lineHeight,
            paragraphSpacing: 10,
            pageMargins: pageMargins,
            contentTopInset: contentTopInset,
            contentBottomInset: contentBottomInset,
            paragraphIndent: paragraphIndent,
            publisherStyles: publisherStyles,
            themePreset: Self.themePreset(for: theme),
            appearanceMode: ReaderAppearanceMode(rawValue: appearanceMode.rawValue) ?? .system,
            brightness: brightness,
            pageTransition: Self.pageTransition(for: pageTransition),
            showBookTitleInPageHeader: showBookTitleInPageHeader
        )
    }

    func apply(preferences: ReaderPreferences) {
        withPreferenceUpdatesSuspended {
            fontScale = min(max(preferences.fontSize / 17, 0.8), 2.0)
            fontFamily = EPUBFontFamily(rawValue: preferences.fontFamily.rawValue) ?? .systemSerif
            boldText = preferences.boldText
            lineHeight = min(max(preferences.lineHeight, 1.0), 2.0)
            pageMargins = min(max(preferences.pageMargins, 0.5), 2.0)
            paragraphIndent = min(max(preferences.paragraphIndent, 0), 3.0)
            contentTopInset = min(max(preferences.contentTopInset, 0), 160)
            contentBottomInset = min(max(preferences.contentBottomInset, 0), 160)
            publisherStyles = preferences.publisherStyles
            appearanceMode = EPUBAppearanceMode(rawValue: preferences.appearanceMode.rawValue) ?? .system
            brightness = min(max(preferences.brightness, 0.25), 1.0)
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
        previewTask?.cancel()
        previewTask = nil
        navigator?.delegate = nil
        onToggleControls = nil
        onSwipeStart = nil
    }

    func resetTypography() {
        withPreferenceUpdatesSuspended {
            fontScale = 1.0
            fontFamily = .systemSerif
            boldText = false
            lineHeight = 1.5
            pageMargins = 1.0
            paragraphIndent = 2.0
            contentTopInset = 56
            contentBottomInset = 32
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
    }

    private var resolvedTheme: EPUBReaderTheme {
        switch appearanceMode {
        case .light:
            return theme == .dark ? .light : theme
        case .dark:
            return .dark
        case .system:
            return systemIsDark ? .dark : (theme == .dark ? .light : theme)
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
    }

    private func makePreferences() -> EPUBPreferences {
        let effectiveTheme = resolvedTheme
        return EPUBPreferences(
            backgroundColor: ReadiumNavigator.Color(
                uiColor: effectiveTheme.adjustedBackgroundUIColor(brightness: brightness)
            ),
            fontFamily: fontFamily.readiumFontFamily,
            fontSize: fontScale,
            fontWeight: boldText ? 1.75 : 1.0,
            lineHeight: lineHeight,
            pageMargins: pageMargins,
            paragraphIndent: paragraphIndent,
            publisherStyles: publisherStyles,
            scroll: flowMode == .scroll,
            spread: .auto,
            textColor: ReadiumNavigator.Color(
                uiColor: effectiveTheme.adjustedContentUIColor(brightness: brightness)
            ),
            textNormalization: !publisherStyles,
            theme: effectiveTheme.readiumTheme
        )
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

        let sourceURL = URL(fileURLWithPath: book.sourceURL)
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
        defaults.set(pageMargins, forKey: PreferenceKey.pageMargins)
        defaults.set(paragraphIndent, forKey: PreferenceKey.paragraphIndent)
        defaults.set(contentTopInset, forKey: PreferenceKey.contentTopInset)
        defaults.set(contentBottomInset, forKey: PreferenceKey.contentBottomInset)
        defaults.set(theme.rawValue, forKey: PreferenceKey.theme)
        defaults.set(appearanceMode.rawValue, forKey: PreferenceKey.appearanceMode)
        defaults.set(brightness, forKey: PreferenceKey.brightness)
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
        chapterTitle = locator.title ?? chapterTitle
        currentReadingHref = locator.href.path
        if let totalProgression = locator.locations.totalProgression {
            progress = min(max(totalProgression, 0), 1)
        }
        loadPreviewIfNeeded()
        currentLocatorJSON = locator.jsonString
        book.readerLocatorJSON = locator.jsonString
        book.progressPercent = progress
        book.lastReadAt = .now
        onStateChange?()
    }
}

extension EPUBReaderModel {
    /// 让正文边距滑杆在不遮挡刘海、动态岛或 Home Indicator 的前提下生效。
    /// Readium 会在分页重建及窗口尺寸变化时重新调用该代理方法。
    func navigatorContentInset(_ navigator: VisualNavigator) -> UIEdgeInsets? {
        let safeAreaInsets = navigator.view.window?.safeAreaInsets ?? navigator.view.safeAreaInsets
        return UIEdgeInsets(
            top: max(safeAreaInsets.top, CGFloat(contentTopInset)),
            left: 0,
            bottom: max(safeAreaInsets.bottom, CGFloat(contentBottomInset)),
            right: 0
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
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        updateLocation(locator)
    }

    func navigator(_ navigator: Navigator, didJumpTo locator: Locator) {
        updateLocation(locator)
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
