//
//  EPUBParser.swift
//  Seidoku
//
//  EPUB 解析：zip 解压 → 定位 OPF → 提取元数据（书名/作者）+ 章节数。
//  zip 解压用系统 libz（raw deflate），零第三方依赖。
//

import Foundation
import zlib

// MARK: - Zip 解压

enum ZipError: LocalizedError {
    case invalidArchive
    case decompressionFailed

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "EPUB 文件损坏（zip 结构无效）"
        case .decompressionFailed: return "EPUB 解压失败"
        }
    }
}

enum ZipExtractor {
    static func extract(_ archive: Data) throws -> [String: Data] {
        let bytes = [UInt8](archive)
        guard let eocd = findEndOfCentralDirectory(bytes) else {
            throw ZipError.invalidArchive
        }

        var result: [String: Data] = [:]
        var offset = eocd.centralDirectoryOffset
        for _ in 0..<eocd.entryCount {
            guard let entry = parseCentralEntry(bytes, at: offset) else {
                throw ZipError.invalidArchive
            }
            if let data = extractEntry(bytes, localHeaderOffset: entry.localHeaderOffset) {
                result[entry.name] = data
            }
            offset = entry.nextEntryOffset
        }
        return result
    }

    private struct EOCD {
        let entryCount: Int
        let centralDirectoryOffset: Int
    }

    private struct CentralEntry {
        let name: String
        let localHeaderOffset: Int
        let nextEntryOffset: Int
    }

    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) -> EOCD? {
        let sig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let minSize = 22
        guard bytes.count >= minSize else { return nil }
        // 从末尾往前找（EOCD 后面可能有 comment）
        let searchStart = max(0, bytes.count - 65536)
        var index = bytes.count - minSize
        while index >= searchStart {
            if bytes[index] == sig[0], bytes[index + 1] == sig[1],
               bytes[index + 2] == sig[2], bytes[index + 3] == sig[3] {
                let entryCount = Int(readUInt16(bytes, index + 10))
                let cdOffset = Int(readUInt32(bytes, index + 16))
                return EOCD(entryCount: entryCount, centralDirectoryOffset: cdOffset)
            }
            index -= 1
        }
        return nil
    }

    private static func parseCentralEntry(_ bytes: [UInt8], at offset: Int) -> CentralEntry? {
        let sig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        guard offset + 46 <= bytes.count,
              bytes[offset] == sig[0], bytes[offset + 1] == sig[1],
              bytes[offset + 2] == sig[2], bytes[offset + 3] == sig[3] else {
            return nil
        }
        let nameLength = Int(readUInt16(bytes, offset + 28))
        let extraLength = Int(readUInt16(bytes, offset + 30))
        let commentLength = Int(readUInt16(bytes, offset + 32))
        let localHeaderOffset = Int(readUInt32(bytes, offset + 42))

        let nameStart = offset + 46
        guard nameStart + nameLength <= bytes.count else { return nil }
        let name = String(bytes: bytes[nameStart..<(nameStart + nameLength)], encoding: .utf8) ?? ""

        let nextEntryOffset = nameStart + nameLength + extraLength + commentLength
        return CentralEntry(name: name, localHeaderOffset: localHeaderOffset, nextEntryOffset: nextEntryOffset)
    }

    private static func extractEntry(_ bytes: [UInt8], localHeaderOffset: Int) -> Data? {
        let sig: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        guard localHeaderOffset + 30 <= bytes.count,
              bytes[localHeaderOffset] == sig[0], bytes[localHeaderOffset + 1] == sig[1],
              bytes[localHeaderOffset + 2] == sig[2], bytes[localHeaderOffset + 3] == sig[3] else {
            return nil
        }
        let compressionMethod = readUInt16(bytes, localHeaderOffset + 8)
        let compressedSize = Int(readUInt32(bytes, localHeaderOffset + 18))
        let uncompressedSize = Int(readUInt32(bytes, localHeaderOffset + 22))
        let nameLength = Int(readUInt16(bytes, localHeaderOffset + 26))
        let extraLength = Int(readUInt16(bytes, localHeaderOffset + 28))

        let dataOffset = localHeaderOffset + 30 + nameLength + extraLength
        guard dataOffset + compressedSize <= bytes.count else { return nil }
        let raw = Array(bytes[dataOffset..<(dataOffset + compressedSize)])

        switch compressionMethod {
        case 0: // stored
            return Data(raw)
        case 8: // deflate
            return inflateRawDeflate(raw, expectedSize: uncompressedSize)
        default:
            return nil
        }
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    /// raw deflate 解压（windowBits = -15）。
    private static func inflateRawDeflate(_ input: [UInt8], expectedSize: Int) -> Data? {
        var stream = z_stream()
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil
        stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input)
        stream.avail_in = uInt(input.count)

        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }

        var output = [UInt8](repeating: 0, count: max(expectedSize, 1))
        output.withUnsafeMutableBufferPointer { buffer in
            stream.next_out = buffer.baseAddress
            stream.avail_out = uInt(buffer.count)
        }
        let status = inflate(&stream, Z_FINISH)
        guard status == Z_STREAM_END || status == Z_OK else { return nil }
        return Data(output.prefix(Int(stream.total_out)))
    }
}

// MARK: - EPUB 解析

struct EPUBParser {
    func parse(url: URL) throws -> ParsedBook {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ParseError.cannotRead(error.localizedDescription)
        }

        let files = try ZipExtractor.extract(data)

        // 1. 定位 OPF（container.xml）
        guard let containerData = files["META-INF/container.xml"],
              let opfPath = parseContainer(containerData),
              let opfData = files[opfPath] else {
            throw ZipError.invalidArchive
        }

        // 2. 解析 OPF 元数据
        let opfString = String(data: opfData, encoding: .utf8) ?? ""
        let title = extractTag(opfString, tag: "title") ?? url.deletingPathExtension().lastPathComponent
        let author = extractTag(opfString, tag: "creator")

        // 3. 章节数（spine itemref 数量）
        let chapterCount = countSpineItems(opfString)

        return ParsedBook(title: title, author: author, chapterCount: chapterCount, content: "")
    }

    /// 从 container.xml 提取第一个 rootfile 的 full-path。
    private func parseContainer(_ data: Data) -> String? {
        let xml = String(data: data, encoding: .utf8) ?? ""
        guard let range = xml.range(of: #"full-path\s*=\s*"([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let match = xml[range]
        let parts = match.split(separator: "\"")
        return parts.count >= 2 ? String(parts[1]) : nil
    }

    /// 提取 <dc:title> / <dc:creator> 等标签内容。
    private func extractTag(_ xml: String, tag: String) -> String? {
        let pattern = "<[^>]*dc:" + tag + "[^>]*>(.*?)</[^>]*dc:" + tag + ">"
        guard let range = xml.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let text = xml[range]
        // 去掉标签本身，只留内容
        let content = text
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    /// 统计 spine 里的 itemref 数量（章节数）。
    private func countSpineItems(_ xml: String) -> Int {
        let matches = xml.ranges(of: #"<itemref\b"#, options: [.regularExpression, .caseInsensitive])
        return matches.count
    }
}

extension String {
    func ranges(of pattern: String, options: NSRegularExpression.Options) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = self as NSString
        return regex.matches(in: self, range: NSRange(location: 0, length: ns.length)).compactMap {
            Range($0.range, in: self)
        }
    }
}
