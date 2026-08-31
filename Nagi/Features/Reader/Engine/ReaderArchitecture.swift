//
//  ReaderArchitecture.swift
//  Nagi
//
//  阅读层的共同契约：导入结果与阅读会话分离，阅读编排层不依赖具体文件格式。
//

import Foundation
import Observation
import SwiftUI
import UIKit

/// Keeps newer SF Symbols requests usable on devices whose installed symbol
/// catalog is older than the app's design reference.
enum ReaderSystemSymbol {
    static func name(_ preferred: String, fallback: String) -> String {
        UIImage(systemName: preferred) == nil ? fallback : preferred
    }
}

// MARK: - Reading document

struct ReaderChapter: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let index: Int
    let depth: Int
}

struct ReaderDocument: Identifiable, Sendable {
    let id: UUID
    let title: String
    let author: String?
    let chapters: [ReaderChapter]
}

struct ReaderBookDescriptor: Sendable, Equatable {
    let id: UUID
    let title: String
    let author: String?
    let format: BookFormat
    let sourceURL: URL
    let progressPercent: Double
    let readerLocatorJSON: String?
    let txtReadingLocationJSON: String?
    let currentChapterIndex: Int

    @MainActor
    init(book: Book) {
        id = book.id
        title = book.title
        author = book.author
        format = book.format
        sourceURL = URL(fileURLWithPath: book.sourceURL)
        progressPercent = book.progressPercent
        readerLocatorJSON = book.readerLocatorJSON
        txtReadingLocationJSON = book.txtReadingLocationJSON
        currentChapterIndex = book.currentChapterIndex
    }
}

// MARK: - Unified preferences

enum ReaderAppearanceMode: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "浅色"
        case .dark: return "深色"
        case .system: return "匹配设备"
        }
    }

    var assetName: String? {
        self == .system ? "readerAppearanceMatchDevice" : nil
    }

    var systemImage: String {
        switch self {
        case .light: return "sunrise.fill"
        case .dark: return "sunset.fill"
        case .system:
            return ReaderSystemSymbol.name(
                "activity.move.ring",
                fallback: "circle.lefthalf.filled"
            )
        }
    }
}

enum ReaderPageTransition: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case slide
    case pageCurl
    case fade
    case scroll

    var id: String { rawValue }

    var label: String {
        switch self {
        case .slide: return "滑动"
        case .pageCurl: return "卷页"
        case .fade: return "淡化"
        case .scroll: return "滚动"
        }
    }

    var assetName: String {
        switch self {
        case .slide: return "readerPageTransitionSlide"
        case .pageCurl: return "readerPageTransitionPageCurl"
        case .fade: return "readerPageTransitionFade"
        case .scroll: return "readerPageTransitionScroll"
        }
    }

    var systemImage: String {
        switch self {
        case .slide:
            return ReaderSystemSymbol.name(
                "arrow.left.page.on.rectangle",
                fallback: "inset.filled.lefthalf.arrow.left.rectangle"
            )
        case .pageCurl: return "book.pages"
        case .fade:
            return ReaderSystemSymbol.name("bolt.rectangle", fallback: "bolt.square")
        case .scroll: return "scroll"
        }
    }
}

enum ReaderThemePreset: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case original
    case quiet
    case paper

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

    var paletteTheme: ReaderTheme {
        switch self {
        case .original: return .light
        case .quiet: return .quiet
        case .paper: return .sepia
        }
    }

    func backgroundColor(isDarkAppearance: Bool) -> Color {
        // In dark appearance, keep the quiet card visually aligned with the
        // original card. This is a settings-card treatment only; the quiet
        // reading palette remains unchanged in ReaderTheme.
        if self == .quiet && isDarkAppearance {
            return Color(uiColor: ReaderThemePalette.originalDarkBackground)
        }
        return Color(uiColor: paletteTheme.readerBackgroundUIColor(isDarkAppearance: isDarkAppearance))
    }

    func contentColor(isDarkAppearance: Bool) -> Color {
        Color(uiColor: paletteTheme.readerContentUIColor(isDarkAppearance: isDarkAppearance))
    }
}

