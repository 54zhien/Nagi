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

    var systemImage: String {
        switch self {
        case .light: return "sun.max"
        case .dark: return "moon.fill"
        case .system: return "circle.lefthalf.filled"
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

struct ReaderPreferences: Codable, Equatable, Sendable {
    var fontSize: Double = ReaderFontSize.defaultValue
    var fontFamily: ReaderFontFamily = .systemSerif
    var boldText = false
    var lineHeight: Double = 1.5
    var paragraphSpacing: Double = 10
    var pageMargins: Double = 1
    var contentTopInset: Double = 56
    var contentBottomInset: Double = 32
    var paragraphIndent: Double = 2
    var publisherStyles = false
    var themePreset: ReaderThemePreset = .original
    var appearanceMode: ReaderAppearanceMode = .system
    var brightness: Double = 0.82
    var pageTransition: ReaderPageTransition = .slide
    var showBookTitleInPageHeader = false
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
    var contentTopInset: Double
    var contentBottomInset: Double
    var pageMargins: Double
    var paragraphIndent: Double
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
        preferences = ReaderPreferencesStore.load() ?? renderer.preferences
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
        renderer.apply(preferences: preferences)
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
            contentTopInset: preferences.contentTopInset,
            contentBottomInset: preferences.contentBottomInset,
            pageMargins: preferences.pageMargins,
            paragraphIndent: preferences.paragraphIndent,
            publisherStyles: preferences.publisherStyles
        )
    }

    func apply(_ draft: ReaderCustomizationDraft) {
        setPreference { preferences in
            preferences.fontFamily = draft.fontFamily
            preferences.boldText = draft.boldText
            preferences.lineHeight = draft.lineHeight
            preferences.contentTopInset = draft.contentTopInset
            preferences.contentBottomInset = draft.contentBottomInset
            preferences.pageMargins = draft.pageMargins
            preferences.paragraphIndent = draft.paragraphIndent
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
        stateRevision &+= 1
    }
}
