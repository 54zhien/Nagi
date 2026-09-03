
import Foundation
import ReadiumShared
import ReadiumStreamer

enum ReadiumServiceError: LocalizedError {
    case invalidFileURL
    case fileNotFound
    case notEPUB

    var errorDescription: String? {
        switch self {
        case .invalidFileURL:
            return "电子书文件路径无效"
        case .fileNotFound:
            return "找不到电子书文件，可能已被移动或删除"
        case .notEPUB:
            return "所选文件不是受支持的 EPUB"
        }
    }
}

@MainActor
final class ReadiumService {
    static let shared = ReadiumService()

    private let assetRetriever: AssetRetriever
    private let publicationOpener: PublicationOpener

    private init() {
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        self.assetRetriever = assetRetriever
        publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )
    }

    func openEPUB(at url: URL, sender: Any? = nil) async throws -> Publication {
        guard let fileURL = FileURL(url: url) else {
            throw ReadiumServiceError.invalidFileURL
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReadiumServiceError.fileNotFound
        }

        let asset = try await assetRetriever.retrieve(url: fileURL).get()
        let publication = try await publicationOpener.open(
            asset: asset,
            allowUserInteraction: true,
            sender: sender
        ).get()

        guard publication.conforms(to: .epub) else {
            throw ReadiumServiceError.notEPUB
        }
        return publication
    }
}
