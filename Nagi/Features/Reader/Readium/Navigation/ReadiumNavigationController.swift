import ReadiumNavigator
import ReadiumShared

/// What the reader has to persist after a location change.
struct ReadiumNavigationUpdate {
    let locatorTitle: String?
    let chapterChanged: Bool
    let locatorJSON: String?
}

/// Owns where the reader currently is: the table of contents, the current
/// resource, the stored locator and the reading progress.
@MainActor
final class ReadiumNavigationController {
    private weak var navigator: EPUBNavigatorViewController?

    private(set) var tableOfContents: [EPUBTOCEntry] = []
    private(set) var currentHref: String?
    private(set) var currentLocatorJSON: String?
    private(set) var progress: Double = 0

    var currentTOCEntryID: String? {
        guard let currentHref else { return nil }
        let currentResource = EPUBResourcePath.normalize(currentHref)
        return tableOfContents.first {
            EPUBResourcePath.normalize($0.link.href) == currentResource
        }?.id
    }

    var currentTOCIndex: Int? {
        guard let currentHref else { return nil }
        let currentResource = EPUBResourcePath.normalize(currentHref)
        return tableOfContents.firstIndex {
            EPUBResourcePath.normalize($0.link.href) == currentResource
        }
    }

    func attach(_ navigator: EPUBNavigatorViewController?) {
        self.navigator = navigator
    }

    /// Seeds the location before the navigator has reported one.
    func seedCurrentHref(_ href: String?) {
        currentHref = href
    }

    /// Restores the stored position when the reader opens.
    func restore(locatorJSON: String?, progress: Double) {
        self.currentLocatorJSON = locatorJSON
        self.progress = min(max(progress, 0), 1)
    }

    func clearLocatorJSON() {
        currentLocatorJSON = nil
    }

    /// Applies a Readium location change and reports what has to be persisted.
    func apply(locator: Locator) -> ReadiumNavigationUpdate {
        let locatorTitle = locator.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let nextHref = locator.href.path
        let chapterChanged = currentHref.map {
            EPUBResourcePath.normalize($0) != EPUBResourcePath.normalize(nextHref)
        } ?? true

        currentHref = nextHref
        if let totalProgression = locator.locations.totalProgression {
            progress = min(max(totalProgression, 0), 1)
        }
        let locatorJSON = try? locator.jsonString()
        if let locatorJSON {
            currentLocatorJSON = locatorJSON
        }

        return ReadiumNavigationUpdate(
            locatorTitle: locatorTitle,
            chapterChanged: chapterChanged,
            locatorJSON: locatorJSON
        )
    }

    func loadTableOfContents(from publication: Publication) async {
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

    func goLeft() {
        guard let navigator else { return }
        Task { await navigator.goLeft(options: .animated) }
    }

    func goRight() {
        guard let navigator else { return }
        Task { await navigator.goRight(options: .animated) }
    }

    func go(to entry: EPUBTOCEntry) {
        guard let navigator else { return }
        Task { await navigator.go(to: entry.link, options: .animated) }
    }
}
