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
import SwiftUI
import UIKit

extension ReaderTheme {
    /// Readium 的主题映射只属于 EPUB 渲染层，主题值本身由所有阅读格式共享。
    var readiumTheme: ReadiumNavigator.Theme {
        switch self {
        case .light: return .light
        case .sepia: return .sepia
        case .dark: return .dark
        }
    }

    /// 将应用主题的正文背景传给 Readium，避免 Navigator 使用另一套默认颜色。
    var readiumBackgroundColor: ReadiumNavigator.Color? {
        ReadiumNavigator.Color(uiColor: UIColor(background))
    }
}

extension ReaderFontFamily {
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
    private(set) var currentReadingHref: String?
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
    var lineHeight: Double { didSet { preferencesDidChange() } }
    var pageMargins: Double { didSet { preferencesDidChange() } }
    var paragraphIndent: Double { didSet { preferencesDidChange() } }
    var contentTopInset: Double { didSet { preferencesDidChange() } }
    var contentBottomInset: Double { didSet { preferencesDidChange() } }
    var theme: ReaderTheme { didSet { preferencesDidChange() } }
    var flowMode: ReaderFlowMode { didSet { preferencesDidChange() } }
    var pageTransition: ReaderPageTransitionMode { didSet { persistPreferences() } }
    var publisherStyles: Bool { didSet { preferencesDidChange() } }
    var showBookTitleInPageHeader: Bool { didSet { persistPreferences() } }

    var onToggleControls: (() -> Void)?
    var onSwipeStart: (() -> Void)?

    private var publication: Publication?
    private var preferenceUpdateTask: Task<Void, Never>?
    private var hasLoaded = false

    private enum PreferenceKey {
        static let fontScale = "reader.epub.fontScale"
        static let fontFamily = "reader.epub.fontFamily"
        static let lineHeight = "reader.epub.lineHeight"
        static let pageMargins = "reader.epub.pageMargins"
        static let paragraphIndent = "reader.epub.paragraphIndent"
        static let contentTopInset = "reader.epub.contentTopInset"
        static let contentBottomInset = "reader.epub.contentBottomInset"
        static let theme = "reader.epub.theme"
        static let flowMode = "reader.epub.flowMode"
        static let pageTransition = "reader.epub.pageTransition"
        static let publisherStyles = "reader.epub.publisherStyles"
        static let showBookTitleInPageHeader = "reader.epub.showBookTitleInPageHeader"
    }

    init(book: Book) {
        self.book = book
        title = book.title
        progress = min(max(book.progressPercent, 0), 1)

        let defaults = UserDefaults.standard
        fontScale = defaults.object(forKey: PreferenceKey.fontScale) as? Double ?? 1.0
        fontFamily = defaults.string(forKey: PreferenceKey.fontFamily).flatMap(ReaderFontFamily.init) ?? .systemSerif
        lineHeight = defaults.object(forKey: PreferenceKey.lineHeight) as? Double ?? 1.5
        pageMargins = defaults.object(forKey: PreferenceKey.pageMargins) as? Double ?? 1.0
        paragraphIndent = defaults.object(forKey: PreferenceKey.paragraphIndent) as? Double ?? 2.0
        contentTopInset = defaults.object(forKey: PreferenceKey.contentTopInset) as? Double ?? 56
        contentBottomInset = defaults.object(forKey: PreferenceKey.contentBottomInset) as? Double ?? 32
        theme = defaults.string(forKey: PreferenceKey.theme).flatMap(ReaderTheme.init) ?? .light
        flowMode = defaults.string(forKey: PreferenceKey.flowMode).flatMap(ReaderFlowMode.init) ?? .paged
        pageTransition = defaults.string(forKey: PreferenceKey.pageTransition).flatMap(ReaderPageTransitionMode.init) ?? .pageCurl
        publisherStyles = defaults.object(forKey: PreferenceKey.publisherStyles) as? Bool ?? false
        showBookTitleInPageHeader = defaults.object(forKey: PreferenceKey.showBookTitleInPageHeader) as? Bool ?? false
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

    func isCurrent(_ entry: EPUBTOCEntry) -> Bool {
        currentTOCEntryID == entry.id
    }

    func resetTypography() {
        fontScale = 1.0
        fontFamily = .systemSerif
        lineHeight = 1.5
        pageMargins = 1.0
        paragraphIndent = 2.0
        contentTopInset = 56
        contentBottomInset = 32
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
        // Readium 当前只区分分页与滚动；两种分页过渡先共享分页引擎，
        // pageTransition 作为独立偏好保留，后续接入具体动画。
        EPUBPreferences(
            backgroundColor: theme.readiumBackgroundColor,
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
        defaults.set(contentTopInset, forKey: PreferenceKey.contentTopInset)
        defaults.set(contentBottomInset, forKey: PreferenceKey.contentBottomInset)
        defaults.set(theme.rawValue, forKey: PreferenceKey.theme)
        defaults.set(flowMode.rawValue, forKey: PreferenceKey.flowMode)
        defaults.set(pageTransition.rawValue, forKey: PreferenceKey.pageTransition)
        defaults.set(publisherStyles, forKey: PreferenceKey.publisherStyles)
        defaults.set(showBookTitleInPageHeader, forKey: PreferenceKey.showBookTitleInPageHeader)
    }

    private func updateLocation(_ locator: Locator) {
        chapterTitle = locator.title ?? chapterTitle
        currentReadingHref = locator.href.path
        if let totalProgression = locator.locations.totalProgression {
            progress = min(max(totalProgression, 0), 1)
        }
        book.readerLocatorJSON = locator.jsonString
        book.progressPercent = progress
        book.lastReadAt = .now
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
