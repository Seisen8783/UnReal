import Compression
import Foundation

/// Minimal pure-Swift ZIP archive reader for KMZ extraction on macOS and iOS.
///
/// Supports stored (method 0) and raw-deflate (method 8) entries with streaming
/// size limits and CRC-32 verification so KMZ loading requires no external tools.
public enum ZipReader {
    struct Entry {
        let nameBytes: Data
        let flags: UInt16
        let compressionMethod: UInt16
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32

        var decodedName: String {
            String(decoding: nameBytes, as: UTF8.self)
        }

        var isEncrypted: Bool {
            (flags & 0x0001) != 0
        }

        func hasASCIISuffix(_ suffix: String) -> Bool {
            let suffixBytes = Array(suffix.utf8)
            guard nameBytes.count >= suffixBytes.count else { return false }
            let tail = nameBytes.suffix(suffixBytes.count)
            return zip(tail, suffixBytes).allSatisfy { lhs, rhs in
                asciiLowercase(lhs) == asciiLowercase(rhs)
            }
        }

        func equalsASCII(_ target: String) -> Bool {
            let targetBytes = Array(target.utf8)
            guard nameBytes.count == targetBytes.count else { return false }
            return zip(nameBytes, targetBytes).allSatisfy { lhs, rhs in
                asciiLowercase(lhs) == asciiLowercase(rhs)
            }
        }
    }

    private static let eocdSignature: UInt32 = 0x0605_4b50
    private static let cdSignature: UInt32 = 0x0201_4b50
    private static let localSignature: UInt32 = 0x0403_4b50

