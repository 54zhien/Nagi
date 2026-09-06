import Foundation
import Observation
import SwiftUI
import UIKit

struct ReaderChapter: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let index: Int
    let depth: Int
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

    var systemImage: String {
        switch self {
        case .light: return "microbe"
        case .dark: return "moon"
        case .system: return "leaf"
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

    var systemImage: String {
        switch self {
        case .slide:
            return "wind.snow"
        case .pageCurl:
            return "tornado"
        case .fade:
            return "bird"
        case .scroll:
            return "cloud.bolt.rain"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "slide": self = .slide
        case "pageCurl", "cover": self = .pageCurl
        case "fade": self = .fade
        case "scroll": self = .scroll
        default: return nil
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
        return Color(uiColor: paletteTheme.readerBackgroundUIColor(isDarkAppearance: isDarkAppearance))
    }

    func contentColor(isDarkAppearance: Bool) -> Color {
        Color(uiColor: paletteTheme.readerContentUIColor(isDarkAppearance: isDarkAppearance))
    }
}

enum ReaderFontSize {
    static let basePointSize = 14.0
    private static let legacyBasePointSize = 17.0
    static let fontScales: [Double] = [
        1.00, 1.15, 1.33, 1.54, 1.78,
        2.05, 2.37, 2.74, 3.16, 3.65,
        4.22, 4.87, 5.62, 6.49, 7.50
    ]
    static let minimumLevel = 0
    static let maximumLevel = fontScales.count - 1
    static let defaultLevel = 2
    static let indicatorCount = fontScales.count

    static func clampedLevel(_ level: Int) -> Int {
        min(max(level, minimumLevel), maximumLevel)
    }

    static func scale(for level: Int) -> Double {
        fontScales[clampedLevel(level)]
    }

    static func pointSize(for level: Int) -> Double {
        basePointSize * scale(for: level)
    }

    static func nearestLevel(forScale scale: Double) -> Int {
        guard scale.isFinite else { return defaultLevel }
        fontScales.indices.min {
            abs(fontScales[$0] - scale) < abs(fontScales[$1] - scale)
        } ?? defaultLevel
    }

    static func nearestLevel(forLegacyPointSize pointSize: Double) -> Int {
        nearestLevel(forScale: pointSize / legacyBasePointSize)
    }
}

enum ReaderLayoutMetrics {
    // ReaderChrome reserves this height above the content.
    static let pageHeaderHeight = 48.0
    static let chromeControlDiameter = 48.0
    static let contentTopSpacing = 16.0
    static let contentBottomControlSpacing = 20.0
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

    static let spacingReferencePointSize = 24.0

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

    static func pageMarginFactor(for pageMargin: Double) -> Double {
        clampPageMargins(pageMargin) / pageMarginBase
    }

    static func spacingPoints(for percentage: Double) -> CGFloat {
        CGFloat(spacingReferencePointSize * percentage / 100)
    }

    /// Converts the original multiplier-based setting to points.
    static func migrateLegacyPageMargins(_ value: Double?) -> Double {
        guard let value else { return defaultPageMargins }
        return clampPageMargins(pageMarginBase * value)
    }

    /// Converts the intermediate percentage-based setting to points.
    static func migrateLegacyPageMarginAdjustment(_ value: Double?) -> Double {
        guard let value else { return defaultPageMargins }
        return clampPageMargins(pageMarginBase * (1 + value / 100))
    }
}

struct ReaderPreferences: Codable, Equatable, Sendable {
    var fontSizeLevel: Int
    var fontSizeScale: Double { ReaderFontSize.scale(for: fontSizeLevel) }
    var fontSize: Double { ReaderFontSize.pointSize(for: fontSizeLevel) }
    var fontFamily: ReaderFontFamily
    var boldText: Bool
    var lineHeight: Double
    /// Reserved for the detailed reader settings sheet.
    var paragraphSpacing: Double
    /// Absolute horizontal page blank in points, applied to both sides.
    var pageMargins: Double
    /// Reserved for the detailed reader settings sheet.
    var paragraphIndent: Double
    var characterSpacing: Double
    var wordSpacing: Double
    var publisherStyles: Bool
    var themePreset: ReaderThemePreset
    var appearanceMode: ReaderAppearanceMode
    var pageTransition: ReaderPageTransition
    var showBookTitleInPageHeader: Bool

    init(
        fontSizeLevel: Int = ReaderFontSize.defaultLevel,
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
        pageTransition: ReaderPageTransition = .slide,
        showBookTitleInPageHeader: Bool = false
    ) {
        self.fontSizeLevel = ReaderFontSize.clampedLevel(fontSizeLevel)
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
        self.pageTransition = pageTransition
        self.showBookTitleInPageHeader = showBookTitleInPageHeader
    }

    private enum CodingKeys: String, CodingKey {
        case storageVersion
        case fontSizeLevel
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
        case pageTransition
        case showBookTitleInPageHeader
    }

    private static let currentStorageVersion = 5

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

        let fontSizeLevel: Int
        if let storedLevel = try container.decodeIfPresent(Int.self, forKey: .fontSizeLevel) {
            fontSizeLevel = ReaderFontSize.clampedLevel(storedLevel)
        } else if let legacyPointSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) {
            fontSizeLevel = ReaderFontSize.nearestLevel(forLegacyPointSize: legacyPointSize)
        } else {
            fontSizeLevel = ReaderFontSize.defaultLevel
        }

        self.init(
            fontSizeLevel: fontSizeLevel,
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
            pageTransition: try container.decodeIfPresent(ReaderPageTransition.self, forKey: .pageTransition) ?? .slide,
            showBookTitleInPageHeader: try container.decodeIfPresent(Bool.self, forKey: .showBookTitleInPageHeader) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentStorageVersion, forKey: .storageVersion)
        try container.encode(fontSizeLevel, forKey: .fontSizeLevel)
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
        try container.encode(pageTransition, forKey: .pageTransition)
        try container.encode(showBookTitleInPageHeader, forKey: .showBookTitleInPageHeader)
    }
}

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

