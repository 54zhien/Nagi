import Foundation

/// Converts stable, container-relative book paths into URLs inside the current app sandbox.
enum BookFileLocator {
    private static let documentsComponent = "Documents"

    static func persistedPath(
        for url: URL,
        fileManager: FileManager = .default
    ) -> String {
        let standardizedURL = url.standardizedFileURL
        let documentsURL = documentsDirectory(fileManager: fileManager).standardizedFileURL
        let documentsPath = documentsURL.path
        let filePath = standardizedURL.path
        let prefix = documentsPath.hasSuffix("/") ? documentsPath : documentsPath + "/"

        guard filePath.hasPrefix(prefix) else { return filePath }
        return String(filePath.dropFirst(prefix.count))
    }

    static func resolve(
        _ storedPath: String,
        fileManager: FileManager = .default
    ) -> URL? {
        let relativePath: String
        if storedPath.hasPrefix("/") {
            guard let legacyRelativePath = relativePathFromLegacyAbsolutePath(storedPath) else {
                return nil
            }
            relativePath = legacyRelativePath
        } else {
            relativePath = storedPath
        }

        let documentsURL = documentsDirectory(fileManager: fileManager).standardizedFileURL
        let importsURL = documentsURL.appending(path: "Imports", directoryHint: .isDirectory)
        let candidateURL = documentsURL.appending(path: relativePath).standardizedFileURL
        let importsPrefix = importsURL.path.hasSuffix("/") ? importsURL.path : importsURL.path + "/"
        guard candidateURL.path.hasPrefix(importsPrefix) else { return nil }
        return candidateURL
    }

    /// Returns a stable representation for both new relative paths and legacy sandbox paths.
    static func normalizedPersistedPath(_ storedPath: String) -> String {
        guard storedPath.hasPrefix("/") else { return storedPath }
        return relativePathFromLegacyAbsolutePath(storedPath) ?? storedPath
    }

    private static func documentsDirectory(fileManager: FileManager) -> URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func relativePathFromLegacyAbsolutePath(_ path: String) -> String? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard let documentsIndex = components.lastIndex(of: documentsComponent) else {
            return nil
        }

        let relativeComponents = components.dropFirst(documentsIndex + 1)
        guard relativeComponents.first == "Imports" else { return nil }
        return relativeComponents.joined(separator: "/")
    }
}

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

    static func stagingPersistedPath(operationID: UUID, fileExtension: String) -> String {
        let extensionSuffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        return "Imports/.staging/\(operationID.uuidString)\(extensionSuffix)"
    }

    func stageFile(_ url: URL, operationID: UUID) throws -> URL {
        let stagingDirectory = importsDirectory.appendingPathComponent(".staging", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ImportError.cannotCreateDirectory(error.localizedDescription)
        }

        let stagedName = URL(
            fileURLWithPath: Self.stagingPersistedPath(
                operationID: operationID,
                fileExtension: url.pathExtension
            )
        ).lastPathComponent
        let stagedURL = stagingDirectory.appendingPathComponent(stagedName)
        let temporaryURL = stagingDirectory.appendingPathComponent(".\(UUID().uuidString).copy")
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        do {
            try FileManager.default.copyItem(at: url, to: temporaryURL)
            if FileManager.default.fileExists(atPath: stagedURL.path) {
                _ = try FileManager.default.replaceItemAt(stagedURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: stagedURL)
            }
        } catch {
            throw ImportError.copyFailed("导入「\(url.lastPathComponent)」失败：\(error.localizedDescription)")
        }
        return stagedURL
    }

    func commitStagedFile(_ stagedURL: URL, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
        }
    }

    static func removeAbandonedCopyFiles(fileManager: FileManager = .default) {
        guard let documentsURL = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return }
        let stagingDirectory = documentsURL
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(".staging", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.lastPathComponent.hasSuffix(".copy") {
            try? fileManager.removeItem(at: file)
        }
    }

}
