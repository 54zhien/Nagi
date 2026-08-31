//
//  ReaderPerformanceSignposts.swift
//  Nagi
//
//  Lightweight points for the Phase 6 Instruments comparison.  These are
//  events, not timing logic: they do not allocate or alter the reader path.
//

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