struct ReadingPosition: Sendable {
    let locatorJSON: String
}

// MARK: - Renderer contract

enum ReaderPreferenceCommitBehavior: Sendable, Equatable {
    case coalesced
    case immediate
}

/// Identifies the part of the reader that must settle after a preference change.
enum ReaderVisualMutationKind: Sendable, Equatable {
    case theme
    case typography
    case font
    case geometry
    case full

    func merged(with other: Self) -> Self {
        self == other ? self : .full
    }
}

@MainActor
protocol ReaderRenderer: AnyObject {
    var isContentReady: Bool { get }
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
    var pageSurfaceProvider: (any PageSurfaceProvider)? { get }
    var onStateChange: (() -> Void)? { get set }

    func load() async
    func makeContentView(
        onToggleControls: @escaping () -> Void,
        onSwipeStart: @escaping () -> Void,
        onPageTurnRequested: @escaping (PageDirection) -> Void
    ) -> AnyView
    func waitForVisualUpdate(for kind: ReaderVisualMutationKind) async
    func restoreFromForeground(isDark: Bool) async
    @discardableResult
    func updateViewport(size: CGSize, safeAreaInsets: UIEdgeInsets, displayScale: CGFloat) -> Bool
    func apply(
        preferences: ReaderPreferences,
        commitBehavior: ReaderPreferenceCommitBehavior
    )
    func updateSystemAppearance(isDark: Bool)
    func selectPreset(_ preset: ReaderThemePreset)
    func tearDown()
    func selectChapter(at index: Int)
    func saveProgress()
    func readingPosition() -> ReadingPosition?
}

// MARK: - Repository

@MainActor
final class ReaderRepository {
    let book: Book

    init(book: Book) {
        self.book = book
    }

    func persist(position: ReadingPosition?, progress: Double) {
        book.progressPercent = min(max(progress, 0), 1)
        book.lastReadAt = .now

        guard let position else { return }
        book.readerLocatorJSON = position.locatorJSON
    }
}

// MARK: - Shared reading orchestration

@MainActor
@Observable
final class ReaderEngine {
    let repository: ReaderRepository
    let renderer: any ReaderRenderer

    private(set) var preferences: ReaderPreferences
    var onStateChange: (() -> Void)?

    init(book: Book) {
        let repository = ReaderRepository(book: book)
        let renderer = ReadiumRenderer(book: book)
        self.repository = repository
        self.renderer = renderer
        let initialPreferences = ReaderPreferencesStore.load() ?? renderer.preferences
        preferences = initialPreferences
        renderer.apply(
            preferences: preferences,
            commitBehavior: .coalesced
        )
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
        onSwipeStart: @escaping () -> Void,
        onPageTurnRequested: @escaping (PageDirection) -> Void
    ) -> AnyView {
        renderer.makeContentView(
            onToggleControls: onToggleControls,
            onSwipeStart: onSwipeStart,
            onPageTurnRequested: onPageTurnRequested
        )
    }

    func waitForVisualUpdate(for kind: ReaderVisualMutationKind = .full) async {
        await renderer.waitForVisualUpdate(for: kind)
    }

    func restoreFromForeground(isDark: Bool) async {
        await renderer.restoreFromForeground(isDark: isDark)
        synchronizeFromRenderer()
    }

    @discardableResult
    func updateViewport(size: CGSize, safeAreaInsets: UIEdgeInsets, displayScale: CGFloat) -> Bool {
        guard renderer.updateViewport(
            size: size,
            safeAreaInsets: safeAreaInsets,
            displayScale: displayScale
        ) else {
            return false
        }
        synchronizeFromRenderer()
        return true
    }