enum ReaderFontSize {
    static let defaultValue = 17.0
    static let step = 2.0
    static let minimum = 9.0
    static let maximum = 41.0
    static let indicatorCount = Int((maximum - minimum) / step) + 1
    static let minimumScale = minimum / defaultValue
    static let maximumScale = maximum / defaultValue
}

/// The typography values that are shared by the TXT and EPUB renderers.
///
/// Keep the physical page clearance here instead of letting each renderer
/// invent its own interpretation. `pageMargins` is the horizontal inset, in
/// points, applied to both sides of the reading content.
enum ReaderLayoutMetrics {
    // The page header's actual occupied height. Vertical reading clearance is
    // resolved from the system safe area and the active reader chrome rather
    // than from a fixed app-wide margin.
    static let pageHeaderHeight = 48.0
    static let fixedParagraphIndent = 2.0

    static let pageMarginBase = 24.0
    static let pageMarginsRange = 16.0 ... 48.0
    static let pageMarginsStep = 2.0
    static let lineHeightRange = 0.80 ... 2.50
    static let characterSpacingRange = -10.0 ... 10.0
    static let wordSpacingRange = -20.0 ... 20.0
    static let defaultLineHeight = 1.50
    static let defaultPageMargins = pageMarginBase
    static let defaultCharacterSpacing = 0.0
    static let defaultWordSpacing = 0.0

    /// Character and word spacing remain percentage controls based on a fixed
    /// reference point size, independent of the reader font size.
    static let spacingReferencePointSize = 24.0

    /// Readium CSS expresses these two values in `rem`.  Its public
    /// `letterSpacing` value is divided by two before it becomes CSS, so the
    /// conversion is kept here to make the EPUB and TextKit paths agree.
    static let readiumRootPointSize = 16.0

    static func clampPageMargins(_ value: Double) -> Double {
        min(max(value, pageMarginsRange.lowerBound), pageMarginsRange.upperBound)
    }

    static func clampLineHeight(_ value: Double) -> Double {
        min(max(value, lineHeightRange.lowerBound), lineHeightRange.upperBound)
    }

    static func clampCharacterSpacing(_ value: Double) -> Double {
        min(max(value, characterSpacingRange.lowerBound), characterSpacingRange.upperBound)
    }

    static func clampWordSpacing(_ value: Double) -> Double {
        min(max(value, wordSpacingRange.lowerBound), wordSpacingRange.upperBound)
    }

    static func pageBlankInset(for pageMargin: Double) -> CGFloat {
        CGFloat(clampPageMargins(pageMargin))
    }

    /// Readium expresses page margins as a factor relative to its default
    /// page margin. Keep the user-facing value in points and convert only at
    /// the renderer boundary.
    static func pageMarginFactor(for pageMargin: Double) -> Double {
        clampPageMargins(pageMargin) / pageMarginBase
    }

    static func spacingPoints(for percentage: Double) -> CGFloat {
        CGFloat(spacingReferencePointSize * percentage / 100)
    }

    static func readiumLetterSpacing(for percentage: Double) -> Double {
        Double(spacingPoints(for: clampCharacterSpacing(percentage)))
            / readiumRootPointSize * 2
    }

    static func readiumWordSpacing(for percentage: Double) -> Double {
        Double(spacingPoints(for: clampWordSpacing(percentage))) / readiumRootPointSize
    }

    /// Values written by the original settings screen were factors in the
    /// 0.5...2.0 range. Convert them to the new absolute-point value.
    static func migrateLegacyPageMargins(_ value: Double?) -> Double {
        guard let value else { return defaultPageMargins }
        return clampPageMargins(pageMarginBase * value)
    }

    /// Values written by the intermediate settings screen were signed
    /// percentages around the 24 pt base. Convert them to points.
    static func migrateLegacyPageMarginAdjustment(_ value: Double?) -> Double {
        guard let value else { return defaultPageMargins }
        return clampPageMargins(pageMarginBase * (1 + value / 100))
    }
}

