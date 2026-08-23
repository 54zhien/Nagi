//
//  FileImportService.swift
//  Seidoku
//
//  文件导入服务：把用户从「文件」App 选择的 EPUB/TXT 复制到 App 沙盒。
//

import Foundation

struct FileImportService {
    enum ImportError: LocalizedError {
        case cannotCreateDirectory(String)
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreateDirectory(let message):
                return "无法创建导入目录：\(message)"
            case .copyFailed(let message):
                return message
            }
        }
    }

    /// 导入文件的沙盒目录（Documents/Imports）
    private var importsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Imports", isDirectory: true)
    }

    /// 把选中的文件复制到沙盒，正确处理 security-scoped 权限。
    func importFiles(_ urls: [URL]) throws {
        do {
            try FileManager.default.createDirectory(
                at: importsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ImportError.cannotCreateDirectory(error.localizedDescription)
        }

        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            let destination = importsDirectory.appendingPathComponent(url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                throw ImportError.copyFailed("导入「\(url.lastPathComponent)」失败：\(error.localizedDescription)")
            }
        }
    }
}
