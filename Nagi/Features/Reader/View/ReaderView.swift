//
//  ReaderView.swift
//  Nagi
//
//  阅读器格式路由：EPUB 与 TXT 进入各自的原生渲染器，共用 ReaderChrome。
//

import SwiftUI

struct ReaderView: View {
    let book: Book

    var body: some View {
        switch book.format {
        case .epub:
            EPUBReaderView(book: book)
        case .txt:
            TXTReaderView(book: book)
        }
    }
}
