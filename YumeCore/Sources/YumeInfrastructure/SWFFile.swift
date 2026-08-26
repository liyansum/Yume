import Foundation

public enum SWFError: Error, Equatable, Sendable {
    case sourceIsNotFileURL
    case sourceMissing
    case sourceIsSymbolicLink
    case invalidSignature
    case tooSmall
    case truncatedHeader
    case lzmaUnsupported
    case invalidRect
    case tagLimitExceeded
    case outOfBounds
}

public enum SWFCompressionKind: String, Sendable, Equatable {
    case none
    case deflate
}

public struct SWFRect: Sendable, Equatable {
    public let minX: Int32
    public let maxX: Int32
    public let minY: Int32
    public let maxY: Int32

    public init(minX: Int32, maxX: Int32, minY: Int32, maxY: Int32) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
    }
}

public struct SWFTagSummary: Sendable, Equatable {
    public let code: UInt16
    public let byteLength: UInt32

    public init(code: UInt16, byteLength: UInt32) {
        self.code = code
        self.byteLength = byteLength
    }
}

public struct SWFInspection: Sendable, Equatable {
    public let compressionKind: SWFCompressionKind
    public let version: UInt8
    public let declaredByteCount: UInt32
    public let frameSize: SWFRect?
    public let frameRateRaw: UInt16?
    public let frameCount: UInt16?
    public let tagSummaries: [SWFTagSummary]

    public init(
        compressionKind: SWFCompressionKind,
        version: UInt8,
        declaredByteCount: UInt32,
        frameSize: SWFRect?,
        frameRateRaw: UInt16?,
        frameCount: UInt16?,
        tagSummaries: [SWFTagSummary]
    ) {
        self.compressionKind = compressionKind
        self.version = version
        self.declaredByteCount = declaredByteCount
        self.frameSize = frameSize
        self.frameRateRaw = frameRateRaw
        self.frameCount = frameCount
        self.tagSummaries = tagSummaries
    }
}

public struct SWFFileParser: Sendable {
    private static let headerByteCount = 8
    private static let endTagCode: UInt16 = 0
    private static let longFormLengthMarker: UInt16 = 0x3F
    private static let maximumTagScanCount = 512
    private static let maximumBitReaderBytes = 4 * 1_024 * 1_024

    private let maximumTagSummaries: Int

    public init(maximumTagSummaries: Int = SWFFileParser.maximumTagScanCount) {
        self.maximumTagSummaries = maximumTagSummaries
    }

    public func inspect(at url: URL) throws -> SWFInspection {
        guard url.isFileURL else { throw SWFError.sourceIsNotFileURL }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw SWFError.sourceIsSymbolicLink }
        guard values.isRegularFile == true else { throw SWFError.sourceMissing }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: Self.headerByteCount),
              header.count == Self.headerByteCount
        else { throw SWFError.tooSmall }

        let signature = [UInt8](header.prefix(3))
        switch Array(signature) {
        case Array("FWS".utf8):
            break
        case Array("CWS".utf8):
            return SWFInspection(
                compressionKind: .deflate,
                version: header[header.startIndex + 3],
                declaredByteCount: readUInt32LE(header, at: 4),
                frameSize: nil,
                frameRateRaw: nil,
                frameCount: nil,
                tagSummaries: []
            )
        default:
            if signature.elementsEqual(Array("ZWS".utf8)) {
                throw SWFError.lzmaUnsupported
            }
            throw SWFError.invalidSignature
        }

        let version = header[header.startIndex + 3]
        guard version > 0 else { throw SWFError.invalidSignature }
        let declaredByteCount = readUInt32LE(header, at: 4)

        try handle.seek(toOffset: UInt64(Self.headerByteCount))
        let remainingLimit = min(Self.maximumBitReaderBytes, max(0, Int(declaredByteCount) - Self.headerByteCount))
        guard remainingLimit > 0 else { throw SWFError.truncatedHeader }
        guard let payload = try handle.read(upToCount: remainingLimit), !payload.isEmpty else {
            throw SWFError.truncatedHeader
        }
        body = payload

        var reader = BitReader(data: body)
        let rect = try reader.readRect()
        let frameRateRaw = try reader.readUInt16()
        let frameCount = try reader.readUInt16()

        var summaries: [SWFTagSummary] = []
        while !reader.isAtEnd {
            guard summaries.count < maximumTagSummaries else { throw SWFError.tagLimitExceeded }
            let codeAndLength = try reader.readUInt16()
            let code = codeAndLength >> 6
            var length = UInt32(codeAndLength & Self.longFormLengthMarker)
            if length == UInt32(Self.longFormLengthMarker) {
                length = try reader.readUInt32()
            }
            summaries.append(SWFTagSummary(code: code, byteLength: length))
            if code == Self.endTagCode { break }
            try reader.skip(UInt64(length))
        }

        return SWFInspection(
            compressionKind: .none,
            version: version,
            declaredByteCount: declaredByteCount,
            frameSize: rect,
            frameRateRaw: frameRateRaw,
            frameCount: frameCount,
            tagSummaries: summaries
        )
    }

    private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(data[data.startIndex + offset + index]) << (8 * UInt32(index))
        }
        return value
    }
}

