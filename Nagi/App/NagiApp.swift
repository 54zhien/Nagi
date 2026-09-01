//
//  NagiApp.swift
//  Nagi
//
//  App 入口。正式 Root 由持久化 UIKit 容器承载。
//

import SwiftUI
import SwiftData

@main
struct NagiApp: App {
    @State private var importState = AppImportState.shared

    var body: some Scene {
        WindowGroup {
            NagiRootRepresentable()
                .ignoresSafeArea(.container, edges: .all)
                .onOpenURL { url in
                    handleIncomingFile(url)
                }
                .alert("导入", isPresented: Binding(
                    get: { importState.message != nil },
                    set: { if !$0 { importState.message = nil } }
                )) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(importState.message ?? "")
                }
        }
        .modelContainer(Persistence.container)
    }

    /// 处理通过「用 Nagi 打开」传入的文件。
    @MainActor
    private func handleIncomingFile(_ url: URL) {
        Task {
            var results: [BookImportResult] = []
            do {
                let files = try FileImportService().importFiles([url])
                results = try await LibraryViewModel.parseBooksInBackground(files)
                let context = Persistence.container.mainContext
                try LibraryViewModel.upsert(results, into: context)
                try context.save()
                AppImportState.shared.message = "已导入「\(results.first?.title ?? "书")」"
            } catch {
                for result in results {
                    TXTReaderAssetStore.removeAsset(atPath: result.readerAssetURL)
                }
                AppImportState.shared.message = "导入失败：\(error.localizedDescription)"
            }
        }
    }
}