struct ReaderPreferences: Codable, Equatable, Sendable {
    var fontSize: Double
    var fontFamily: ReaderFontFamily
    var boldText: Bool
    var lineHeight: Double
    var paragraphSpacing: Double
    /// Absolute horizontal page blank in points, applied to both sides.
    var pageMargins: Double
    /// Kept in the model for compatibility, but fixed by ReaderLayoutMetrics.
    var paragraphIndent: Double
    var characterSpacing: Double
    var wordSpacing: Double
    var publisherStyles: Bool
    var themePreset: ReaderThemePreset
    var appearanceMode: ReaderAppearanceMode
    /// Kept for decoding older saved preferences. Reader brightness is now
    /// controlled by the device, so renderers normalize this value to 1.
    var brightness: Double
    var pageTransition: ReaderPageTransition
    var showBookTitleInPageHeader: Bool

    init(
        fontSize: Double = ReaderFontSize.defaultValue,
        fontFamily: ReaderFontFamily = .original,
        boldText: Bool = false,
        lineHeight: Double = ReaderLayoutMetrics.defaultLineHeight,
        paragraphSpacing: Double = 10,
        pageMargins: Double = ReaderLayoutMetrics.defaultPageMargins,
        paragraphIndent: Double = ReaderLayoutMetrics.fixedParagraphIndent,
        characterSpacing: Double = ReaderLayoutMetrics.defaultCharacterSpacing,
        wordSpacing: Double = ReaderLayoutMetrics.defaultWordSpacing,
        publisherStyles: Bool = false,
        themePreset: ReaderThemePreset = .original,
        appearanceMode: ReaderAppearanceMode = .system,
        brightness: Double = 1,
        pageTransition: ReaderPageTransition = .slide,
        showBookTitleInPageHeader: Bool = false
    ) {
        _ = paragraphIndent
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.boldText = boldText
        self.lineHeight = ReaderLayoutMetrics.clampLineHeight(lineHeight)
        self.paragraphSpacing = paragraphSpacing
        self.pageMargins = ReaderLayoutMetrics.clampPageMargins(pageMargins)
        self.paragraphIndent = ReaderLayoutMetrics.fixedParagraphIndent
        self.characterSpacing = ReaderLayoutMetrics.clampCharacterSpacing(characterSpacing)
        self.wordSpacing = ReaderLayoutMetrics.clampWordSpacing(wordSpacing)
        self.publisherStyles = publisherStyles
        self.themePreset = themePreset
        self.appearanceMode = appearanceMode
        self.brightness = brightness
        self.pageTransition = pageTransition
        self.showBookTitleInPageHeader = showBookTitleInPageHeader
    }

    private enum CodingKeys: String, CodingKey {
        case storageVersion
        case fontSize
        case fontFamily
        case boldText
        case lineHeight
        case paragraphSpacing
        case pageMargins
        case paragraphIndent
        case characterSpacing
        case wordSpacing
        case publisherStyles
        case themePreset
        case appearanceMode
        case brightness
        case pageTransition
        case showBookTitleInPageHeader
    }

    private static let currentStorageVersion = 4

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storageVersion = try container.decodeIfPresent(Int.self, forKey: .storageVersion) ?? 1
        let storedPageMargins = try container.decodeIfPresent(Double.self, forKey: .pageMargins)
        let pageMargins: Double
        switch storageVersion {
        case 3...:
            pageMargins = ReaderLayoutMetrics.clampPageMargins(
                storedPageMargins ?? ReaderLayoutMetrics.defaultPageMargins
            )
        case 2:
            pageMargins = ReaderLayoutMetrics.migrateLegacyPageMarginAdjustment(storedPageMargins)
        default:
            pageMargins = ReaderLayoutMetrics.migrateLegacyPageMargins(storedPageMargins)
        }

