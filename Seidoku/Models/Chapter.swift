//
//  Chapter.swift
//  Seidoku
//
//  章节模型（运行时加载，不存入 SwiftData，正文从文件系统按需读取）。
//

import Foundation

struct BookChapter: Identifiable, Hashable {
    /// 章节标识：EPUB 用 archive 内路径；TXT 用索引。
    let id: String
    let title: String
    let href: String
    let index: Int
}
