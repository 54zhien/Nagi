
import os

enum ReaderPerformanceSignposts {
    private static let log = OSLog(
        subsystem: "com.imzhien.Nagi",
        category: "ReaderPerformance"
    )

    static func glassTouchBegan() {
        os_signpost(.event, log: log, name: "GlassTouchBegan")
    }

    static func glassTouchEnded() {
        os_signpost(.event, log: log, name: "GlassTouchEnded")
    }

    static func readerMutationCommitted() {
        os_signpost(.event, log: log, name: "ReaderMutationCommitted")
    }
}
