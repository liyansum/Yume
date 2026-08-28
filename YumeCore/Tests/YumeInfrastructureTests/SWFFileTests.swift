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

    func testCompressedSWFAndLZMARejected() throws {
        let fixture = try SWFFixture()
        defer { fixture.remove() }
        let rawBody = SWFBuilder()
            .rect(minX: 0, maxX: 3200, minY: 0, maxY: 1800)
            .frame(rateRaw: 0x1800, count: 1)
            .end()
            .build()
        try fixture.write(
            signature: "CWS",
            version: 10,
            declaredByteCount: 8 + rawBody.count,
            body: zlibStored(rawBody)
        )
        let compressed = try SWFFileParser().inspect(at: fixture.archiveURL)

        XCTAssertEqual(compressed.compressionKind, .deflate)
        XCTAssertEqual(compressed.version, 10)
        XCTAssertEqual(compressed.frameSize?.maxX, 3200)
        XCTAssertEqual(compressed.tagSummaries.map(\.code), [0])

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

    private func zlibStored(_ raw: Data) -> Data {
        precondition(raw.count <= 65_535)
        var result = Data([0x78, 0x01, 0x01])
        let length = UInt16(raw.count)
        let complement = ~length
        result.append(UInt8(length & 0xff))
        result.append(UInt8(length >> 8))
        result.append(UInt8(complement & 0xff))
        result.append(UInt8(complement >> 8))
        result.append(raw)
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in raw {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        let checksum = (b << 16) | a
        result.append(UInt8((checksum >> 24) & 0xff))
        result.append(UInt8((checksum >> 16) & 0xff))
        result.append(UInt8((checksum >> 8) & 0xff))
        result.append(UInt8(checksum & 0xff))
        return result
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

    func rect(minX: Int, maxX: Int, minY: Int, maxY: Int) -> SWFBuilder {
        var copy = self
        let bits = 16
        copy.appendBits(UInt64(bits), count: 5)
        for value in [minX, maxX, minY, maxY] {
            copy.appendSignedBits(Int64(value), count: bits)
        }
        copy.alignToByte()
        return copy
    }

    func frame(rateRaw: UInt16, count: UInt16) -> SWFBuilder {
        var copy = self
        copy.body.append(UInt8(rateRaw & 0xFF))
        copy.body.append(UInt8(rateRaw >> 8))
        copy.body.append(UInt8(count & 0xFF))
        copy.body.append(UInt8(count >> 8))
        return copy
    }

    func tag(code: UInt16, length: UInt32) -> SWFBuilder {
        var copy = self
        if length < 0x3F {
            let combined = (code << 6) | UInt16(length)
            copy.body.append(UInt8(combined & 0xFF))
            copy.body.append(UInt8(combined >> 8))
        } else {
            let combined = (code << 6) | 0x3F
            copy.body.append(UInt8(combined & 0xFF))
            copy.body.append(UInt8(combined >> 8))
            var longLength = length.littleEndian
            withUnsafeBytes(of: &longLength) { copy.body.append(contentsOf: $0) }
        }
        copy.body.append(Data(repeating: 0xAB, count: Int(length)))
        return copy
    }

    func end() -> SWFBuilder {
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
