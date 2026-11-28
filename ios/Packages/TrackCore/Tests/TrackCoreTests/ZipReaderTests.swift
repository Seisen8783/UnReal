import Compression
import Foundation
import XCTest
@testable import TrackCore

final class ZipReaderTests: XCTestCase {
    func testExtractsBundledKMZWithLocalizedEntry() throws {
        let url = try XCTUnwrap(TrackSource.bundledURL)
        let xml = try ZipReader.extractPrimaryKML(from: url)
        XCTAssertFalse(xml.isEmpty)
        let text = String(decoding: xml, as: UTF8.self)
        XCTAssertTrue(text.contains("<kml"))

        let route = try TrackRoute.load(url)
        XCTAssertNotNil(route.untimedSegments)
        XCTAssertEqual(route.points[0].latitude, 37.388089191992755, accuracy: 0.000001)
        XCTAssertEqual(route.points[0].longitude, 117.98433160802179, accuracy: 0.000001)
    }

    func testExtractsStoredAndDeflatedDocKML() throws {
        let kml = Data("""
            <kml xmlns="http://www.opengis.net/kml/2.2">
              <Placemark><LineString><coordinates>117.0,37.0 117.01,37.01</coordinates></LineString></Placemark>
            </kml>
            """.utf8)

        let storedZip = makeZip(entries: [
            (name: "other.kml", data: Data("<kml/>".utf8), method: 0, flags: 0),
            (name: "Doc.KML", data: kml, method: 0, flags: 0),
        ])
        XCTAssertEqual(try ZipReader.extractPrimaryKML(from: storedZip), kml)

        let deflatedZip = makeZip(entries: [
            (name: "track.kml", data: kml, method: 8, flags: 0),
        ])
        XCTAssertEqual(try ZipReader.extractPrimaryKML(from: deflatedZip), kml)
    }

    func testRejectsEncryptedOrOversizedOrCorruptZip() {
        let sample = Data("hello world hello world".utf8)
        let encrypted = makeZip(entries: [(name: "doc.kml", data: sample, method: 0, flags: 0x0001)])
        XCTAssertThrowsError(try ZipReader.extractPrimaryKML(from: encrypted))

        let deflated = makeZip(entries: [(name: "doc.kml", data: sample, method: 8, flags: 0)])
        XCTAssertThrowsError(try ZipReader.extractPrimaryKML(from: deflated, maxEntryBytes: 10))

        var corrupt = deflated
        corrupt[corrupt.count - 30] ^= 0xFF
        XCTAssertThrowsError(try ZipReader.extractPrimaryKML(from: corrupt))

        let ambiguous = makeZip(entries: [
            (name: "a.kml", data: sample, method: 0, flags: 0),
            (name: "b.kml", data: sample, method: 0, flags: 0),
        ])
        XCTAssertThrowsError(try ZipReader.extractPrimaryKML(from: ambiguous))
    }

    // MARK: - Minimal ZIP builder for tests

    private func makeZip(entries: [(name: String, data: Data, method: UInt16, flags: UInt16)]) -> Data {
        var archive = Data()
        var centralDirectory = Data()

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let payload: Data
            if entry.method == 8 {
                payload = deflate(entry.data)
            } else {
                payload = entry.data
            }

            let localOffset = UInt32(archive.count)
            archive.appendLE(UInt32(0x0403_4b50))
            archive.appendLE(UInt16(20))
            archive.appendLE(entry.flags)
            archive.appendLE(entry.method)
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(crc)
            archive.appendLE(UInt32(payload.count))
            archive.appendLE(UInt32(entry.data.count))
            archive.appendLE(UInt16(nameBytes.count))
            archive.appendLE(UInt16(0))
            archive.append(nameBytes)
            archive.append(payload)

            centralDirectory.appendLE(UInt32(0x0201_4b50))
            centralDirectory.appendLE(UInt16(20))
            centralDirectory.appendLE(UInt16(20))
            centralDirectory.appendLE(entry.flags)
            centralDirectory.appendLE(entry.method)
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(crc)
            centralDirectory.appendLE(UInt32(payload.count))
            centralDirectory.appendLE(UInt32(entry.data.count))
            centralDirectory.appendLE(UInt16(nameBytes.count))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt32(0))
            centralDirectory.appendLE(localOffset)
            centralDirectory.append(nameBytes)
        }

        let cdOffset = UInt32(archive.count)
        let cdSize = UInt32(centralDirectory.count)
        archive.append(centralDirectory)

        archive.appendLE(UInt32(0x0605_4b50))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(cdSize)
        archive.appendLE(cdOffset)
        archive.appendLE(UInt16(0))
        return archive
    }

    private func deflate(_ input: Data) -> Data {
        let cap = max(64, input.count * 2)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { buffer.deallocate() }
        let size = input.withUnsafeBytes { raw in
            compression_encode_buffer(buffer, cap,
                                      raw.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                      nil, COMPRESSION_ZLIB)
        }
        return Data(bytes: buffer, count: size)
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
