import Foundation
import XCTest
import YumeDomain
@testable import YumeInfrastructure

final class KirikiriXP3ArchiveTests: XCTestCase {
    func testIndexesAndExtractsUnprotectedEntry() throws {
        let fixture = try XP3Fixture()
        defer { fixture.remove() }
        let payload = Data("self-authored fixture payload".utf8)
        try fixture.write { builder in
            builder.add(name: "data/scripts/main.tjs", payload: payload)
        }

        let archive = KirikiriXP3Archive()
        let entries = try archive.index(at: fixture.archiveURL)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].relativePath.rawValue, "data/scripts/main.tjs")
        XCTAssertEqual(entries[0].uncompressedSize, UInt64(payload.count))
        XCTAssertFalse(entries[0].isProtected)

        let destination = fixture.destination(named: "main.tjs")
        try archive.extract(entries[0], from: fixture.archiveURL, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    func testRejectsBadMagicAndTruncatedTOC() throws {
        let fixture = try XP3Fixture()
        defer { fixture.remove() }
        try fixture.write(magicVariant: [0x00, 0x01]) { _ in }

        XCTAssertThrowsError(try KirikiriXP3Archive().index(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? XP3Error, .magicMismatch)
        }

        try fixture.write(
            magicVariant: XP3Fixture.classicVariant,
            fakeTOCOffset: 4_000_000
        ) { _ in }
        XCTAssertThrowsError(try KirikiriXP3Archive().index(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? XP3Error, .truncatedTOC)
        }
    }

    func testRejectsUnsupportedHeaderVariant() throws {
        let fixture = try XP3Fixture()
        defer { fixture.remove() }
        try fixture.write(magicVariant: [0x11, 0x22]) { _ in }

        XCTAssertThrowsError(try KirikiriXP3Archive().index(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? XP3Error, .unsupportedHeaderVariant)
        }
    }

    func testProtectedEntryIndexesButRefusesExtraction() throws {
        let fixture = try XP3Fixture()
        defer { fixture.remove() }
        try fixture.write { builder in
            builder.add(name: "locked.dat", payload: Data("x".utf8), protectFlag: 1)
        }

        let entries = try KirikiriXP3Archive().index(at: fixture.archiveURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isProtected)

        XCTAssertThrowsError(
            try KirikiriXP3Archive().extract(
                entries[0],
                from: fixture.archiveURL,
                to: fixture.destination(named: "locked-copy.dat")
            )
        ) { error in
            XCTAssertEqual(error as? XP3Error, .protectedEntryUnsupported)
        }
    }

    func testCaseFoldedDuplicatePathsAreRejected() throws {
        let fixture = try XP3Fixture()
        defer { fixture.remove() }
        try fixture.write { builder in
            builder.add(name: "Same.txt", payload: Data("a".utf8))
            builder.add(name: "same.TXT", payload: Data("b".utf8))
        }

        XCTAssertThrowsError(try KirikiriXP3Archive().index(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? XP3Error, .duplicatePath)
        }
    }

    func testUnsafePathIsRejected() throws {
        let fixture = try XP3Fixture()
        defer { fixture.remove() }
        try fixture.write { builder in
            builder.add(name: "../escape.bin", payload: Data("e".utf8))
        }

        XCTAssertThrowsError(try KirikiriXP3Archive().index(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? XP3Error, .unsafePath)
        }
    }
}

extension KirikiriXP3ArchiveTests: @unchecked Sendable {}

private struct XP3Fixture {
    static let classicVariant: [UInt8] = [0x8D, 0xEA]

    let root: URL
    let archiveURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "yume-xp3-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        archiveURL = root.appendingPathComponent("fixture.xp3")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func destination(named name: String) -> URL {
        root.appendingPathComponent(name)
    }

    func write(
        magicVariant: [UInt8] = classicVariant,
        fakeTOCOffset: UInt64? = nil,
        configure: (inout XP3TOCBuilder) -> Void
    ) throws {
        var builder = XP3TOCBuilder()
        configure(&builder)

        var data = Data(Array("XP3\r\n \n\x1A".utf8))
        data.append(contentsOf: magicVariant)
        let tocOffset = fakeTOCOffset ?? UInt64(data.count + magicVariant.count + 8)
        var offsetBytes = tocOffset
        withUnsafeBytes(of: &offsetBytes) { data.append(contentsOf: $0) }
        data.append(builder.build(blobStartOffset: Int(tocOffset)))
        try data.write(to: archiveURL)
    }
}

private struct XP3TOCBuilder {
    private struct BuiltEntry {
        let name: String
        let payload: Data
        let protectFlag: UInt32
    }

    private var entries: [BuiltEntry] = []

    mutating func add(name: String, payload: Data, protectFlag: UInt32 = 0) {
        entries.append(BuiltEntry(name: name, payload: payload, protectFlag: protectFlag))
    }

    func build(blobStartOffset: Int) -> Data {
        var table = Data()
        var blobCursor = 0

        for entry in entries {
            var infoPayload = Data()
            appendLE(&infoPayload, value: entry.protectFlag, byteCount: 4)
            appendLE(&infoPayload, value: 0, byteCount: 8)
            var nameData = Data()
            for scalar in Array(entry.name.utf16) {
                appendLE(&nameData, value: scalar, byteCount: 2)
            }
            appendLE(&infoPayload, value: nameData.count, byteCount: 2)
            infoPayload.append(nameData)
            table.append(record(tag: "info", payload: infoPayload))

            var filePayload = Data()
            appendLE(&filePayload, value: 0, byteCount: 4)
            appendLE(&filePayload, value: UInt64(blobStartOffset + blobCursor), byteCount: 8)
            appendLE(&filePayload, value: UInt64(entry.payload.count), byteCount: 8)
            appendLE(&filePayload, value: UInt64(entry.payload.count), byteCount: 8)
            table.append(record(tag: "file", payload: filePayload))

            blobCursor += entry.payload.count
        }

        return zlibWrap(raw: table) + entries.reduce(into: Data()) { result, entry in
            result.append(entry.payload)
        }
    }

    private func record(tag: String, payload: Data) -> Data {
        var data = Data()
        appendLE(&data, value: adler32(of: Data(tag.utf8) + payload), byteCount: 4)
        data.append(Data(tag.utf8))
        appendLE(&data, value: payload.count, byteCount: 8)
        data.append(payload)
        return data
    }

    private func zlibWrap(raw: Data) -> Data {
        var wrapped = Data([0x78, 0x01])
        wrapped.append(storedDeflate(of: raw))
        appendLE(&wrapped, value: adler32(of: raw), byteCount: 4)
        return wrapped
    }

    private func storedDeflate(of raw: Data) -> Data {
        var deflated = Data()
        var offset = 0
        repeat {
            let end = min(offset + 65_535, raw.count)
            let chunk = raw.subdata(in: offset..<end)
            deflated.append(end >= raw.count ? 0x01 : 0x00)
            appendLE(&deflated, value: chunk.count, byteCount: 2)
            appendLE(&deflated, value: chunk.count ^ 0xFFFF, byteCount: 2)
            deflated.append(chunk)
            offset = end
        } while offset < raw.count
        return deflated
    }

    private func appendLE<T: FixedWidthInteger>(_ data: inout Data, value: T, byteCount: Int) {
        var remaining = value
        for _ in 0..<byteCount {
            data.append(UInt8(truncatingIfNeeded: remaining & 0xFF))
            remaining >>= 8
        }
    }

    private func adler32(of data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return (b << 16) | a
    }
}
