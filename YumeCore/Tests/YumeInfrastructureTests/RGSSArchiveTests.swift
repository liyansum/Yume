import Foundation
import XCTest
import YumeDomain
@testable import YumeInfrastructure

final class RGSSArchiveTests: XCTestCase {
    func testIndexesAndExtractsV1Archive() throws {
        let fixture = try RGSSADFixture()
        defer { fixture.remove() }
        let files: [(String, Data)] = [
            ("Graphics\\Battlers\\hero.png", Data("hero-bytes".utf8)),
            ("Data\\Actors.rxdata", Data("{\"actors\":1}".utf8))
        ]
        try fixture.write(version: 0x01, entries: files)

        let archive = RGSSArchive()
        let entries = try archive.index(at: fixture.archiveURL)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(
            Set(entries.map(\.relativePath.rawValue)),
            ["Graphics/Battlers/hero.png", "Data/Actors.rxdata"]
        )

        let hero = try XCTUnwrap(entries.first { $0.relativePath.rawValue == "Graphics/Battlers/hero.png" })
        let destination = fixture.destination("hero-copy.bin")
        try archive.extract(hero, from: fixture.archiveURL, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("hero-bytes".utf8))
    }

    func testRejectsVersionThreeAndBadMagic() throws {
        let fixture = try RGSSADFixture()
        defer { fixture.remove() }

        try fixture.write(version: 0x03, entries: [])
        XCTAssertThrowsError(try RGSSArchive().index(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? RGSSADError, .versionThreeUnsupported)
        }

        try fixture.write(version: 0x09, entries: [])
        XCTAssertThrowsError(try RGSSArchive().index(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? RGSSADError, .magicMismatch)
        }
    }

    func testDuplicateCaseFoldedNamesAreRejected() throws {
        let fixture = try RGSSADFixture()
        defer { fixture.remove() }
        try fixture.write(version: 0x01, entries: [
            ("Data/Same.png", Data("a".utf8)),
            ("data\\same.PNG", Data("b".utf8))
        ])

        XCTAssertThrowsError(try RGSSArchive().index(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? RGSSADError, .duplicatePath)
        }
    }
}

extension RGSSArchiveTests: @unchecked Sendable {}

private struct RGSSADFixture {
    let root: URL
    let archiveURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "yume-rgssad-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        archiveURL = root.appendingPathComponent("Game.rgssad")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func destination(_ name: String) -> URL {
        root.appendingPathComponent(name)
    }

    func write(version: UInt8, entries: [(String, Data)]) throws {
        var data = Data(Array("RGSSAD\0".utf8))
        data.append(version)

        if version == 0x01 {
            var key: UInt32 = 0xDEAD_CAFE
            func advance() { key = key &* 7 &+ 3 }

            var table = Data()
            var blobCursor: UInt32 = 0
            let tocByteCount = entries.reduce(0) { length, entry in
                length + 12 + Data(entry.0.utf8).count
            }
            let blobStart = UInt32(8 + tocByteCount)

            for (path, payload) in entries {
                let nameBytes = Data(path.utf8)
                appendScrambled(&table, UInt32(nameBytes.count), key: &key)
                for byte in nameBytes {
                    table.append(byte ^ UInt8(truncatingIfNeeded: key & 0xFF))
                    advance()
                }
                appendScrambled(&table, blobStart + blobCursor, key: &key)
                appendScrambled(&table, UInt32(payload.count), key: &key)
                blobCursor += UInt32(payload.count)
            }
            data.append(table)
            data.append(entries.reduce(into: Data()) { $0.append($1.1) })
        } else {
            data.append(Data(repeating: 0xAB, count: 16))
        }
        try data.write(to: archiveURL)
    }

    private func appendScrambled(_ data: inout Data, _ value: UInt32, key: inout UInt32) {
        let scrambled = value ^ key
        key = key &* 7 &+ 3
        data.append(UInt8(truncatingIfNeeded: scrambled & 0xFF))
        data.append(UInt8(truncatingIfNeeded: (scrambled >> 8) & 0xFF))
        data.append(UInt8(truncatingIfNeeded: (scrambled >> 16) & 0xFF))
        data.append(UInt8(truncatingIfNeeded: (scrambled >> 24) & 0xFF))
    }
}

extension RGSSArchiveTests: @unchecked Sendable {}

private struct RGSSADFixture {
    let root: URL
    let archiveURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "yume-rgssad-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        archiveURL = root.appendingPathComponent("Game.rgssad")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func destination(_ name: String) -> URL {
        root.appendingPathComponent(name)
    }

    func write(version: UInt8, entries: [(String, Data)]) throws {
        var data = Data(Array("RGSSAD\0".utf8))
        data.append(version)

        if version == 0x01 {
            var key: UInt32 = 0xDEAD_CAFE
            func advance() { key = key &* 7 &+ 3 }

            var blob = Data()
            for (path, payload) in entries {
                let nameBytes = Data(path.utf8)
                appendScrambled(&data, UInt32(nameBytes.count), key: &key)
                for byte in nameBytes {
                    data.append(byte ^ UInt8(truncatingIfNeeded: key & 0xFF))
                    advance()
                }
                let offset = UInt64(8) + UInt64(data.count - 8 - currentTOCLength()) + UInt64(blob.count)
                appendScrambled(&data, UInt32(truncatingIfNeeded: offset), key: &key)
                appendScrambled(&data, UInt32(payload.count), key: &key)
                blob.append(payload)
            }
            data.append(blob)
        } else {
            data.append(Data(repeating: 0xAB, count: 16))
        }
        try data.write(to: archiveURL)
    }

    private func currentTOCLength() -> Int {
        0
    }

    private func appendScrambled(_ data: inout Data, _ value: UInt32, key: inout UInt32) {
        let scrambled = value ^ key
        key = key &* 7 &+ 3
        data.append(UInt8(truncatingIfNeeded: scrambled & 0xFF))
        data.append(UInt8(truncatingIfNeeded: (scrambled >> 8) & 0xFF))
        data.append(UInt8(truncatingIfNeeded: (scrambled >> 16) & 0xFF))
        data.append(UInt8(truncatingIfNeeded: (scrambled >> 24) & 0xFF))
    }
}
