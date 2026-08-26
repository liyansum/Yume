import Foundation
import XCTest
@testable import YumeInfrastructure

final class NScripterArchiveTests: XCTestCase {
    func testSniffIndexAndExtractStoredEntries() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        try ArchiveBuilder.make(kind: "SAR", entries: [
            .stored("one.txt", data: Data("alpha".utf8)),
            .stored("sub/two.bin", data: Data([0x00, 0x02, 0x03]))
        ]).write(to: fixture.archiveURL)
        let archive = NScripterArchive()

        XCTAssertEqual(try NScripterArchive.sniffKind(at: fixture.archiveURL), .sar)
        let entries = try archive.index(at: fixture.archiveURL)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].relativePath.rawValue, "one.txt")
        XCTAssertEqual(entries[0].offset, 53)
        XCTAssertEqual(entries[0].byteCount, 5)
        XCTAssertFalse(entries[0].isCompressed)
        XCTAssertEqual(entries[1].relativePath.rawValue, "sub/two.bin")
        XCTAssertEqual(entries[1].offset, 58)
        XCTAssertEqual(entries[1].byteCount, 3)
        XCTAssertFalse(entries[1].isCompressed)

        let destination = fixture.root.appendingPathComponent("out/one.txt")
        try archive.extract(entries[0], from: fixture.archiveURL, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("alpha".utf8))
    }

    func testNSACompressionFlagIsStrippedButExtractionRefused() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        try ArchiveBuilder.make(kind: "NSA", entries: [
            .flagged("comp.dat", data: Data([0x01, 0xAA])),
            .stored("plain.txt", data: Data("ok".utf8))
        ]).write(to: fixture.archiveURL)
        let archive = NScripterArchive()

        XCTAssertEqual(try NScripterArchive.sniffKind(at: fixture.archiveURL), .nsa)
        let entries = try archive.index(at: fixture.archiveURL)

        XCTAssertTrue(entries[0].isCompressed)
        XCTAssertEqual(entries[0].relativePath.rawValue, "comp.dat")
        XCTAssertEqual(entries[0].offset, 53)
        XCTAssertEqual(entries[0].byteCount, 2)
        XCTAssertFalse(entries[1].isCompressed)

        XCTAssertThrowsError(
            try archive.extract(entries[0], from: fixture.archiveURL, to: fixture.unusedURL)
        ) { error in
            XCTAssertEqual(error as? NSArcError, .unsupportedEncryption)
        }

        let destination = fixture.root.appendingPathComponent("out/plain.txt")
        try archive.extract(entries[1], from: fixture.archiveURL, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("ok".utf8))
    }

    func testNS2IsRecognizedAndIndexedLikeNSA() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        try ArchiveBuilder.make(kind: "NS2", entries: [
            .stored("only.txt", data: Data("solo".utf8))
        ]).write(to: fixture.archiveURL)
        let archive = NScripterArchive()

        XCTAssertEqual(try NScripterArchive.sniffKind(at: fixture.archiveURL), .ns2)
        let entries = try archive.index(at: fixture.archiveURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].offset, 29)
        XCTAssertEqual(entries[0].byteCount, 4)
    }

    func testMagicMismatchFailsClosed() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        try ArchiveBuilder.make(kind: "XYZ", entries: [
            .stored("a.bin", data: Data([0x01]))
        ]).write(to: fixture.archiveURL)

        XCTAssertThrowsError(try NScripterArchive.sniffKind(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? NSArcError, .magicMismatch)
        }
        XCTAssertThrowsError(try NScripterArchive().index(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? NSArcError, .magicMismatch)
        }

        try Data([0x53, 0x41]).write(to: fixture.archiveURL)
        XCTAssertThrowsError(try NScripterArchive().index(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? NSArcError, .truncatedDirectory)
        }
        XCTAssertThrowsError(try NScripterArchive.sniffKind(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? NSArcError, .magicMismatch)
        }
    }

    func testTruncatedDirectoryFailsClosed() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        try ArchiveBuilder.make(
            kind: "SAR",
            entries: [
                .stored("a.bin", data: Data([0x01])),
                .stored("b.bin", data: Data([0x02]))
            ],
            declaredEntryCount: 3
        ).write(to: fixture.archiveURL)

        XCTAssertThrowsError(try NScripterArchive().index(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? NSArcError, .truncatedDirectory)
        }
    }

    func testOutOfBoundsOffsetsAndSizesAreRejected() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        try ArchiveBuilder.make(kind: "SAR", entries: [
            .stored("far.bin", data: Data([0x01]), declaredOffset: 1_000_000)
        ]).write(to: fixture.archiveURL)
        XCTAssertThrowsError(try NScripterArchive().index(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? NSArcError, .outOfBounds)
        }

        try ArchiveBuilder.make(kind: "SAR", entries: [
            .stored("big.bin", data: Data([0x01]), declaredSize: 999)
        ]).write(to: fixture.archiveURL)
        XCTAssertThrowsError(try NScripterArchive().index(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? NSArcError, .outOfBounds)
        }
    }

    func testCaseFoldedDuplicatePathsAreRejected() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        try ArchiveBuilder.make(kind: "SAR", entries: [
            .stored("Save.txt", data: Data("a".utf8)),
            .stored("save.txt", data: Data("b".utf8))
        ]).write(to: fixture.archiveURL)

        XCTAssertThrowsError(try NScripterArchive().index(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? NSArcError, .duplicatePath)
        }
    }

    func testLimitsAreEnforcedBeforeAndDuringParsing() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        try ArchiveBuilder.make(kind: "SAR", entries: [
            .stored("a.bin", data: Data([0x01])),
            .stored("b.bin", data: Data([0x02]))
        ]).write(to: fixture.archiveURL)

        XCTAssertThrowsError(
            try NScripterArchive(limits: .init(maximumEntryCount: 1)).index(at: fixture.archiveURL)
        ) { error in
            XCTAssertEqual(error as? NSArcError, .entryLimitExceeded)
        }
        XCTAssertThrowsError(
            try NScripterArchive(limits: .init(maximumExpandedByteCount: 1)).index(at: fixture.archiveURL)
        ) { error in
            XCTAssertEqual(error as? NSArcError, .expandedSizeLimitExceeded)
        }
    }

    func testExtractRefusesExistingDestinationAndSourceOverwrite() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        try ArchiveBuilder.make(kind: "SAR", entries: [
            .stored("one.txt", data: Data("alpha".utf8))
        ]).write(to: fixture.archiveURL)
        let archive = NScripterArchive()
        let entry = try archive.index(at: fixture.archiveURL)[0]

        let destination = fixture.root.appendingPathComponent("out/one.txt")
        try archive.extract(entry, from: fixture.archiveURL, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("alpha".utf8))

        XCTAssertThrowsError(
            try archive.extract(entry, from: fixture.archiveURL, to: destination)
        ) { error in
            XCTAssertEqual(error as? NSArcError, .destinationAlreadyExists)
        }
    }

    func testExtractRemovesPartialOutputWhenSourceEndsEarly() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        try ArchiveBuilder.make(kind: "SAR", entries: [
            .stored("one.txt", data: Data("alphalong".utf8))
        ]).write(to: fixture.archiveURL)
        let archive = NScripterArchive()
        let entry = try archive.index(at: fixture.archiveURL)[0]

        var truncated = try Data(contentsOf: fixture.archiveURL)
        truncated.removeLast(4)
        try truncated.write(to: fixture.archiveURL)

        let destination = fixture.root.appendingPathComponent("out/one.txt")
        XCTAssertThrowsError(
            try archive.extract(entry, from: fixture.archiveURL, to: destination)
        ) { error in
            XCTAssertEqual(error as? NSArcError, .outOfBounds)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}

