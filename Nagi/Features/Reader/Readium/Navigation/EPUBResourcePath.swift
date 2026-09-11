import Foundation

/// Normalises an EPUB resource href.
///
/// The table of contents, the current reading location and the chapter
/// preview all have to agree on what "the same resource" means; an href can
/// carry a fragment, a query, a leading slash or percent-encoding that none
/// of them care about.
enum EPUBResourcePath {
    static func normalize(_ href: String) -> String {
        let resource = href
            .split(whereSeparator: { $0 == "#" || $0 == "?" })
            .first
            .map(String.init) ?? href
        var decoded = resource.removingPercentEncoding ?? resource
        while decoded.hasPrefix("/") {
            decoded.removeFirst()
        }
        return decoded
    }
}
