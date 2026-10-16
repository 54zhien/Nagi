import Foundation

enum TXTTextEncoding: Sendable, Equatable {
    case utf8, utf16LittleEndian, utf16BigEndian, utf32LittleEndian, utf32BigEndian, gb18030
}

enum TXTDecodingMethod: Sendable, Equatable {
    case empty, byteOrderMark, nulHeuristic, utf8, gb18030, lossyUTF8
}

/// Describes the decoder actually used, not proof of the source's intended encoding.
/// usedLossyUTF8Fallback does not certify other decoder paths as lossless.
struct TXTDecodingResult: Sendable {
    let text: String
    let encoding: TXTTextEncoding?
    let method: TXTDecodingMethod
    let didDecode: Bool

    var usedLossyUTF8Fallback: Bool { method == .lossyUTF8 }
}

/// Initial API seam for test-first extraction. Ownership/provenance/preparation
/// are intentionally incomplete until the following implementation commit.
struct TXTSourceSnapshot: Sendable {
    let bytes: Data

    init(copying data: Data) {
        bytes = data
    }

    static func read(at url: URL) throws -> Self {
        do {
            return Self(copying: try Data(contentsOf: url))
        } catch {
            throw ParseError.cannotRead(error.localizedDescription)
        }
    }

    var decoded: TXTDecodingResult {
        Self.decode(bytes)
    }

    static func decode(_ data: Data) -> TXTDecodingResult {
        TXTDecodingResult(text: TXTParser.decode(data), encoding: .utf8,
                          method: .utf8, didDecode: true)
    }

    func preparedText() throws -> String {
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.emptyContent }
        return text
    }
}