    /// Extracts the primary KML XML payload from a KMZ archive on disk.
    public static func extractPrimaryKML(from url: URL, maxArchiveBytes: Int = 10 * 1024 * 1024,
                                         maxEntryBytes: Int = 20 * 1024 * 1024) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let archive = try handle.read(upToCount: maxArchiveBytes + 1) ?? Data()
        guard archive.count <= maxArchiveBytes else {
            throw TrackError("轨迹文件超过大小上限。")
        }
        return try extractPrimaryKML(from: archive, maxEntryBytes: maxEntryBytes)
    }

    /// Extracts the primary KML XML payload from raw KMZ archive bytes.
    public static func extractPrimaryKML(from archive: Data,
                                         maxEntryBytes: Int = 20 * 1024 * 1024) throws -> Data {
        let entries = try parseCentralDirectory(archive)
        let kmlEntries = entries.filter { $0.hasASCIISuffix(".kml") }
        let docEntries = kmlEntries.filter { $0.equalsASCII("doc.kml") }
        let selected: Entry
        if docEntries.count == 1 {
            selected = docEntries[0]
        } else if kmlEntries.count == 1 {
            selected = kmlEntries[0]
        } else {
            throw TrackError("KMZ 应包含一个 doc.kml 或唯一的 KML 文件。")
        }
        return try extractEntry(selected, from: archive, limit: maxEntryBytes)
    }

    private static func parseCentralDirectory(_ archive: Data) throws -> [Entry] {
        guard archive.count >= 22 else {
            throw TrackError("KMZ 损坏、已加密或无法解压。")
        }
        let searchStart = max(0, archive.count - 22 - 65_535)
        var eocdOffset: Int?
        var cursor = archive.count - 22
        while cursor >= searchStart {
            if readUInt32(archive, at: cursor) == eocdSignature {
                let commentLength = Int(readUInt16(archive, at: cursor + 20))
                if cursor + 22 + commentLength == archive.count {
                    eocdOffset = cursor
                    break
                }
            }
            cursor -= 1
        }
        guard let eocd = eocdOffset else {
            throw TrackError("KMZ 损坏、已加密或无法解压。")
        }

        let diskNumber = readUInt16(archive, at: eocd + 4)
        let cdDisk = readUInt16(archive, at: eocd + 6)
        let diskEntries = readUInt16(archive, at: eocd + 8)
        let totalEntries = readUInt16(archive, at: eocd + 10)
        let cdSize = readUInt32(archive, at: eocd + 12)
        let cdOffset = readUInt32(archive, at: eocd + 16)

        guard diskNumber == 0, cdDisk == 0, diskEntries == totalEntries,
              totalEntries != 0xFFFF, cdSize != 0xFFFF_FFFF, cdOffset != 0xFFFF_FFFF else {
            throw TrackError("KMZ 损坏、已加密或无法解压。")
        }

        let start = Int(cdOffset)
        let end = start + Int(cdSize)
        guard start >= 0, end <= eocd else {
            throw TrackError("KMZ 损坏、已加密或无法解压。")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(totalEntries))
        var offset = start
        for _ in 0..<Int(totalEntries) {
            guard offset + 46 <= end, readUInt32(archive, at: offset) == cdSignature else {
                throw TrackError("KMZ 损坏、已加密或无法解压。")
            }
            let flags = readUInt16(archive, at: offset + 8)
            let method = readUInt16(archive, at: offset + 10)
            let crc = readUInt32(archive, at: offset + 16)
            let compressedSize = readUInt32(archive, at: offset + 20)
            let uncompressedSize = readUInt32(archive, at: offset + 24)
            let nameLength = Int(readUInt16(archive, at: offset + 28))
            let extraLength = Int(readUInt16(archive, at: offset + 30))
            let commentLength = Int(readUInt16(archive, at: offset + 32))
            let localOffset = readUInt32(archive, at: offset + 42)
            let nameStart = offset + 46
            let nextOffset = nameStart + nameLength + extraLength + commentLength
            guard nextOffset <= end else {
                throw TrackError("KMZ 损坏、已加密或无法解压。")
            }
            let nameBytes = archive.subdata(in: nameStart..<(nameStart + nameLength))
            entries.append(Entry(nameBytes: nameBytes, flags: flags, compressionMethod: method,
                                 crc32: crc, compressedSize: compressedSize,
                                 uncompressedSize: uncompressedSize, localHeaderOffset: localOffset))
            offset = nextOffset
        }
        return entries
    }

    private static func extractEntry(_ entry: Entry, from archive: Data, limit: Int) throws -> Data {
        guard !entry.isEncrypted else {
            throw TrackError("KMZ 损坏、已加密或无法解压。")
        }
        guard entry.uncompressedSize != 0xFFFF_FFFF, entry.compressedSize != 0xFFFF_FFFF else {
            throw TrackError("KMZ 损坏、已加密或无法解压。")
        }
        guard Int(entry.uncompressedSize) <= limit else {
            throw TrackError("KMZ 内容超过大小上限。")
        }

        let localOffset = Int(entry.localHeaderOffset)
        guard localOffset + 30 <= archive.count,
              readUInt32(archive, at: localOffset) == localSignature else {
            throw TrackError("KMZ 损坏、已加密或无法解压。")
        }
        let localFlags = readUInt16(archive, at: localOffset + 6)
        guard (localFlags & 0x0001) == 0 else {
            throw TrackError("KMZ 损坏、已加密或无法解压。")
        }
        let localNameLen = Int(readUInt16(archive, at: localOffset + 26))
        let localExtraLen = Int(readUInt16(archive, at: localOffset + 28))
        let payloadStart = localOffset + 30 + localNameLen + localExtraLen
        let payloadEnd = payloadStart + Int(entry.compressedSize)
        guard payloadStart >= 0, payloadEnd <= archive.count else {
            throw TrackError("KMZ 损坏、已加密或无法解压。")
        }

        let payload = archive.subdata(in: payloadStart..<payloadEnd)
        let output: Data
        switch entry.compressionMethod {
        case 0:
            guard payload.count <= limit else {
                throw TrackError("KMZ 内容超过大小上限。")
            }
            output = payload
        case 8:
            output = try inflateRawDeflate(payload, expectedSize: Int(entry.uncompressedSize), limit: limit)
        default:
            throw TrackError("KMZ 损坏、已加密或无法解压。")
        }

        guard output.count == Int(entry.uncompressedSize), crc32(output) == entry.crc32 else {
            throw TrackError("KMZ 损坏、已加密或无法解压。")
        }
        return output
    }

    private static func inflateRawDeflate(_ compressed: Data, expectedSize: Int, limit: Int) throws -> Data {
        if compressed.isEmpty && expectedSize == 0 {
            return Data()
        }
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>.allocate(capacity: 1),
                                        dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
                                        src_size: 0,
                                        state: nil)
        let dummyDst = stream.dst_ptr
        defer { dummyDst.deallocate() }

        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw TrackError("KMZ 损坏、已加密或无法解压。")
        }
        defer { compression_stream_destroy(&stream) }

        let chunkSize = 65_536
        var output = Data()
        output.reserveCapacity(min(expectedSize, limit))
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { scratch.deallocate() }

        try compressed.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw TrackError("KMZ 损坏、已加密或无法解压。")
            }
            stream.src_ptr = base
            stream.src_size = compressed.count

            while true {
                stream.dst_ptr = scratch
                stream.dst_size = chunkSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - stream.dst_size
                if produced > 0 {
                    guard output.count + produced <= limit else {
                        throw TrackError("KMZ 内容超过大小上限。")
                    }
                    output.append(scratch, count: produced)
                }
                if status == COMPRESSION_STATUS_END {
                    break
                }
                if status == COMPRESSION_STATUS_ERROR {
                    throw TrackError("KMZ 损坏、已加密或无法解压。")
                }
                if produced == 0 && stream.src_size == 0 {
                    throw TrackError("KMZ 损坏、已加密或无法解压。")
                }
            }
        }
        return output
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func asciiLowercase(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
