
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

    private var importsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Imports", isDirectory: true)
    }

    @discardableResult
    func importFiles(_ urls: [URL]) throws -> [URL] {
        do {
            try FileManager.default.createDirectory(
                at: importsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ImportError.cannotCreateDirectory(error.localizedDescription)
        }

        var imported: [URL] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            let destination = importsDirectory.appendingPathComponent(url.lastPathComponent)
            let temporary = importsDirectory.appendingPathComponent(
                ".\(UUID().uuidString).import",
                isDirectory: false
            )
            do {
                try FileManager.default.copyItem(at: url, to: temporary)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(
                        destination,
                        withItemAt: temporary,
                        backupItemName: nil,
                        options: []
                    )
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                imported.append(destination)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw ImportError.copyFailed("导入「\(url.lastPathComponent)」失败：\(error.localizedDescription)")
            }
        }
        return imported
    }
}
