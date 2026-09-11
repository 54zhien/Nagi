import Foundation
import ReadiumNavigator
import ReadiumShared

/// Owns the open publication and the navigator built from it.
///
/// The session is the only place that knows how a book turns into a Readium
/// publication, and the only owner of the navigator's lifetime.
@MainActor
final class ReadiumSession {
    /// The result of opening a book.
    struct Opened {
        let navigator: EPUBNavigatorViewController
        let initialLocation: Locator?
    }

    private(set) var publication: Publication?
    private(set) var navigator: EPUBNavigatorViewController?
    /// The asset that is actually being read; TXT books read a generated EPUB.
    private(set) var publicationURL: URL?

    var isReflowable: Bool {
        guard let publication else { return false }
        return publication.metadata.layout != .fixed
    }

    /// Resolves the book's reading asset, opens it and builds the navigator.
    ///
    /// Both the preferences and the initial location can only be resolved once
    /// the publication is open - the preferences depend on whether the layout
    /// is reflowable, the location on the reading order - so the caller
    /// supplies both as closures.
    func open(
        book: Book,
        preferences: () -> EPUBPreferences,
        initialLocation: (Publication) async -> Locator?
    ) async throws -> Opened {
        let readingURL = try await ReaderAssetResolver.resolve(book: book)
        try Task.checkCancellation()
        let publication = try await ReadiumService.shared.openEPUB(at: readingURL)
        try Task.checkCancellation()

        self.publicationURL = readingURL
        self.publication = publication

        let navigatorPreferences = preferences()
        let location = await initialLocation(publication)
        try Task.checkCancellation()

        let navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: location,
            config: .init(
                preferences: navigatorPreferences,
                disablePageTurnsWhileScrolling: true,
                continuousScroll: true,
                preloadPreviousPositionCount: 2,
                preloadNextPositionCount: 6,
                fontFamilyDeclarations: EPUBFontResources.declarations(),
                readiumCSSRSProperties: CSSRSProperties(
                    pageGutter: CSSPxLength(ReaderLayoutMetrics.pageMarginBase)
                )
            )
        )
        self.navigator = navigator
        return Opened(navigator: navigator, initialLocation: location)
    }
}