        self.init(
            fontSize: try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? ReaderFontSize.defaultValue,
            fontFamily: try container.decodeIfPresent(ReaderFontFamily.self, forKey: .fontFamily) ?? .original,
            boldText: try container.decodeIfPresent(Bool.self, forKey: .boldText) ?? false,
            lineHeight: try container.decodeIfPresent(Double.self, forKey: .lineHeight) ?? ReaderLayoutMetrics.defaultLineHeight,
            paragraphSpacing: try container.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? 10,
            pageMargins: pageMargins,
            characterSpacing: try container.decodeIfPresent(Double.self, forKey: .characterSpacing) ?? ReaderLayoutMetrics.defaultCharacterSpacing,
            wordSpacing: try container.decodeIfPresent(Double.self, forKey: .wordSpacing) ?? ReaderLayoutMetrics.defaultWordSpacing,
            publisherStyles: try container.decodeIfPresent(Bool.self, forKey: .publisherStyles) ?? false,
            themePreset: try container.decodeIfPresent(ReaderThemePreset.self, forKey: .themePreset) ?? .original,
            appearanceMode: try container.decodeIfPresent(ReaderAppearanceMode.self, forKey: .appearanceMode) ?? .system,
            brightness: try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 1,
            pageTransition: try container.decodeIfPresent(ReaderPageTransition.self, forKey: .pageTransition) ?? .slide,
            showBookTitleInPageHeader: try container.decodeIfPresent(Bool.self, forKey: .showBookTitleInPageHeader) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentStorageVersion, forKey: .storageVersion)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(fontFamily, forKey: .fontFamily)
        try container.encode(boldText, forKey: .boldText)
        try container.encode(lineHeight, forKey: .lineHeight)
        try container.encode(paragraphSpacing, forKey: .paragraphSpacing)
        try container.encode(pageMargins, forKey: .pageMargins)
        try container.encode(paragraphIndent, forKey: .paragraphIndent)
        try container.encode(characterSpacing, forKey: .characterSpacing)
        try container.encode(wordSpacing, forKey: .wordSpacing)
        try container.encode(publisherStyles, forKey: .publisherStyles)
        try container.encode(themePreset, forKey: .themePreset)
        try container.encode(appearanceMode, forKey: .appearanceMode)
        try container.encode(brightness, forKey: .brightness)
        try container.encode(pageTransition, forKey: .pageTransition)
        try container.encode(showBookTitleInPageHeader, forKey: .showBookTitleInPageHeader)
    }
}

/// Resolves the distance from the physical screen edge to the readable text.
///
/// The user-facing inset is a total distance, so it must not be added to the
/// system safe area. Whichever is larger is the effective clearance.
enum ReaderContentInsetResolver {
    static func resolve(
        safeAreaInsets: UIEdgeInsets,
        top: CGFloat,
        bottom: CGFloat,
        horizontal: CGFloat = 0
    ) -> UIEdgeInsets {
        let requestedTop = max(0, top)
        let requestedBottom = max(0, bottom)
        let requestedHorizontal = max(0, horizontal)

        return UIEdgeInsets(
            top: max(safeAreaInsets.top, requestedTop),
            left: max(safeAreaInsets.left, requestedHorizontal),
            bottom: max(safeAreaInsets.bottom, requestedBottom),
            right: max(safeAreaInsets.right, requestedHorizontal)
        )
    }
}

enum ReaderPreferencesStore {
    private static let key = "reader.shared.preferences.v1"

