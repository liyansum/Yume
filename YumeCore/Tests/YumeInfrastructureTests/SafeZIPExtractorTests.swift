import Foundation
import XCTest
@testable import YumeInfrastructure

final class SafeZIPExtractorTests: XCTestCase {
    func testInspectAndExtractStoredAndDeflatedEntries() throws {
        let fixture = try ZIPFixture()
        defer { fixture.remove() }
        let archive = ZIPBuilder.make([
            .directory("game/"),
            .stored("game/readme.txt", data: Data("hello".utf8), crc32: 0x3610a686),
            .deflated(
                "game/index.html",
                compressed: Data(hex: "b3514cc94f2ea92c4855c828c9cdb14bcbac28292d4a0500"),
                uncompressedSize: 22,
                crc32: 0x7ede44ee
            )
        ])
        try archive.write(to: fixture.archiveURL)
        let extractor = SafeZIPExtractor()

        let inspection = try extractor.inspect(fixture.archiveURL)
        let extracted = try extractor.extract(fixture.archiveURL, to: fixture.destinationURL)

        XCTAssertEqual(inspection.entryCount, 3)
        XCTAssertEqual(inspection.fileCount, 2)
        XCTAssertEqual(inspection.uncompressedByteCount, 27)
        XCTAssertEqual(extracted, inspection)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destinationURL.appendingPathComponent("game/readme.txt")),
            Data("hello".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.destinationURL.appendingPathComponent("game/index.html")),
            Data("<!doctype html>fixture".utf8)
        )
    }

    func testTraversalAndCaseCollisionAreRejectedBeforeWriting() throws {
        let fixture = try ZIPFixture()
        defer { fixture.remove() }
        try ZIPBuilder.make([
            .stored("../escape", data: Data("hello".utf8), crc32: 0x3610a686)
        ]).write(to: fixture.archiveURL)
        XCTAssertThrowsError(try SafeZIPExtractor().inspect(fixture.archiveURL)) { error in
            XCTAssertEqual(error as? SafeZIPError, .unsafePath)
        }

        try ZIPBuilder.make([
            .stored("Data/File.txt", data: Data("hello".utf8), crc32: 0x3610a686),
            .stored("data/file.TXT", data: Data("hello".utf8), crc32: 0x3610a686)
        ]).write(to: fixture.archiveURL)
        XCTAssertThrowsError(try SafeZIPExtractor().inspect(fixture.archiveURL)) { error in
            XCTAssertEqual(error as? SafeZIPError, .duplicatePath)
        }
    }

    func testEncryptedEntryRequiresPasswordAndSymbolicLinkEntriesFailClosed() throws {
        let fixture = try ZIPFixture()
        defer { fixture.remove() }
        try ZIPBuilder.make([
            .stored("secret.txt", data: Data("hello".utf8), crc32: 0x3610a686, flags: 1)
        ]).write(to: fixture.archiveURL)

        let encryptedInspection = try SafeZIPExtractor().inspect(fixture.archiveURL)
        XCTAssertTrue(encryptedInspection.containsEncryptedEntries)
        XCTAssertThrowsError(
            try SafeZIPExtractor().extract(fixture.archiveURL, to: fixture.destinationURL)
        ) { error in
            XCTAssertEqual(error as? SafeZIPError, .passwordRequired)
        }

        try ZIPBuilder.make([
            .stored(
                "link",
                data: Data("hello".utf8),
                crc32: 0x3610a686,
                externalAttributes: 0xa1ff0000
            )
        ]).write(to: fixture.archiveURL)
        XCTAssertThrowsError(try SafeZIPExtractor().inspect(fixture.archiveURL)) { error in
            XCTAssertEqual(error as? SafeZIPError, .symbolicLinkEntry)
        }
    }

    func testTraditionalEncryptedZIPRejectsWrongPasswordAndExtractsWithCorrectPassword() throws {
        let fixture = try ZIPFixture()
        defer { fixture.remove() }
        try Data(base64Encoded: Self.pkCryptFixture)!.write(to: fixture.archiveURL)

        XCTAssertThrowsError(
            try SafeZIPExtractor().extract(
                fixture.archiveURL,
                to: fixture.destinationURL,
                password: "wrong"
            )
        ) { error in
            XCTAssertEqual(error as? SafeZIPError, .incorrectPasswordOrCorruptArchive)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationURL.path))

        let result = try SafeZIPExtractor().extract(
            fixture.archiveURL,
            to: fixture.destinationURL,
            password: "yume-test"
        )
        XCTAssertTrue(result.containsEncryptedEntries)
        XCTAssertEqual(
            try String(
                contentsOf: fixture.destinationURL.appendingPathComponent("index.html"),
                encoding: .utf8
            ),
            "<!doctype html>encrypted fixture\n"
        )
    }

    func testWinZipAES256RejectsWrongPasswordAndExtractsWithCorrectPassword() throws {
        let fixture = try ZIPFixture()
        defer { fixture.remove() }
        try Data(base64Encoded: Self.aes256Fixture)!.write(to: fixture.archiveURL)

        let inspection = try SafeZIPExtractor().inspect(fixture.archiveURL)
        XCTAssertTrue(inspection.containsEncryptedEntries)
        XCTAssertThrowsError(
            try SafeZIPExtractor().extract(
                fixture.archiveURL,
                to: fixture.destinationURL,
                password: "wrong"
            )
        ) { error in
            XCTAssertEqual(error as? SafeZIPError, .incorrectPasswordOrCorruptArchive)
        }

        let result = try SafeZIPExtractor().extract(
            fixture.archiveURL,
            to: fixture.destinationURL,
            password: "yume-test"
        )
        XCTAssertTrue(result.containsEncryptedEntries)
        XCTAssertEqual(
            try String(
                contentsOf: fixture.destinationURL.appendingPathComponent("game/index.html"),
                encoding: .utf8
            ),
            "<!doctype html>encrypted fixture"
        )
    }

    func testCRCMismatchRemovesPartialDestination() throws {
        let fixture = try ZIPFixture()
        defer { fixture.remove() }
        try ZIPBuilder.make([
            .stored("file.txt", data: Data("hello".utf8), crc32: 0)
        ]).write(to: fixture.archiveURL)

        XCTAssertThrowsError(
            try SafeZIPExtractor().extract(fixture.archiveURL, to: fixture.destinationURL)
        ) { error in
            guard case .extractionFailed = error as? SafeZIPError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationURL.path))
    }

    private static let pkCryptFixture =
        "UEsDBAoACQAAACK3G12FjbAOLQAAACEAAAAKABwAaW5kZXguaHRtbFVUCQADP1CQakNQkGp1eAsAAQQAAAAABAAAAAD3OAIkD3Skz4H58akrxb/GuMM9Ow0LkLO1yZOu8FJw6B+LZNuOPFQT6ILQpbBQSwcIhY2wDi0AAAAhAAAAUEsBAh4DCgAJAAAAIrcbXYWNsA4tAAAAIQAAAAoAGAAAAAAAAQAAAICBAAAAAGluZGV4Lmh0bWxVVAUAAz9QkGp1eAsAAQQAAAAABAAAAABQSwUGAAAAAAEAAQBQAAAAgQAAAAAA"

    private static let aes256Fixture =
        "UEsDBDMACQhjAAAAAAAAAAAAAAAAACAAAAAPAAsAZ2FtZS9pbmRleC5odG1sAZkHAAEAQUUDCACbg9+19B3+0GTzXDCX1vuH5ie5LZdS6BWQa+oWecBlsa7f0jBigAgGKENUCxzw2L83v5JlX3+0+y8labkcb1BLBwgkx29kPgAAACAAAABQSwECLQMzAAkIYwAAAAAAJMdvZD4AAAAgAAAADwALAAAAAAAAAAAAAAAAAAAAZ2FtZS9pbmRleC5odG1sAZkHAAEAQUUDCABQSwUGAAAAAAEAAQBIAAAAhgAAAAAA"
}

