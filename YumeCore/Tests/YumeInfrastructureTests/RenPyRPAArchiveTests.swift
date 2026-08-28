import Foundation
import XCTest
import YumeDomain
@testable import YumeInfrastructure

final class RenPyRPAArchiveTests: XCTestCase {
    func testDecodesRPA20IndexWithKey() throws {
        let key: UInt32 = 0x2A
        let index = PickleBuilder()
            .add(name: "resources/logo.png", offset: 0x1F4, size: 4096, key: key)
            .add(name: "data/script.rpyc", offset: 0x10000, size: 512, key: key)
            .build()
        let entries = try RenPyRPAArchive().decodeIndex(index, key: key)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].relativePath.rawValue, "resources/logo.png")
        XCTAssertEqual(entries[0].offset, 0x1F4)
        XCTAssertEqual(entries[0].byteCount, 4096)
        XCTAssertEqual(entries[1].relativePath.rawValue, "data/script.rpyc")
        XCTAssertEqual(entries[1].offset, 0x10000)
    }

    func testDecodesThreeFieldTuplesWithoutKey() throws {
        let index = PickleBuilder()
            .add(name: "movie.webm", offset: 16, prefixLength: 3, size: 991)
            .build()
        let entries = try RenPyRPAArchive().decodeIndex(index, key: nil)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].relativePath.rawValue, "movie.webm")
        XCTAssertEqual(entries[0].offset, 16)
        XCTAssertEqual(entries[0].byteCount, 991)
    }

    func testRejectsUnknownOpcodesAndDuplicatePaths() throws {
        XCTAssertThrowsError(try RenPyRPAArchive().decodeIndex(Data([0x63]), key: nil)) { error in
            XCTAssertEqual(error as? RPAError, .invalidArchive)
        }

        let duplicate = PickleBuilder()
            .add(name: "Same.txt", offset: 1, size: 2, key: 0)
            .add(name: "same.TXT", offset: 3, size: 4, key: 0)
            .build()
        XCTAssertThrowsError(try RenPyRPAArchive().decodeIndex(duplicate, key: nil)) { error in
            XCTAssertEqual(error as? RPAError, .duplicatePath)
        }
    }

    func testRejectsTraversalPaths() throws {
        let traversal = PickleBuilder()
            .add(name: "../escape.bin", offset: 1, size: 2, key: 0)
            .build()
        XCTAssertThrowsError(try RenPyRPAArchive().decodeIndex(traversal, key: nil)) { error in
            XCTAssertEqual(error as? RPAError, .unsafePath)
        }
    }

    func testReadsHeaderAndIndexFromFile() throws {
        let fixture = try RPAFixture()
        defer { fixture.remove() }
        let key: UInt32 = 0x7E
        let index = PickleBuilder()
            .add(name: "archive/file.txt", offset: 64, size: 5, key: key)
            .build()
        try fixture.write(headerVersion: "RPA-2.0", key: key, indexOffset: 32, index: index)

        let entries = try RenPyRPAArchive().index(at: fixture.archiveURL)
        XCTAssertEqual(entries.map(\.relativePath.rawValue), ["archive/file.txt"])
        XCTAssertEqual(entries[0].offset, 64)

        try fixture.write(headerVersion: "RPA-9.9", key: key, indexOffset: 32, index: index)
        XCTAssertThrowsError(try RenPyRPAArchive().index(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? RPAError, .unsupportedFormatVersion("RPA-9.9"))
        }
    }
}

extension RenPyRPAArchiveTests: @unchecked Sendable {}

private struct RPAFixture {
    let root: URL
    let archiveURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "yume-rpa-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        archiveURL = root.appendingPathComponent("fixture.rpa")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func write(headerVersion: String, key: UInt32?, indexOffset: UInt64, index: Data) throws {
        var data = Data((headerVersion + " ").utf8)
        data.append(contentsOf: String(format: "%x", indexOffset).utf8)
        if let key {
            data.append(contentsOf: String(format: " %x", key).utf8)
        }
        data.append(0x0A)
        data.append(Data(repeating: 0, count: Int(indexOffset) - data.count))
        data.append(index)
        try data.write(to: archiveURL)
    }
}

private struct PickleBuilder {
    private struct BuiltEntry {
        let name: String
        let offset: Int
        let size: Int
        let prefixLength: Int?
    }

    private var entries: [BuiltEntry] = []

    func add(name rawName: String, offset: Int, size: Int, key: UInt32) -> PickleBuilder {
        let scalars = rawName.unicodeScalars.map { Unicode.Scalar($0.value ^ key) ?? $0 }
        let xored = String(String.UnicodeScalarView(scalars))
        var copy = self
        copy.entries.append(BuiltEntry(name: xored, offset: offset, size: size, prefixLength: nil))
        return copy
    }

    func add(name: String, offset: Int, prefixLength: Int, size: Int) -> PickleBuilder {
        var copy = self
        copy.entries.append(BuiltEntry(name: name, offset: offset, size: size, prefixLength: prefixLength))
        return copy
    }

    func build() -> Data {
        var data = Data([0x80, 0x02])
        data.append(0x7D)
        data.append(0x28)
        for entry in entries {
            appendText(&data, entry.name)
            if entry.prefixLength == nil {
                data.append(contentsOf: [0x28])
                appendInt(&data, entry.offset)
                appendInt(&data, entry.size)
                data.append(0x74)
            } else {
                data.append(contentsOf: [0x28])
                appendInt(&data, entry.offset)
                data.append(contentsOf: [0x55, UInt8(entry.prefixLength!)])
                data.append(Data(repeating: 0x61, count: entry.prefixLength!))
                appendInt(&data, entry.size)
                data.append(0x74)
            }
        }
        data.append(0x75)
        data.append(0x2E)
        return data
    }

    private func appendText(_ data: inout Data, _ text: String) {
        let payload = Data(text.utf8)
        data.append(0x58)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
    }

    private func appendInt(_ data: inout Data, _ value: Int) {
        data.append(0x49)
        data.append(contentsOf: String(value).utf8)
        data.append(0x0A)
    }
}

extension RenPyRPAArchiveTests {
    func testExtractSkipsPrefixBytes() throws {
        let fixture = try RPAFixture()
        defer { fixture.remove() }
        let prefix = Data("--prefix-junk-".utf8)
        let content = Data("real-renpy-script-content".utf8)
        var file = Data(repeating: 0, count: 32)
        file.append(prefix)
        file.append(content)
        try file.write(to: fixture.archiveURL)

        let entry = RPAGameFileEntry(
            relativePath: try StorageRelativePath(rawValue: "script.rpyc"),
            offset: 32,
            byteCount: UInt64(content.count),
            prefixByteCount: prefix.count
        )

        let destination = fixture.root.appendingPathComponent("out.rpyc")
        try RenPyRPAArchive().extract(entry, from: fixture.archiveURL, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), content)
    }
}