    static func load() -> ReaderPreferences? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ReaderPreferences.self, from: data)
    }

    static func save(_ preferences: ReaderPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct ReaderCustomizationDraft: Equatable, Sendable {
    var fontFamily: ReaderFontFamily
    var boldText: Bool
    var lineHeight: Double
    var pageMargins: Double
    var paragraphIndent: Double
    var characterSpacing: Double
    var wordSpacing: Double
    var publisherStyles: Bool
}

enum ReaderChromeLayout: Sendable {
    case legacyOverlay
    case cornerAligned
}

// MARK: - Stable reading position

struct TextReadingPosition: Codable, Hashable, Sendable {
    let chapterID: String
    let utf16Offset: Int
    let prefix: String
    let suffix: String
}

struct EPUBReadingPosition: Codable, Hashable, Sendable {
    let locatorJSON: String
    let href: String?
    let progression: Double?
}

enum ReadingPositionPayload: Codable, Hashable, Sendable {
    case text(TextReadingPosition)
    case epub(EPUBReadingPosition)
}

struct ReadingPosition: Codable, Hashable, Sendable {
    let version: Int
    let bookID: UUID
    let chapterID: String?
    let progression: Double?
    let payload: ReadingPositionPayload

    init(
        bookID: UUID,
        chapterID: String?,
        progression: Double?,
        payload: ReadingPositionPayload
    ) {
        version = 1
        self.bookID = bookID
        self.chapterID = chapterID
        self.progression = progression
        self.payload = payload
    }
}

// MARK: - Renderer contract

@MainActor
protocol ReaderRenderer: AnyObject {
    var document: ReaderDocument? { get }
    var title: String { get }
    var isLoading: Bool { get }
    var errorMessage: String? { get }
    var currentChapterID: String? { get }
    var progress: Double { get }
    var chapters: [ReaderChapter] { get }
    var previewText: String { get }
    var previewChapterTitle: String { get }
    var isLoadingPreview: Bool { get }
    var preferences: ReaderPreferences { get }
    var backgroundColor: UIColor { get }
    var contentColor: UIColor { get }
    var headerColor: UIColor { get }
    var chromeLayout: ReaderChromeLayout { get }
    var handlesContentTap: Bool { get }
    var canGoNext: Bool { get }
    var canGoPrevious: Bool { get }
    var onStateChange: (() -> Void)? { get set }

    func load() async
    func makeContentView(
        onToggleControls: @escaping () -> Void,
        onSwipeStart: @escaping () -> Void
    ) -> AnyView
    func updateViewport(size: CGSize, safeAreaInsets: UIEdgeInsets, displayScale: CGFloat)
    func apply(preferences: ReaderPreferences)
    func updateSystemAppearance(isDark: Bool)
    func selectPreset(_ preset: ReaderThemePreset)
    func tearDown()
    func clearError()
    func goForward()
    func goBackward()
    func selectChapter(at index: Int)
    func saveProgress()
    func readingPosition() -> ReadingPosition?
}

// MARK: - Repository

@MainActor
final class ReaderRepository {
    let book: Book
    let descriptor: ReaderBookDescriptor

    init(book: Book) {
        self.book = book
        descriptor = ReaderBookDescriptor(book: book)
    }

    func makeRenderer() -> any ReaderRenderer {
        ReaderRendererFactory.make(book: book)
    }

    func persist(position: ReadingPosition?, progress: Double) {
        book.progressPercent = min(max(progress, 0), 1)
        book.lastReadAt = .now

        guard let position else { return }
        switch position.payload {
        case .text(let textPosition):
            if let data = try? JSONEncoder().encode(textPosition),
               let json = String(data: data, encoding: .utf8) {
                book.txtReadingLocationJSON = json
            }
        case .epub(let epubPosition):
            book.readerLocatorJSON = epubPosition.locatorJSON
        }
    }
}

// MARK: - Shared reading orchestration

@MainActor
@Observable
final class ReaderEngine {
    let repository: ReaderRepository
    let renderer: any ReaderRenderer

    private(set) var document: ReaderDocument?
    private(set) var preferences: ReaderPreferences
    var onStateChange: (() -> Void)?

    init(book: Book) {
        let repository = ReaderRepository(book: book)
        let renderer = repository.makeRenderer()
        self.repository = repository
        self.renderer = renderer
        var initialPreferences = ReaderPreferencesStore.load() ?? renderer.preferences
        // Migrate the retired reader-only brightness value. The medium sheet
        // now owns a live UIScreen brightness session instead.
        initialPreferences.brightness = 1
        preferences = initialPreferences
        renderer.apply(preferences: preferences)
        renderer.onStateChange = { [weak self] in
            guard let self else { return }
            self.synchronizeFromRenderer()
            self.onStateChange?()
        }
    }

    func loadIfNeeded() async {
        await renderer.load()
        synchronizeFromRenderer()
    }

    func makeContentView(
        onToggleControls: @escaping () -> Void,
        onSwipeStart: @escaping () -> Void
    ) -> AnyView {
        renderer.makeContentView(
            onToggleControls: onToggleControls,
            onSwipeStart: onSwipeStart
        )
    }

    func updateViewport(size: CGSize, safeAreaInsets: UIEdgeInsets, displayScale: CGFloat) {
        renderer.updateViewport(size: size, safeAreaInsets: safeAreaInsets, displayScale: displayScale)
        synchronizeFromRenderer()
    }

    func apply(preferences: ReaderPreferences) {
        var normalizedPreferences = preferences
        normalizedPreferences.brightness = 1
        renderer.apply(preferences: normalizedPreferences)
        synchronizeFromRenderer()
    }

    func updateSystemAppearance(isDark: Bool) {
        renderer.updateSystemAppearance(isDark: isDark)
        synchronizeFromRenderer()
    }

    func selectPreset(_ preset: ReaderThemePreset) {
        renderer.selectPreset(preset)
        synchronizeFromRenderer()
    }

    func tearDown() {
        renderer.tearDown()
    }

    func clearError() {
        renderer.clearError()
        synchronizeFromRenderer()
    }

#if DEBUG || NAGI_FONT_DIAGNOSTICS
    func refreshFontDiagnostics() async {
        if let renderer = renderer as? ReadiumRenderer {
            await renderer.refreshFontDiagnostics()
        }
        synchronizeFromRenderer()
    }
#endif

    func goForward() {
        renderer.goForward()
    }

    func goBackward() {
        renderer.goBackward()
    }

    func selectChapter(at index: Int) {
        renderer.selectChapter(at: index)
    }

    func saveProgress() {
        renderer.saveProgress()
        repository.persist(position: renderer.readingPosition(), progress: renderer.progress)
        synchronizeFromRenderer()
    }

    private func synchronizeFromRenderer() {
        document = renderer.document
        preferences = renderer.preferences
        ReaderPreferencesStore.save(preferences)
    }
}

@MainActor
@Observable
final class ReaderViewModel {
    let book: Book
    let engine: ReaderEngine

    private(set) var document: ReaderDocument?
    private(set) var title: String
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var currentChapterID: String?
    private(set) var progress = 0.0
    private(set) var chapters: [ReaderChapter] = []
    private(set) var previewText = ""
    private(set) var previewChapterTitle = ""
    private(set) var isLoadingPreview = false
    private(set) var preferences: ReaderPreferences
    private(set) var stateRevision = 0

#if DEBUG || NAGI_FONT_DIAGNOSTICS
    private(set) var fontDiagnostics: ReaderFontDiagnostics?
#endif

    init(book: Book) {
        self.book = book
        let engine = ReaderEngine(book: book)
        self.engine = engine
        title = book.title
        preferences = engine.preferences
        synchronize()
        engine.onStateChange = { [weak self] in self?.synchronize() }
    }

    var backgroundColor: UIColor { engine.renderer.backgroundColor }
    var contentColor: UIColor { engine.renderer.contentColor }
    var headerColor: UIColor { engine.renderer.headerColor }
    var chromeLayout: ReaderChromeLayout { engine.renderer.chromeLayout }
    var handlesContentTap: Bool { engine.renderer.handlesContentTap }
    var canGoNext: Bool { engine.renderer.canGoNext }
    var canGoPrevious: Bool { engine.renderer.canGoPrevious }

    func loadIfNeeded() async {
        await engine.loadIfNeeded()
        synchronize()
    }

    func makeContentView(
        onToggleControls: @escaping () -> Void,
        onSwipeStart: @escaping () -> Void
    ) -> AnyView {
        _ = stateRevision
        return engine.makeContentView(
            onToggleControls: onToggleControls,
            onSwipeStart: onSwipeStart
        )
    }

    func updateViewport(size: CGSize, safeAreaInsets: UIEdgeInsets, displayScale: CGFloat) {
        engine.updateViewport(size: size, safeAreaInsets: safeAreaInsets, displayScale: displayScale)
        synchronize()
    }

    func setPreference(_ update: (inout ReaderPreferences) -> Void) {
        var next = preferences
        update(&next)
        engine.apply(preferences: next)
        synchronize()
    }

    func binding<Value>(_ keyPath: WritableKeyPath<ReaderPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { self.preferences[keyPath: keyPath] },
            set: { [weak self] value in
                self?.setPreference { preferences in
                    preferences[keyPath: keyPath] = value
                }
            }
        )
    }

    func setFontSize(_ size: Double) {
        setPreference {
            $0.fontSize = min(max(size, ReaderFontSize.minimum), ReaderFontSize.maximum)
        }
    }

    func setAppearance(_ appearance: ReaderAppearanceMode) {
        setPreference { $0.appearanceMode = appearance }
    }

    func setPageTransition(_ transition: ReaderPageTransition) {
        setPreference { $0.pageTransition = transition }
    }

    func updateSystemAppearance(isDark: Bool) {
        engine.updateSystemAppearance(isDark: isDark)
        synchronize()
    }

    func selectPreset(_ preset: ReaderThemePreset) {
        engine.selectPreset(preset)
        synchronize()
    }

    func tearDown() {
        engine.tearDown()
    }

    func makeCustomizationDraft() -> ReaderCustomizationDraft {
        ReaderCustomizationDraft(
            fontFamily: preferences.fontFamily,
            boldText: preferences.boldText,
            lineHeight: preferences.lineHeight,
            pageMargins: preferences.pageMargins,
            paragraphIndent: ReaderLayoutMetrics.fixedParagraphIndent,
            characterSpacing: preferences.characterSpacing,
            wordSpacing: preferences.wordSpacing,
            publisherStyles: preferences.publisherStyles
        )
    }

    func apply(_ draft: ReaderCustomizationDraft) {
        setPreference { preferences in
            preferences.fontFamily = draft.fontFamily
            preferences.boldText = draft.boldText
            preferences.lineHeight = ReaderLayoutMetrics.clampLineHeight(draft.lineHeight)
            preferences.pageMargins = ReaderLayoutMetrics.clampPageMargins(draft.pageMargins)
            preferences.paragraphIndent = ReaderLayoutMetrics.fixedParagraphIndent
            preferences.characterSpacing = ReaderLayoutMetrics.clampCharacterSpacing(draft.characterSpacing)
            preferences.wordSpacing = ReaderLayoutMetrics.clampWordSpacing(draft.wordSpacing)
            preferences.publisherStyles = draft.publisherStyles
        }
    }

    func goForward() {
        engine.goForward()
        synchronize()
    }

    func goBackward() {
        engine.goBackward()
        synchronize()
    }

    func selectChapter(at index: Int) {
        engine.selectChapter(at: index)
        synchronize()
    }

    func saveProgress() {
        engine.saveProgress()
        synchronize()
    }

    func clearError() {
        engine.clearError()
        synchronize()
    }

#if DEBUG || NAGI_FONT_DIAGNOSTICS
    func refreshFontDiagnostics() async {
        await engine.refreshFontDiagnostics()
        synchronize()
    }
#endif

    private func synchronize() {
        let renderer = engine.renderer
        document = engine.document ?? renderer.document
        title = renderer.title
        isLoading = renderer.isLoading
        errorMessage = renderer.errorMessage
        currentChapterID = renderer.currentChapterID
        progress = renderer.progress
        chapters = renderer.chapters
        previewText = renderer.previewText
        previewChapterTitle = renderer.previewChapterTitle
        isLoadingPreview = renderer.isLoadingPreview
        preferences = renderer.preferences

#if DEBUG || NAGI_FONT_DIAGNOSTICS
        fontDiagnostics = (renderer as? ReadiumRenderer)?.fontDiagnostics
#endif

        stateRevision &+= 1
    }
}
