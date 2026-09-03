
import Foundation

struct BookChapter: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let href: String
    let index: Int
}
