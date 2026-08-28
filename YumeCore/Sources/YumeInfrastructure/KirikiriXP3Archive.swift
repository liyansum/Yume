import CYumeZlib
import Foundation
import YumeDomain

public enum XP3Error: Error, Equatable, Sendable {
    case sourceIsNotFileURL
    case sourceMissing
    case sourceIsSymbolicLink
    case invalidArchive
    case magicMismatch
    case unsupportedHeaderVariant
    case truncatedTOC
    case protectedEntryUnsupported
    case compressedEntryUnsupported
    case unsafePath
    case duplicatePath
    case entryLimitExceeded
    case pathLimitExceeded
    case expandedSizeLimitExceeded
    case decompressionFailed(Int32)
    case destinationAlreadyExists
    case outOfBounds
}

public struct XP3Limits: Sendable, Equatable {
    public let maximumEntryCount: Int
    public let maximumPathByteCount: Int
    public let maximumExpandedByteCount: Int64
    public let maximumTOCByteCount: Int64

    public init(
        maximumEntryCount: Int = 100_000,
        maximumPathByteCount: Int = 1_024,
        maximumExpandedByteCount: Int64 = 4 * 1_073_741_824,
        maximumTOCByteCount: Int64 = 64 * 1_024 * 1_024
    ) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumPathByteCount = maximumPathByteCount
        self.maximumExpandedByteCount = maximumExpandedByteCount
        self.maximumTOCByteCount = maximumTOCByteCount
    }
}

public struct XP3Entry: Sendable, Equatable {
    public let relativePath: StorageRelativePath
    public let uncompressedSize: UInt64
    public let archivedSize: UInt64
    public let dataOffset: UInt64
    public let isProtected: Bool
    public let isCompressed: Bool

    public init(
        relativePath: StorageRelativePath,
        uncompressedSize: UInt64,
        archivedSize: UInt64,
        dataOffset: UInt64,
        isProtected: Bool,
        isCompressed: Bool = false
    ) {
        self.relativePath = relativePath
        self.uncompressedSize = uncompressedSize
        self.archivedSize = archivedSize
        self.dataOffset = dataOffset
        self.isProtected = isProtected
        self.isCompressed = isCompressed
    }
}

public struct KirikiriXP3Archive: Sendable {
    private static let headerPrefix: [UInt8] = [0x58, 0x50, 0x33, 0x0D, 0x0A, 0x20, 0x0A, 0x1A]
    private static let classicVariant: [UInt8] = [0x8D, 0xEA]
    private static let modernVariant: [UInt8] = [0x67, 0x4E]
    private static let tocOffsetByteCount = 8
    private static let recordHeaderByteCount = 16
    private static let copyBufferByteCount = 65_536

    private let limits: XP3Limits

    public init(limits: XP3Limits = XP3Limits()) {
        self.limits = limits
    }

    public func index(at url: URL) throws -> [XP3Entry] {
        guard url.isFileURL else { throw XP3Error.sourceIsNotFileURL }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isSymbolicLink != true else { throw XP3Error.sourceIsSymbolicLink }
        guard values.isRegularFile == true else { throw XP3Error.sourceMissing }

        let fileSize = UInt64(values.fileSize ?? 0)
        let fixedHeaderByteCount = Self.headerPrefix.count + Self.classicVariant.count + Self.tocOffsetByteCount
        guard fileSize >= UInt64(fixedHeaderByteCount) else { throw XP3Error.truncatedTOC }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: 0)
        let prefix = try requireBytes(handle, count: Self.headerPrefix.count)
        guard prefix == Self.headerPrefix else { throw XP3Error.magicMismatch }

        let variant = try requireBytes(handle, count: 2)
        guard variant == Self.classicVariant || variant == Self.modernVariant else {
            throw XP3Error.unsupportedHeaderVariant
        }

        let tocOffsetBytes = try requireBytes(handle, count: Self.tocOffsetByteCount)
        var reader = ByteReader(data: Data(tocOffsetBytes))
        let tocOffset = try reader.readUInt64()
        guard tocOffset > 0, tocOffset < fileSize else { throw XP3Error.truncatedTOC }