private struct BitReader {
    private let bytes: [UInt8]
    private var byteIndex = 0
    private var bitIndex = 0

    init(data: Data) {
        bytes = [UInt8](data)
    }

    var isAtEnd: Bool {
        byteIndex >= bytes.count
    }

    mutating func skip(_ bitCount: UInt64) throws {
        var remainingBits = bitCount
        while remainingBits > 0 {
            if isAtEnd { throw SWFError.outOfBounds }
            let available = UInt64(8 - bitIndex)
            if remainingBits >= available {
                remainingBits -= available
                advanceByte()
            } else {
                bitIndex += Int(remainingBits)
                remainingBits = 0
            }
        }
    }

    mutating func readBit() throws -> UInt8 {
        if isAtEnd { throw SWFError.outOfBounds }
        let bit = (bytes[byteIndex] >> (7 - bitIndex)) & 1
        bitIndex += 1
        if bitIndex == 8 { advanceByte() }
        return bit
    }

    mutating func readBits(_ count: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<count {
            value = (value << 1) | UInt64(try readBit())
        }
        return value
    }

    mutating func readIntBits(_ count: Int) throws -> Int64 {
        guard count > 0 else { return 0 }
        var raw = try readBits(count)
        if count < 64 {
            let signMask = UInt64(1) << UInt64(count - 1)
            if raw & signMask != 0 {
                raw |= ~((signMask << 1) &- 1)
            }
        }
        return Int64(bitPattern: raw)
    }

    mutating func readUInt16() throws -> UInt16 {
        let low = try readBits(8)
        let high = try readBits(8)
        return UInt16(high) << 8 | UInt16(low)
    }

    mutating func readUInt32() throws -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(try readBits(8)) << (8 * UInt32(index))
        }
        return value
    }

    mutating func readRect() throws -> SWFRect {
        let bitsPerCoordinate = Int(try readBits(5))
        guard bitsPerCoordinate > 0, bitsPerCoordinate <= 31 else { throw SWFError.invalidRect }
        let minX = try readIntBits(bitsPerCoordinate)
        let maxX = try readIntBits(bitsPerCoordinate)
        let minY = try readIntBits(bitsPerCoordinate)
        let maxY = try readIntBits(bitsPerCoordinate)
        return SWFRect(minX: Int32(truncatingIfNeeded: minX), maxX: Int32(truncatingIfNeeded: maxX), minY: Int32(truncatingIfNeeded: minY), maxY: Int32(truncatingIfNeeded: maxY))
    }

    private mutating func advanceByte() {
        bitIndex = 0
        byteIndex += 1
    }
}