    func apply(
        preferences: ReaderPreferences,
        commitBehavior: ReaderPreferenceCommitBehavior = .coalesced
    ) {
        renderer.apply(
            preferences: preferences,
            commitBehavior: commitBehavior
        )
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

    func selectChapter(at index: Int) {
        renderer.selectChapter(at: index)
    }

    func saveProgress() {
        renderer.saveProgress()
        repository.persist(position: renderer.readingPosition(), progress: renderer.progress)
        synchronizeFromRenderer()
    }

    private func synchronizeFromRenderer() {
        preferences = renderer.preferences
        ReaderPreferencesStore.save(preferences)
    }
}

@MainActor
@Observable
final class ReaderViewModel {
    let book: Book
    let engine: ReaderEngine

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
    var isContentReady: Bool { engine.renderer.isContentReady }
    var pageSurfaceProvider: (any PageSurfaceProvider)? { engine.renderer.pageSurfaceProvider }

    func loadIfNeeded() async {
        await engine.loadIfNeeded()
        synchronize()
    }

    func synchronizeBookTitle() {
        title = book.title
        stateRevision &+= 1
    }

    func makeContentView(
        onToggleControls: @escaping () -> Void,
        onSwipeStart: @escaping () -> Void,
        onPageTurnRequested: @escaping (PageDirection) -> Void
    ) -> AnyView {
        return engine.makeContentView(
            onToggleControls: onToggleControls,
            onSwipeStart: onSwipeStart,
            onPageTurnRequested: onPageTurnRequested
        )
    }

    func waitForVisualUpdate(for kind: ReaderVisualMutationKind = .full) async {
        await engine.waitForVisualUpdate(for: kind)
    }

    func restoreFromForeground(isDark: Bool) async {
        await engine.restoreFromForeground(isDark: isDark)
        synchronize()
    }

    @discardableResult
    func updateViewport(size: CGSize, safeAreaInsets: UIEdgeInsets, displayScale: CGFloat) -> Bool {
        guard engine.updateViewport(
            size: size,
            safeAreaInsets: safeAreaInsets,
            displayScale: displayScale
        ) else {
            return false
        }
        synchronize()
        return true
    }

    func setPreference(
        _ update: (inout ReaderPreferences) -> Void,
        commitBehavior: ReaderPreferenceCommitBehavior = .coalesced
    ) {
        var next = preferences
        update(&next)
        engine.apply(preferences: next, commitBehavior: commitBehavior)
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

    func setFontSizeLevel(_ level: Int) {
        setPreference {
            $0.fontSizeLevel = ReaderFontSize.clampedLevel(level)
        }
    }

    func setAppearance(_ appearance: ReaderAppearanceMode) {
        setPreference(
            { $0.appearanceMode = appearance },
            commitBehavior: .immediate
        )
    }

    func setPageTransition(_ transition: ReaderPageTransition) {
        setPreference(
            { $0.pageTransition = transition },
            commitBehavior: .immediate
        )
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

    func visualMutationKind(for draft: ReaderCustomizationDraft) -> ReaderVisualMutationKind {
        var kind: ReaderVisualMutationKind?

        func include(_ candidate: ReaderVisualMutationKind) {
            kind = kind?.merged(with: candidate) ?? candidate
        }

        if preferences.fontFamily != draft.fontFamily
            || preferences.boldText != draft.boldText {
            include(.font)
        }
        if preferences.lineHeight != draft.lineHeight
            || preferences.characterSpacing != draft.characterSpacing
            || preferences.wordSpacing != draft.wordSpacing
            || preferences.publisherStyles != draft.publisherStyles {
            include(.typography)
        }
        if preferences.pageMargins != draft.pageMargins
            || preferences.paragraphIndent != draft.paragraphIndent {
            include(.geometry)
        }

        return kind ?? .full
    }

    func apply(_ draft: ReaderCustomizationDraft) {
        setPreference(
            { preferences in
                preferences.fontFamily = draft.fontFamily
                preferences.boldText = draft.boldText
                preferences.lineHeight = ReaderLayoutMetrics.clampLineHeight(draft.lineHeight)
                preferences.pageMargins = ReaderLayoutMetrics.clampPageMargins(draft.pageMargins)
                preferences.paragraphIndent = ReaderLayoutMetrics.fixedParagraphIndent
                preferences.characterSpacing = ReaderLayoutMetrics.clampCharacterSpacing(draft.characterSpacing)
                preferences.wordSpacing = ReaderLayoutMetrics.clampWordSpacing(draft.wordSpacing)
                preferences.publisherStyles = draft.publisherStyles
            },
            commitBehavior: .immediate
        )
    }

    func selectChapter(at index: Int) {
        engine.selectChapter(at: index)
        synchronize()
    }

    func saveProgress() {
        engine.saveProgress()
        synchronize()
    }

    private func synchronize() {
        let renderer = engine.renderer
        title = book.title
        isLoading = renderer.isLoading
        errorMessage = renderer.errorMessage
        currentChapterID = renderer.currentChapterID
        progress = renderer.progress
        chapters = renderer.chapters
        previewText = renderer.previewText
        previewChapterTitle = renderer.previewChapterTitle
        isLoadingPreview = renderer.isLoadingPreview
        preferences = renderer.preferences

        stateRevision &+= 1
    }
}
