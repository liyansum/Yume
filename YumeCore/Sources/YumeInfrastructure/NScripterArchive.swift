import Foundation
import YumeDomain

public struct NSArcEntry: Sendable, Equatable {
    public let relativePath: StorageRelativePath
    public let offset: UInt64
    public let byteCount: UInt64
    public let isCompressed: Bool

    public init(
        relativePath: StorageRelativePath,
        offset: UInt64,
        byteCount: UInt64,
        isCompressed: Bool
    ) {
        self.relativePath = relativePath
        self.offset = offset
        self.byteCount = byteCount
        self.isCompressed = isCompressed
    }
}

public enum NSArcError: Error, Equatable, Sendable {
    case sourceIsNotFileURL
    case sourceMissing
    case sourceIsSymbolicLink
    case invalidArchive
    case magicMismatch
    case truncatedDirectory
    case unsupportedEncryption
    case unsafePath
    case duplicatePath
    case entryLimitExceeded
    case pathLimitExceeded
    case expandedSizeLimitExceeded
    case outOfBounds
    case destinationAlreadyExists
}

public struct NScripterArchive: Sendable {
    public enum FormatKind: String, Sendable {
        case sar = "SAR"
        case nsa = "NSA"
        case ns2 = "NS2"
    }

    public struct Limits: Sendable, Equatable {
        public let maximumEntryCount: Int
        public let maximumPathByteCount: Int
        public let maximumExpandedByteCount: Int64

        public init(
            maximumEntryCount: Int = 20_000,
            maximumPathByteCount: Int = 256,
            maximumExpandedByteCount: Int64 = 4 * 1_073_741_824
        ) {
            self.maximumEntryCount = maximumEntryCount
            self.maximumPathByteCount = maximumPathByteCount
            self.maximumExpandedByteCount = maximumExpandedByteCount
        }
    }

    private static let knownMagics: [FormatKind] = [.sar, .nsa, .ns2]
    private static let headerByteCount = 5
    private static let nameFieldByteCount = 16
    private static let recordByteCount = 24
    private static let compressionFlagMask: UInt32 = 0x8000_0000
    private static let copyBufferByteCount = 65_536

