//
//  EPUBReadingContentProvider.swift
//  Nagi
//
//  阅读阶段的 EPUB 资源读取入口。解析细节集中在 EPUBParser，
//  避免阅读模型直接承担 ZIP 资源路由。
//

import Foundation

struct EPUBReadingContentProvider: Sendable {
    private let parser = EPUBParser()

    func loadChapterContent(url: URL, href: String) throws -> String {
        try parser.loadChapterContent(url: url, href: href)
    }
}
