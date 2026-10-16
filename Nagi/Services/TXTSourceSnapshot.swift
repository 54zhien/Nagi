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
    /// True for empty input or a successful failable decoder. False for a failed
    /// authoritative BOM or explicit replacement fallback; not a losslessness certificate.
    let didDecode: Bool

    var usedLossyUTF8Fallback: Bool { method == .lossyUTF8 }
}

/// Owned captured bytes, independent of a URL or externally mutable Data storage.
/// No atomic-file-read promise: decoding (and future digests) use this captured image.
struct TXTSourceSnapshot: Sendable {
    let bytes: Data

    init(copying data: Data) {
        bytes = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Data in
            guard let address = buffer.baseAddress else { return Data() }
            return Data(bytes: address, count: buffer.count)
        }
    }

    static func read(at url: URL) throws -> Self {
        do {
            // A mapping is allowed only while capturing. The snapshot never retains it.
            return Self(copying: try Data(contentsOf: url, options: [.mappedIfSafe]))
        } catch {
            throw ParseError.cannotRead(error.localizedDescription)
        }
    }

    var decoded: TXTDecodingResult {
        Self.decode(bytes)
    }

    static func decode(_ data: Data) -> TXTDecodingResult {
        guard !data.isEmpty else {
            return TXTDecodingResult(text: "", encoding: nil, method: .empty, didDecode: true)
        }

        // Keep legacy precedence and failed-BOM behavior. Report the chosen path,
        // not every candidate attempted, and never infer lossiness from U+FFFD text.
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return strictDecode(Data(data.dropFirst(3)), encoding: .utf8,
                                selected: .utf8, method: .byteOrderMark)
        }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return strictDecode(Data(data.dropFirst(4)), encoding: .utf32LittleEndian,
                                selected: .utf32LittleEndian, method: .byteOrderMark)
        }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return strictDecode(Data(data.dropFirst(4)), encoding: .utf32BigEndian,
                                selected: .utf32BigEndian, method: .byteOrderMark)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return strictDecode(Data(data.dropFirst(2)), encoding: .utf16LittleEndian,
                                selected: .utf16LittleEndian, method: .byteOrderMark)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return strictDecode(Data(data.dropFirst(2)), encoding: .utf16BigEndian,
                                selected: .utf16BigEndian, method: .byteOrderMark)
        }

        if let choice = detectUTF32Encoding(data),
           let text = String(data: data, encoding: choice.encoding) {
            return TXTDecodingResult(text: text, encoding: choice.selected,
                                     method: .nulHeuristic, didDecode: true)
        }
        if let choice = detectUTF16Encoding(data),
           let text = String(data: data, encoding: choice.encoding) {
            return TXTDecodingResult(text: text, encoding: choice.selected,
                                     method: .nulHeuristic, didDecode: true)
        }
        if let text = String(data: data, encoding: .utf8) {
            return TXTDecodingResult(text: text, encoding: .utf8, method: .utf8, didDecode: true)
        }
        let gbEncoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let text = String(data: data, encoding: String.Encoding(rawValue: gbEncoding)) {
            return TXTDecodingResult(text: text, encoding: .gb18030,
                                     method: .gb18030, didDecode: true)
        }
        return TXTDecodingResult(text: String(decoding: data, as: UTF8.self), encoding: .utf8,
                                 method: .lossyUTF8, didDecode: false)
    }

    func preparedText() throws -> String {
        let text = Self.normalizeLineEndings(
            decoded.text.replacingOccurrences(of: "\u{FEFF}", with: "")
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.emptyContent }
        return text
    }

    static func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{0085}", with: "\n")
    }

    private static func strictDecode(
        _ data: Data,
        encoding: String.Encoding,
        selected: TXTTextEncoding,
        method: TXTDecodingMethod
    ) -> TXTDecodingResult {
        let text = String(data: data, encoding: encoding)
        return TXTDecodingResult(text: text ?? "", encoding: selected,
                                 method: method, didDecode: text != nil)
    }

    private static func detectUTF16Encoding(
        _ data: Data
    ) -> (encoding: String.Encoding, selected: TXTTextEncoding)? {
        let sample = Array(data.prefix(4096))
        guard sample.count >= 8 else { return nil }

        let evenCount = max(sample.count / 2, 1)
        let evenZeros = stride(from: 0, to: sample.count, by: 2)
            .reduce(into: 0) { count, index in count += sample[index] == 0 ? 1 : 0 }
        let oddZeros = stride(from: 1, to: sample.count, by: 2)
            .reduce(into: 0) { count, index in count += sample[index] == 0 ? 1 : 0 }

        if oddZeros * 3 >= evenCount * 2, evenZeros * 10 < evenCount {
            return (.utf16LittleEndian, .utf16LittleEndian)
        }
        if evenZeros * 3 >= evenCount * 2, oddZeros * 10 < evenCount {
            return (.utf16BigEndian, .utf16BigEndian)
        }
        return nil
    }

    private static func detectUTF32Encoding(
        _ data: Data
    ) -> (encoding: String.Encoding, selected: TXTTextEncoding)? {
        let sample = Array(data.prefix(4096))
        guard sample.count >= 16 else { return nil }

        let quartetCount = max(sample.count / 4, 1)
        let zeroCounts = (0..<4).map { offset in
            stride(from: offset, to: sample.count, by: 4)
                .reduce(into: 0) { count, index in count += sample[index] == 0 ? 1 : 0 }
        }
        // Preserve the legacy high-byte-pair heuristic for Chinese UTF32 text.
        let littleEndianHighByteZeros = zeroCounts[2] + zeroCounts[3]
        if littleEndianHighByteZeros * 2 >= quartetCount * 3,
           zeroCounts[0] + zeroCounts[1] < quartetCount * 3 {
            return (.utf32LittleEndian, .utf32LittleEndian)
        }

        let bigEndianHighByteZeros = zeroCounts[0] + zeroCounts[1]
        if bigEndianHighByteZeros * 2 >= quartetCount * 3,
           zeroCounts[2] + zeroCounts[3] < quartetCount * 3 {
            return (.utf32BigEndian, .utf32BigEndian)
        }
        return nil
    }
}
