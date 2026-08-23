//
//  LibraryView.swift
//  Seidoku
//
//  书库：书架列表 + 导入入口（右上角 + 导入 EPUB/TXT）
//

import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @State private var isImporterPresented = false
    @State private var importErrorMessage: String?

    private let importService = FileImportService()

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "书库是空的",
                systemImage: "books.vertical",
                description: Text("点右上角 + 导入 TXT / EPUB 小说")
            )
            .navigationTitle("书库")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("导入小说")
                }
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.plainText, .epub],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .alert(
                "导入失败",
                isPresented: Binding(
                    get: { importErrorMessage != nil },
                    set: { if !$0 { importErrorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importErrorMessage ?? "")
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            do {
                try importService.importFiles(urls)
            } catch {
                importErrorMessage = error.localizedDescription
            }
        case .failure(let error):
            importErrorMessage = error.localizedDescription
        }
    }
}

extension UTType {
    /// EPUB 没有系统内置 UTType，用文件扩展名动态类型。
    static let epub = UTType(filenameExtension: "epub") ?? .data
}

#Preview {
    LibraryView()
}