private struct ArchiveFixture {
    let root: URL
    let archiveURL: URL
    let unusedURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "yume-nsarc-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        archiveURL = root.appendingPathComponent("fixture.arc")
        unusedURL = root.appendingPathComponent("unused.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum ArchiveBuilder {
    struct BuiltEntry {
        let name: String
        let data: Data
        let flagged: Bool
        let declaredOffset: UInt64?
        let declaredSize: UInt32?

        static func stored(
            _ name: String,
            data: Data,
            declaredOffset: UInt64? = nil,
            declaredSize: UInt32? = nil
        ) -> BuiltEntry {
            BuiltEntry(
                name: name,
                data: data,
                flagged: false,
                declaredOffset: declaredOffset,
                declaredSize: declaredSize
            )
        }

        static func flagged(
            _ name: String,
            data: Data,
            declaredOffset: UInt64? = nil,
            declaredSize: UInt32? = nil
        ) -> BuiltEntry {
            BuiltEntry(
                name: name,
                data: data,
                flagged: true,
                declaredOffset: declaredOffset,
                declaredSize: declaredSize
            )
        }
    }

    static func make(
        kind: String,
        entries: [BuiltEntry],
        declaredEntryCount: UInt16? = nil
    ) -> Data {
        precondition(kind.utf8.count == 3)
        let directoryEnd = 5 + entries.count * 24
        var directory = Data(kind.utf8)
        appendBE(UInt16(declaredEntryCount ?? UInt16(entries.count)), to: &directory)

        var payload = Data()
        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            precondition(nameBytes.count <= 16)
            var field = nameBytes
            field.append(Data(repeating: 0, count: 16 - nameBytes.count))
            directory.append(field)

            let offsetValue = entry.declaredOffset
                ?? UInt64(directoryEnd + payload.count)
            let flag: UInt32 = entry.flagged ? 0x8000_0000 : 0
            appendBE(UInt32(truncatingIfNeeded: offsetValue) | flag, to: &directory)
            appendBE((entry.declaredSize ?? UInt32(entry.data.count)) | flag, to: &directory)
            payload.append(entry.data)
        }

        var archive = directory
        archive.append(payload)
        return archive
    }

    private static func appendBE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
