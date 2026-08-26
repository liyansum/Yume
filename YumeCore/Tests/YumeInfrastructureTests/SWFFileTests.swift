import Foundation
import XCTest
@testable import YumeInfrastructure

final class SWFFileTests: XCTestCase {
    func testInspectsUncompressedSWFWithTags() throws {
        let fixture = try SWFFixture()
        defer { fixture.remove() }
        let body = SWFBuilder()
            .rect(minX: 0, maxX: 5500, minY: 0, maxY: 4000)
            .frame(rateRaw: 0x180C, count: 12)
            .tag(code: 9, length: 3)
            .tag(code: 69, length: 4)
            .end()
            .build()
        try fixture.write(signature: "FWS", version: 6, declaredByteCount: 8 + body.count, body: body)

        let inspection = try SWFFileParser().inspect(at: fixture.archiveURL)

        XCTAssertEqual(inspection.compressionKind, .none)
        XCTAssertEqual(inspection.version, 6)
        XCTAssertEqual(inspection.frameSize?.maxX, 5500)
        XCTAssertEqual(inspection.frameRateRaw, 0x180C)
        XCTAssertEqual(inspection.frameCount, 12)
        XCTAssertEqual(inspection.tagSummaries.map(\.code), [9, 69, 0])
    }

    func testCompressedHeaderOnlyAndLZMARejected() throws {
        let fixture = try SWFFixture()
        defer { fixture.remove() }
        try fixture.write(
            signature: "CWS",
            version: 32,
            declaredByteCount: 4096,
            body: Data(repeating: 0x11, count: 64)
        )
        let compressed = try SWFFileParser().inspect(at: fixture.archiveURL)

        XCTAssertEqual(compressed.compressionKind, .deflate)
        XCTAssertEqual(compressed.version, 32)
        XCTAssertNil(compressed.frameSize)
        XCTAssertTrue(compressed.tagSummaries.isEmpty)

        try fixture.write(
            signature: "ZWS",
            version: 13,
            declaredByteCount: 4096,
            body: Data(repeating: 0x22, count: 64)
        )
        XCTAssertThrowsError(try SWFFileParser().inspect(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? SWFError, .lzmaUnsupported)
        }

        try fixture.write(
            signature: "XXX",
            version: 1,
            declaredByteCount: 128,
            body: Data(repeating: 0x33, count: 64)
        )
        XCTAssertThrowsError(try SWFFileParser().inspect(at: fixture.archiveURL)) { error in
            XCTAssertEqual(error as? SWFError, .invalidSignature)
        }
    }
}

extension SWFFileTests: @unchecked Sendable {}

private struct SWFFixture {
    let root: URL
    let archiveURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "yume-swf-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        archiveURL = root.appendingPathComponent("fixture.swf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func write(signature: String, version: UInt8, declaredByteCount: Int, body: Data) throws {
        var data = Data(signature.utf8)
        data.append(version)
        var byteCount = UInt32(declaredByteCount).littleEndian
        withUnsafeBytes(of: &byteCount) { data.append(contentsOf: $0) }
        data.append(body)
        try data.write(to: archiveURL)
    }
}

private struct SWFBuilder {
    private var body = Data()

    mutating func rect(minX: Int, maxX: Int, minY: Int, maxY: Int) -> SWFBuilder {
        let bits = 16
        appendBits(UInt64(bits), count: 5)
        for value in [minX, maxX, minY, maxY] {
            appendSignedBits(Int64(value), count: bits)
        }
        alignToByte()
        return self
    }

    mutating func frame(rateRaw: UInt16, count: UInt16) -> SWFBuilder {
        body.append(UInt8(rateRaw & 0xFF))
        body.append(UInt8(rateRaw >> 8))
        body.append(UInt8(count & 0xFF))
        body.append(UInt8(count >> 8))
        return self
    }

    mutating func tag(code: UInt16, length: UInt32) -> SWFBuilder {
        if length < 0x3F {
            let combined = (code << 6) | UInt16(length)
            body.append(UInt8(combined & 0xFF))
            body.append(UInt8(combined >> 8))
        } else {
            let combined = (code << 6) | 0x3F
            body.append(UInt8(combined & 0xFF))
            body.append(UInt8(combined >> 8))
            var longLength = length.littleEndian
            withUnsafeBytes(of: &longLength) { body.append(contentsOf: $0) }
        }
        body.append(Data(repeating: 0xAB, count: Int(length)))
        return self
    }

    mutating func end() -> SWFBuilder {
        tag(code: 0, length: 0)
    }

    func build() -> Data {
        body
    }

    private var bitBuffer: (value: UInt64, count: Int) = (0, 0)

    private mutating func appendBits(_ value: UInt64, count: Int) {
        for shift in stride(from: count - 1, through: 0, by: -1) {
            let bit = (value >> UInt64(shift)) & 1
            bitBuffer.value = (bitBuffer.value << 1) | bit
            bitBuffer.count += 1
            if bitBuffer.count == 8 {
                body.append(UInt8(truncatingIfNeeded: bitBuffer.value))
                bitBuffer = (0, 0)
            }
        }
    }

    private mutating func appendSignedBits(_ value: Int64, count: Int) {
        appendBits(UInt64(bitPattern: value) & ((1 << UInt64(count)) - 1), count: count)
    }

    private mutating func alignToByte() {
        guard bitBuffer.count > 0 else { return }
        while bitBuffer.count < 8 {
            bitBuffer.value <<= 1
            bitBuffer.count += 1
        }
        body.append(UInt8(truncatingIfNeeded: bitBuffer.value))
        bitBuffer = (0, 0)
    }
}