private struct ZIPFixture {
    let root: URL
    let archiveURL: URL
    let destinationURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "yume-zip-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        archiveURL = root.appendingPathComponent("fixture.zip")
        destinationURL = root.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum ZIPBuilder {
    struct Entry {
        let name: String
        let method: UInt16
        let flags: UInt16
        let crc32: UInt32
        let compressed: Data
        let uncompressedSize: UInt32
        let externalAttributes: UInt32

        static func directory(_ name: String) -> Entry {
            Entry(
                name: name,
                method: 0,
                flags: 0,
                crc32: 0,
                compressed: Data(),
                uncompressedSize: 0,
                externalAttributes: 0x41ed0010
            )
        }

        static func stored(
            _ name: String,
            data: Data,
            crc32: UInt32,
            flags: UInt16 = 0,
            externalAttributes: UInt32 = 0x81a40000
        ) -> Entry {
            Entry(
                name: name,
                method: 0,
                flags: flags,
                crc32: crc32,
                compressed: data,
                uncompressedSize: UInt32(data.count),
                externalAttributes: externalAttributes
            )
        }

        static func deflated(
            _ name: String,
            compressed: Data,
            uncompressedSize: UInt32,
            crc32: UInt32
        ) -> Entry {
            Entry(
                name: name,
                method: 8,
                flags: 0,
                crc32: crc32,
                compressed: compressed,
                uncompressedSize: uncompressedSize,
                externalAttributes: 0x81a40000
            )
        }
    }

    static func make(_ entries: [Entry]) -> Data {
        var archive = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let localOffset = UInt32(archive.count)
            archive.appendLE(UInt32(0x04034b50))
            archive.appendLE(UInt16(20))
            archive.appendLE(entry.flags)
            archive.appendLE(entry.method)
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(entry.crc32)
            archive.appendLE(UInt32(entry.compressed.count))
            archive.appendLE(entry.uncompressedSize)
            archive.appendLE(UInt16(name.count))
            archive.appendLE(UInt16(0))
            archive.append(name)
            archive.append(entry.compressed)

            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(0x0314))
            central.appendLE(UInt16(20))
            central.appendLE(entry.flags)
            central.appendLE(entry.method)
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(entry.crc32)
            central.appendLE(UInt32(entry.compressed.count))
            central.appendLE(entry.uncompressedSize)
            central.appendLE(UInt16(name.count))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(entry.externalAttributes)
            central.appendLE(localOffset)
            central.append(name)
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.appendLE(UInt32(0x06054b50))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt32(central.count))
        archive.appendLE(centralOffset)
        archive.appendLE(UInt16(0))
        return archive
    }
}

private extension Data {
    init(hex: String) {
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