        return try parseTOC(sourcePath: url.path, tocOffset: tocOffset, fileSize: fileSize)
    }

    public func extract(_ entry: XP3Entry, from sourceURL: URL, to destinationURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw XP3Error.destinationAlreadyExists
        }
        guard !entry.isProtected else { throw XP3Error.protectedEntryUnsupported }

        if entry.isCompressed {
            return try extractCompressed(entry, from: sourceURL, to: destinationURL)
        }

        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }
        do {
            let fileSize = try UInt64(handle.seekToEnd())
            guard entry.dataOffset < fileSize, entry.archivedSize <= fileSize - entry.dataOffset else {
                throw XP3Error.outOfBounds
            }
            try handle.seek(toOffset: entry.dataOffset)
            guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
                throw XP3Error.invalidArchive
            }
            let output = try FileHandle(forWritingTo: destinationURL)
            defer { try? output.close() }

            var remaining = entry.archivedSize
            while remaining > 0 {
                let requested = Int(min(UInt64(Self.copyBufferByteCount), remaining))
                guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else {
                    throw XP3Error.outOfBounds
                }
                try output.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private struct Chunk {
        let tag: String
        let payload: Data
    }

    private func extractCompressed(_ entry: XP3Entry, from sourceURL: URL, to destinationURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw XP3Error.destinationAlreadyExists
        }
        do {
            let result = sourceURL.path.withCString { source in
                destinationURL.path.withCString { output in
                    yume_deflate_raw_to_file(
                        source,
                        entry.dataOffset,
                        entry.archivedSize,
                        output,
                        entry.uncompressedSize
                    )
                }
            }
            guard result == YUME_ZIP_OK else { throw XP3Error.decompressionFailed(result) }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private func parseTOC(sourcePath: String, tocOffset: UInt64, fileSize: UInt64) throws -> [XP3Entry] {
        guard tocOffset + 20 <= fileSize else { throw XP3Error.truncatedTOC }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: sourcePath))
        defer { try? handle.close() }
        try handle.seek(toOffset: tocOffset)
        var headerReader = ByteReader(data: Data(try requireBytes(handle, count: 20)))
        _ = try headerReader.readUInt32()
        let zippedByteCount = try headerReader.readUInt64()
        let rawByteCount = try headerReader.readUInt64()

        guard zippedByteCount > 0,
              zippedByteCount < fileSize,
              rawByteCount > 0,
              zippedByteCount <= UInt64(limits.maximumTOCByteCount),
              rawByteCount <= UInt64(limits.maximumTOCByteCount),
              tocOffset <= fileSize - 20 - zippedByteCount
        else { throw XP3Error.truncatedTOC }

        let inflatedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yume-xp3-toc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: inflatedURL) }

        let result = sourcePath.withCString { source in
            inflatedURL.path.withCString { output in
                yume_zlib_inflate_to_file(source, tocOffset + 20, zippedByteCount, output, rawByteCount)
            }
        }
        guard result == YUME_ZIP_OK else { throw XP3Error.decompressionFailed(result) }

        let table = try Data(contentsOf: inflatedURL, options: [.mappedIfSafe])
        var entries: [XP3Entry] = []
        var foldedPaths: Set<String> = []
        var totalUncompressed: UInt64 = 0
        var pendingChunks: [Chunk] = []
        var cursor = 0

        func flushPending() throws {
            guard !pendingChunks.isEmpty else { return }
            let entry = try buildEntry(from: pendingChunks)
            pendingChunks.removeAll()
            guard entries.count < limits.maximumEntryCount else { throw XP3Error.entryLimitExceeded }
            let folded = entry.relativePath.rawValue.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard foldedPaths.insert(folded).inserted else { throw XP3Error.duplicatePath }
            let addition = totalUncompressed.addingReportingOverflow(entry.uncompressedSize)
            guard !addition.overflow, addition.partialValue <= UInt64(limits.maximumExpandedByteCount) else {
                throw XP3Error.expandedSizeLimitExceeded
            }
            totalUncompressed = addition.partialValue
            entries.append(entry)
        }

        while cursor < table.count {
            guard table.count - cursor >= Self.recordHeaderByteCount else { throw XP3Error.truncatedTOC }
            var recordReader = ByteReader(data: table, startIndex: cursor)
            let adler = try recordReader.readUInt32()
            let tagData = try recordReader.readData(count: 4)
            guard let tag = String(data: tagData, encoding: .ascii) else { throw XP3Error.invalidArchive }
            let payloadSize = try recordReader.readUInt64()
            let payloadStart = cursor + Self.recordHeaderByteCount
            guard payloadSize <= UInt64(table.count - payloadStart) else { throw XP3Error.truncatedTOC }

            let payload = table.subdata(in: payloadStart..<(payloadStart + Int(payloadSize)))
            guard Self.adler32(of: tagData + payload) == adler else { throw XP3Error.invalidArchive }

            if tag == "info" {
                try flushPending()
            }
            pendingChunks.append(Chunk(tag: tag, payload: payload))
            cursor = payloadStart + Int(payloadSize)
        }
        try flushPending()
        return entries
    }

    private func buildEntry(from chunks: [Chunk]) throws -> XP3Entry {
        var name: String?
        var protectFlag: UInt32?
        var compressionFlag: UInt32?
        var dataOffset: UInt64?
        var originalSize: UInt64?
        var archivedSize: UInt64?

        for chunk in chunks {
            var reader = ByteReader(data: chunk.payload)
            switch chunk.tag {
            case "info":
                protectFlag = try reader.readUInt32()
                _ = try reader.readUInt64()
                let nameLength = Int(try reader.readUInt16())
                guard nameLength > 0, nameLength % 2 == 0, reader.remaining >= nameLength else {
                    throw XP3Error.invalidArchive
                }
                let nameData = try reader.readData(count: nameLength)
                name = String(data: nameData, encoding: .utf16LittleEndian)
            case "file":
                compressionFlag = try reader.readUInt32()
                dataOffset = try reader.readUInt64()
                originalSize = try reader.readUInt64()
                archivedSize = try reader.readUInt64()
            default:
                continue
            }
        }

        guard let name, !name.isEmpty,
              let protectFlag,
              let compressionFlag,
              let dataOffset,
              let originalSize,
              let archivedSize
        else { throw XP3Error.invalidArchive }
        guard compressionFlag == 0 || compressionFlag == 1 else {
            throw XP3Error.invalidArchive
        }

        let normalized = name.replacingOccurrences(of: "\\", with: "/")
        guard normalized.utf8.count <= limits.maximumPathByteCount else { throw XP3Error.pathLimitExceeded }
        guard let relativePath = try? StorageRelativePath(rawValue: normalized) else {
            throw XP3Error.unsafePath
        }
        return XP3Entry(
            relativePath: relativePath,
            uncompressedSize: originalSize,
            archivedSize: archivedSize,
            dataOffset: dataOffset,
            isProtected: protectFlag != 0,
            isCompressed: compressionFlag == 1
        )
    }

    private func requireBytes(_ handle: FileHandle, count: Int) throws -> [UInt8] {
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw XP3Error.truncatedTOC
        }
        return [UInt8](data)
    }

    private static func adler32(of data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return (b << 16) | a
    }
}

private struct ByteReader {
    let data: Data
    private(set) var offset: Int

    init(data: Data, startIndex: Int = 0) {
        self.data = data
        self.offset = startIndex
    }

    var remaining: Int { data.count - offset }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readData(count: 2)
        return UInt16(bytes[bytes.startIndex]) | UInt16(bytes[bytes.startIndex + 1]) << 8
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(bytes[bytes.startIndex + index]) << (8 * UInt32(index))
        }
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readData(count: 8)
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[bytes.startIndex + index]) << (8 * UInt64(index))
        }
        return value
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw XP3Error.invalidArchive }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
}
