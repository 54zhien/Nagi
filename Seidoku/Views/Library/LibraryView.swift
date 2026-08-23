//
//  LibraryView.swift
//  Seidoku
//
//  书库：书架列表 + 导入入口（第一阶段占位，后续实现导入/书架）
//

import SwiftUI

struct LibraryView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "书库是空的",
                systemImage: "books.vertical",
                description: Text("导入 TXT / EPUB 小说后会显示在这里")
            )
            .navigationTitle("书库")
        }
    }
}

#Preview {
    LibraryView()
}
