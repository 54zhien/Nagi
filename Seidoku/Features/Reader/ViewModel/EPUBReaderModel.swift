//
//  EPUBReaderModel.swift
//  Seidoku
//
//  Readium EPUB 阅读状态、用户偏好、目录与稳定阅读位置。
//

import Foundation
import Observation
import ReadiumNavigator
import ReadiumShared
import UIKit

enum EPUBReaderTheme: String, CaseIterable, Identifiable {
    case light, sepia, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "白色"
        case .sepia: return "米黄"
        case .dark: return "深色"
        }
    }

    var readiumTheme: ReadiumNavigator.Theme {
        switch self {
        case .light: return .light
        case .sepia: return .sepia
        case .dark: return .dark
        }
    }
}

enum EPUBFlowMode: String, CaseIterable, Identifiable {
    case paged, scroll

    var id: String { rawValue }
    var label: String { self == .paged ? "横向分页" : "上下滚动" }
}

enum EPUBFontFamily: String, CaseIterable, Identifiable {
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

@MainActor
@Observable
final class EPUBReaderModel {
    let book: Book

    var navigator: EPUBNavigatorViewController?
    var isLoading = false
    var errorMessage: String?
    var title: String
    var chapterTitle = ""
    var progress = 0.0
    var tableOfContents: [EPUBTOCEntry] = []

    var fontScale: Double { didSet { preferencesDidChange() } }
    var fontFamily: EPUBFontFamily { didSet { preferencesDidChange() } }
    var lineHeight: Double { didSet { preferencesDidChange() } }
    var pageMargins: Double { didSet { preferencesDidChange() } }
    var paragraphIndent: Double { didSet { preferencesDidChange() } }
    var theme: EPUBReaderTheme { didSet { preferencesDidChange() } }
    var flowMode: EPUBFlowMode { didSet { preferencesDidChange() } }
    var publisherStyles: Bool { didSet { preferencesDidChange() } }

    var onToggleControls: (() -> Void)?

    private var publication: Publication?
    private var preferenceUpdateTask: Task<Void, Never>?
    private var hasLoaded = false

    private enum PreferenceKey {
        static let fontScale = "reader.epub.fontScale"
        static let fontFamily = "reader.epub.fontFamily"
        static let lineHeight = "reader.epub.lineHeight"
        static let pageMargins = "reader.epub.pageMargins"
        static let paragraphIndent = "reader.epub.paragraphIndent"
        static let theme = "reader.epub.theme"
        static let flowMode = "reader.epub.flowMode"
        static let publisherStyles = "reader.epub.publisherStyles"
    }

    init(book: Book) {
        self.book = book
        title = book.title
        progress = min(max(book.progressPercent, 0), 1)

        let defaults = UserDefaults.standard
        fontScale = defaults.object(forKey: PreferenceKey.fontScale) as? Double ?? 1.0
        fontFamily = defaults.string(forKey: PreferenceKey.fontFamily).flatMap(EPUBFontFamily.init) ?? .systemSerif
        lineHeight = defaults.object(forKey: PreferenceKey.lineHeight) as? Double ?? 1.5
        pageMargins = defaults.object(forKey: PreferenceKey.pageMargins) as? Double ?? 1.0
        paragraphIndent = defaults.object(forKey: PreferenceKey.paragraphIndent) as? Double ?? 2.0
        theme = defaults.string(forKey: PreferenceKey.theme).flatMap(EPUBReaderTheme.init) ?? .light
        flowMode = defaults.string(forKey: PreferenceKey.flowMode).flatMap(EPUBFlowMode.init) ?? .paged
        publisherStyles = defaults.object(forKey: PreferenceKey.publisherStyles) as? Bool ?? false
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
                        .compact: (top: 28, bottom: 32),
                        .regular: (top: 48, bottom: 48),
                    ],
                    preloadPreviousPositionCount: 2,
                    preloadNextPositionCount: 6
                )
            )
            navigator.delegate = self
            self.navigator = navigator
            hasLoaded = true

            if let initialLocation {
                updateLocation(initialLocation)
            }

            await loadTableOfContents(from: publication)
        } catch {
            errorMessage = "无法打开 EPUB：\(error.localizedDescription)"
        }
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

    func resetTypography() {
        fontScale = 1.0
        fontFamily = .systemSerif
        lineHeight = 1.5
        pageMargins = 1.0
        paragraphIndent = 2.0
        publisherStyles = false
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

    private func preferencesDidChange() {
        persistPreferences()
        preferenceUpdateTask?.cancel()
        preferenceUpdateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, let self, let navigator = self.navigator else { return }
            navigator.submitPreferences(self.makePreferences())
        }
    }

    private func makePreferences() -> EPUBPreferences {
        EPUBPreferences(
            fontFamily: fontFamily.readiumFontFamily,
            fontSize: fontScale,
            lineHeight: lineHeight,
            pageMargins: pageMargins,
            paragraphIndent: paragraphIndent,
            publisherStyles: publisherStyles,
            scroll: flowMode == .scroll,
            spread: .auto,
            textNormalization: !publisherStyles,
            theme: theme.readiumTheme
        )
    }

    private func persistPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(fontScale, forKey: PreferenceKey.fontScale)
        defaults.set(fontFamily.rawValue, forKey: PreferenceKey.fontFamily)
        defaults.set(lineHeight, forKey: PreferenceKey.lineHeight)
        defaults.set(pageMargins, forKey: PreferenceKey.pageMargins)
        defaults.set(paragraphIndent, forKey: PreferenceKey.paragraphIndent)
        defaults.set(theme.rawValue, forKey: PreferenceKey.theme)
        defaults.set(flowMode.rawValue, forKey: PreferenceKey.flowMode)
        defaults.set(publisherStyles, forKey: PreferenceKey.publisherStyles)
    }

    private func updateLocation(_ locator: Locator) {
        chapterTitle = locator.title ?? chapterTitle
        if let totalProgression = locator.locations.totalProgression {
            progress = min(max(totalProgression, 0), 1)
        }
        book.readerLocatorJSON = locator.jsonString
        book.progressPercent = progress
        book.lastReadAt = .now
    }
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