    private let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public static func sniffKind(at url: URL) throws -> FormatKind {
        let handle = try openValidatedSource(url)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 3) ?? Data()
        return try formatKind(for: magic)
    }

    public func index(at url: URL) throws -> [NSArcEntry] {
        let handle = try Self.openValidatedSource(url)
        defer { try? handle.close() }
        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
        } catch {
            throw NSArcError.sourceMissing
        }
        guard fileSize >= UInt64(Self.headerByteCount) else { throw NSArcError.truncatedDirectory }

        let header = try Self.read(handle: handle, byteCount: Self.headerByteCount)
        _ = try Self.formatKind(for: header.prefix(3))
        var headerReader = DirectoryReader(data: header)
        try headerReader.skip(3)
        let declaredEntryCount = Int(try headerReader.readUInt16())
        guard declaredEntryCount <= limits.maximumEntryCount else { throw NSArcError.entryLimitExceeded }

        let directoryByteCount = Self.recordByteCount * declaredEntryCount
        guard UInt64(Self.headerByteCount + directoryByteCount) <= fileSize else {
            throw NSArcError.truncatedDirectory
        }
        let records = try Self.read(handle: handle, byteCount: directoryByteCount)
        var reader = DirectoryReader(data: records)

        var entries: [NSArcEntry] = []
        entries.reserveCapacity(declaredEntryCount)
        var foldedPaths: Set<String> = []
        var totalByteCount: UInt64 = 0

        for _ in 0..<declaredEntryCount {
            let nameField = try reader.readData(count: Self.nameFieldByteCount)
            let rawOffset = try reader.readUInt32()
            let rawSize = try reader.readUInt32()
            let isCompressed = rawOffset & Self.compressionFlagMask != 0
                || rawSize & Self.compressionFlagMask != 0
            let offset = UInt64(rawOffset & ~Self.compressionFlagMask)
            let byteCount = UInt64(rawSize & ~Self.compressionFlagMask)

            let nameBytes = nameField.prefix { $0 != 0 }
            guard !nameBytes.isEmpty, nameBytes.allSatisfy({ $0 < 0x80 }) else {
                throw NSArcError.invalidArchive
            }
            guard nameBytes.count <= limits.maximumPathByteCount else {
                throw NSArcError.pathLimitExceeded
            }
            let name = String(decoding: nameBytes, as: UTF8.self)
            let relativePath: StorageRelativePath
            do {
                relativePath = try StorageRelativePath(rawValue: name)
            } catch {
                throw NSArcError.unsafePath
            }
            let folded = name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard foldedPaths.insert(folded).inserted else { throw NSArcError.duplicatePath }

            let end = offset.addingReportingOverflow(byteCount)
            guard !end.overflow, end.partialValue <= fileSize else { throw NSArcError.outOfBounds }

            let addition = totalByteCount.addingReportingOverflow(byteCount)
            guard !addition.overflow,
                  addition.partialValue <= UInt64(limits.maximumExpandedByteCount)
            else { throw NSArcError.expandedSizeLimitExceeded }
            totalByteCount = addition.partialValue

            entries.append(
                NSArcEntry(
                    relativePath: relativePath,
                    offset: offset,
                    byteCount: byteCount,
                    isCompressed: isCompressed
                )
            )
        }
        return entries
    }

    public func extract(_ entry: NSArcEntry, from sourceURL: URL, to destinationURL: URL) throws {
        guard !entry.isCompressed else { throw NSArcError.unsupportedEncryption }
        guard sourceURL.isFileURL, destinationURL.isFileURL else {
            throw NSArcError.sourceIsNotFileURL
        }
        guard destinationURL.standardizedFileURL.path != sourceURL.standardizedFileURL.path else {
            throw NSArcError.unsafePath
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw NSArcError.destinationAlreadyExists
        }

        let handle = try Self.openValidatedSource(sourceURL)
        defer { try? handle.close() }
        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
        } catch {
            throw NSArcError.sourceMissing
        }
        let end = entry.offset.addingReportingOverflow(entry.byteCount)
        guard !end.overflow, end.partialValue <= fileSize else { throw NSArcError.outOfBounds }
        try handle.seek(toOffset: entry.offset)

        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard FileManager.default.createFile(atPath: destinationURL.path, contents: Data()) else {
                throw NSArcError.invalidArchive
            }
            let output = try FileHandle(forWritingTo: destinationURL)
            defer { try? output.close() }

            var copied: UInt64 = 0
            while copied < entry.byteCount {
                try Task.checkCancellation()
                let requested = Int(min(
                    UInt64(Self.copyBufferByteCount),
                    entry.byteCount - copied
                ))
                guard let chunk = try handle.read(upToCount: requested),
                      !chunk.isEmpty
                else { break }
                let moved = copied.addingReportingOverflow(UInt64(chunk.count))
                guard !moved.overflow, moved.partialValue <= entry.byteCount else {
                    throw NSArcError.outOfBounds
                }
                copied = moved.partialValue
                try output.write(contentsOf: chunk)
            }
            guard copied == entry.byteCount else { throw NSArcError.outOfBounds }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private static func openValidatedSource(_ url: URL) throws -> FileHandle {
        guard url.isFileURL else { throw NSArcError.sourceIsNotFileURL }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { throw NSArcError.sourceIsSymbolicLink }
        guard values?.isRegularFile == true else { throw NSArcError.sourceMissing }
        do {
            return try FileHandle(forReadingFrom: url)
        } catch {
            throw NSArcError.sourceMissing
        }
    }

    private static func formatKind(for magic: Data) throws -> FormatKind {
        guard magic.count == 3,
              let match = knownMagics.first(where: { kind in Data(kind.rawValue.utf8) == magic })
        else { throw NSArcError.magicMismatch }
        return match
    }

    private static func read(handle: FileHandle, byteCount: Int) throws -> Data {
        guard byteCount > 0 else { return Data() }
        guard let data = try handle.read(upToCount: byteCount), data.count == byteCount else {
            throw NSArcError.truncatedDirectory
        }
        return data
    }
}

private struct DirectoryReader {
    let data: Data
    private(set) var offset = 0

    var remaining: Int { data.count - offset }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = [UInt8](try readData(count: 2))
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = [UInt8](try readData(count: 4))
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw NSArcError.truncatedDirectory }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func skip(_ count: Int) throws {
        _ = try readData(count: count)
    }
}
