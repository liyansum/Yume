import CYumeZlib
import Foundation
import YumeDomain

public struct ZIPArchiveInspection: Sendable, Equatable {
    public let entryCount: Int
    public let fileCount: Int
    public let compressedByteCount: Int64
    public let uncompressedByteCount: Int64
    public let containsEncryptedEntries: Bool

    public init(
        entryCount: Int,
        fileCount: Int,
        compressedByteCount: Int64,
        uncompressedByteCount: Int64,
        containsEncryptedEntries: Bool
    ) {
        self.entryCount = entryCount
        self.fileCount = fileCount
        self.compressedByteCount = compressedByteCount
        self.uncompressedByteCount = uncompressedByteCount
        self.containsEncryptedEntries = containsEncryptedEntries
    }
}

public enum SafeZIPError: Error, Equatable, Sendable {
    case sourceIsNotFileURL
    case sourceMissing
    case sourceIsSymbolicLink
    case invalidArchive
    case multiDiskArchiveUnsupported
    case encryptedEntryUnsupported
    case unsupportedCompressionMethod(UInt16)
    case unsupportedFilenameEncoding
    case unsafePath
    case symbolicLinkEntry
    case duplicatePath
    case entryLimitExceeded
    case pathLimitExceeded
    case expandedSizeLimitExceeded
    case compressionRatioLimitExceeded
    case destinationAlreadyExists
    case extractionFailed(Int32)
}

public struct SafeZIPExtractor: Sendable {
    public struct Limits: Sendable, Equatable {
        public let maximumEntryCount: Int
        public let maximumPathByteCount: Int
        public let maximumExpandedByteCount: Int64
        public let maximumEntryCompressionRatio: Int64
        public let maximumOverallCompressionRatio: Int64

        public init(
            maximumEntryCount: Int = 250_000,
            maximumPathByteCount: Int = 1_024,
            maximumExpandedByteCount: Int64 = 100 * 1_073_741_824,
            maximumEntryCompressionRatio: Int64 = 1_000,
            maximumOverallCompressionRatio: Int64 = 200
        ) {
            self.maximumEntryCount = maximumEntryCount
            self.maximumPathByteCount = maximumPathByteCount
            self.maximumExpandedByteCount = maximumExpandedByteCount
            self.maximumEntryCompressionRatio = maximumEntryCompressionRatio
            self.maximumOverallCompressionRatio = maximumOverallCompressionRatio
        }
    }

    private let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public func inspect(_ sourceURL: URL) throws -> ZIPArchiveInspection {
        let archive = try parse(sourceURL)
        return ZIPArchiveInspection(
            entryCount: archive.entries.count,
            fileCount: archive.entries.filter { !$0.isDirectory }.count,
            compressedByteCount: archive.entries.reduce(0) { $0 + Int64($1.compressedSize) },
            uncompressedByteCount: archive.entries.reduce(0) { $0 + Int64($1.uncompressedSize) },
            containsEncryptedEntries: archive.entries.contains { $0.isEncrypted }
        )
    }

    public func extract(_ sourceURL: URL, to destinationURL: URL) throws -> ZIPArchiveInspection {
        let archive = try parse(sourceURL)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw SafeZIPError.destinationAlreadyExists
        }
        guard !archive.entries.contains(where: \.isEncrypted) else {
            throw SafeZIPError.encryptedEntryUnsupported
        }

        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        do {
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? handle.close() }

            for entry in archive.entries {
                try Task.checkCancellation()
                let outputURL = destinationURL.appendingPathComponent(
                    entry.relativePath.rawValue,
                    isDirectory: entry.isDirectory
                )
                if entry.isDirectory {
                    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
                    continue
                }

                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let dataOffset = try localDataOffset(for: entry, handle: handle, fileSize: archive.fileSize)
                let result = sourceURL.path.withCString { sourcePath in
                    outputURL.path.withCString { outputPath in
                        yume_zip_extract_entry(
                            sourcePath,
                            dataOffset,
                            entry.compressedSize,
                            entry.compressionMethod,
                            outputPath,
                            entry.uncompressedSize,
                            entry.crc32
                        )
                    }
                }
                guard result == YUME_ZIP_OK else {
                    throw SafeZIPError.extractionFailed(result)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }

        return ZIPArchiveInspection(
            entryCount: archive.entries.count,
            fileCount: archive.entries.filter { !$0.isDirectory }.count,
            compressedByteCount: archive.entries.reduce(0) { $0 + Int64($1.compressedSize) },
            uncompressedByteCount: archive.entries.reduce(0) { $0 + Int64($1.uncompressedSize) },
            containsEncryptedEntries: false
        )
    }

    private struct Archive {
        let fileSize: UInt64
        let centralDirectoryOffset: UInt64
        let entries: [Entry]
    }

    private struct Entry {
        let relativePath: StorageRelativePath
        let compressionMethod: UInt16
        let flags: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let isDirectory: Bool

        var isEncrypted: Bool { flags & 0x0001 != 0 || flags & 0x0040 != 0 }
    }

    private func parse(_ sourceURL: URL) throws -> Archive {
        guard sourceURL.isFileURL else { throw SafeZIPError.sourceIsNotFileURL }
        let values = try sourceURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isSymbolicLink != true else { throw SafeZIPError.sourceIsSymbolicLink }
        guard values.isRegularFile == true, let integerFileSize = values.fileSize else {
            throw SafeZIPError.sourceMissing
        }
        let fileSize = UInt64(integerFileSize)
        guard fileSize >= 22 else { throw SafeZIPError.invalidArchive }

        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }
        let endRecord = try findEndRecord(handle: handle, fileSize: fileSize)
        let directory = try readCentralDirectoryLocation(
            endRecord: endRecord,
            handle: handle,
            fileSize: fileSize
        )
        guard directory.entryCount <= limits.maximumEntryCount,
              directory.byteCount <= 128 * 1_024 * 1_024,
              directory.offset <= fileSize,
              directory.byteCount <= fileSize - directory.offset
        else { throw SafeZIPError.entryLimitExceeded }

        try handle.seek(toOffset: directory.offset)
        let centralData = try handle.read(upToCount: Int(directory.byteCount)) ?? Data()
        guard centralData.count == Int(directory.byteCount) else { throw SafeZIPError.invalidArchive }
        var reader = ByteReader(data: centralData)
        var entries: [Entry] = []
        var foldedPaths: Set<String> = []
        var totalCompressed: UInt64 = 0
        var totalUncompressed: UInt64 = 0

        for _ in 0..<directory.entryCount {
            guard try reader.readUInt32() == 0x02014b50 else { throw SafeZIPError.invalidArchive }
            let versionMadeBy = try reader.readUInt16()
            _ = try reader.readUInt16()
            let flags = try reader.readUInt16()
            let method = try reader.readUInt16()
            guard method == 0 || method == 8 else {
                throw SafeZIPError.unsupportedCompressionMethod(method)
            }
            try reader.skip(4)
            let crc32 = try reader.readUInt32()
            let compressed32 = try reader.readUInt32()
            let uncompressed32 = try reader.readUInt32()
            let nameLength = Int(try reader.readUInt16())
            let extraLength = Int(try reader.readUInt16())
            let commentLength = Int(try reader.readUInt16())
            let diskStart32 = try reader.readUInt16()
            try reader.skip(2)
            let externalAttributes = try reader.readUInt32()
            let localOffset32 = try reader.readUInt32()
            let nameData = try reader.readData(count: nameLength)
            let extraData = try reader.readData(count: extraLength)
            try reader.skip(commentLength)

            let name = try decodedName(nameData, flags: flags)
            let directoryEntry = name.hasSuffix("/")
            let trimmedName = directoryEntry ? String(name.dropLast()) : name
            guard !trimmedName.isEmpty,
                  trimmedName.utf8.count <= limits.maximumPathByteCount,
                  !trimmedName.contains("\\")
            else { throw SafeZIPError.pathLimitExceeded }
            let relativePath: StorageRelativePath
            do {
                relativePath = try StorageRelativePath(rawValue: trimmedName)
            } catch {
                throw SafeZIPError.unsafePath
            }
            let folded = trimmedName.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard foldedPaths.insert(folded).inserted else { throw SafeZIPError.duplicatePath }

            let zip64 = try zip64Values(
                extraData,
                needsUncompressed: uncompressed32 == UInt32.max,
                needsCompressed: compressed32 == UInt32.max,
                needsOffset: localOffset32 == UInt32.max,
                needsDisk: diskStart32 == UInt16.max
            )
            let compressed = compressed32 == UInt32.max ? try required(zip64.compressed) : UInt64(compressed32)
            let uncompressed = uncompressed32 == UInt32.max ? try required(zip64.uncompressed) : UInt64(uncompressed32)
            let localOffset = localOffset32 == UInt32.max ? try required(zip64.offset) : UInt64(localOffset32)
            let diskStart = diskStart32 == UInt16.max ? zip64.disk ?? 0 : UInt32(diskStart32)
            guard diskStart == 0 else { throw SafeZIPError.multiDiskArchiveUnsupported }

            let unixMode = UInt16((externalAttributes >> 16) & 0xffff)
            if versionMadeBy >> 8 == 3, unixMode & 0xf000 == 0xa000 {
                throw SafeZIPError.symbolicLinkEntry
            }
            if !directoryEntry, compressed == 0, uncompressed > 0 {
                throw SafeZIPError.invalidArchive
            }
            if !directoryEntry, compressed > 0,
               uncompressed / compressed > UInt64(limits.maximumEntryCompressionRatio) {
                throw SafeZIPError.compressionRatioLimitExceeded
            }
            let compressedAddition = totalCompressed.addingReportingOverflow(compressed)
            let uncompressedAddition = totalUncompressed.addingReportingOverflow(uncompressed)
            guard !compressedAddition.overflow, !uncompressedAddition.overflow else {
                throw SafeZIPError.expandedSizeLimitExceeded
            }
            totalCompressed = compressedAddition.partialValue
            totalUncompressed = uncompressedAddition.partialValue
            guard totalUncompressed <= UInt64(limits.maximumExpandedByteCount) else {
                throw SafeZIPError.expandedSizeLimitExceeded
            }

            entries.append(
                Entry(
                    relativePath: relativePath,
                    compressionMethod: method,
                    flags: flags,
                    crc32: crc32,
                    compressedSize: compressed,
                    uncompressedSize: uncompressed,
                    localHeaderOffset: localOffset,
                    isDirectory: directoryEntry
                )
            )
        }

        if totalCompressed > 0,
           totalUncompressed / totalCompressed > UInt64(limits.maximumOverallCompressionRatio) {
            throw SafeZIPError.compressionRatioLimitExceeded
        }
        return Archive(
            fileSize: fileSize,
            centralDirectoryOffset: directory.offset,
            entries: entries
        )
    }

    private struct EndRecord {
        let offset: UInt64
        let data: Data
    }

    private struct DirectoryLocation {
        let entryCount: Int
        let byteCount: UInt64
        let offset: UInt64
    }

    private func findEndRecord(handle: FileHandle, fileSize: UInt64) throws -> EndRecord {
        let searchLength = min(fileSize, UInt64(65_557))
        let searchOffset = fileSize - searchLength
        try handle.seek(toOffset: searchOffset)
        let data = try handle.read(upToCount: Int(searchLength)) ?? Data()
        guard data.count == Int(searchLength) else { throw SafeZIPError.invalidArchive }
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw SafeZIPError.invalidArchive }
        for index in stride(from: bytes.count - 22, through: 0, by: -1) {
            guard bytes[index] == 0x50, bytes[index + 1] == 0x4b,
                  bytes[index + 2] == 0x05, bytes[index + 3] == 0x06
            else { continue }
            let commentLength = Int(bytes[index + 20]) | Int(bytes[index + 21]) << 8
            guard index + 22 + commentLength == bytes.count else { continue }
            return EndRecord(offset: searchOffset + UInt64(index), data: Data(bytes[index...]))
        }
        throw SafeZIPError.invalidArchive
    }

    private func readCentralDirectoryLocation(
        endRecord: EndRecord,
        handle: FileHandle,
        fileSize: UInt64
    ) throws -> DirectoryLocation {
        var reader = ByteReader(data: endRecord.data)
        guard try reader.readUInt32() == 0x06054b50 else { throw SafeZIPError.invalidArchive }
        let disk = try reader.readUInt16()
        let directoryDisk = try reader.readUInt16()
        let entriesOnDisk = try reader.readUInt16()
        let entries = try reader.readUInt16()
        let byteCount32 = try reader.readUInt32()
        let offset32 = try reader.readUInt32()
        guard disk == 0, directoryDisk == 0, entriesOnDisk == entries else {
            throw SafeZIPError.multiDiskArchiveUnsupported
        }

        let needsZip64 = entries == UInt16.max || byteCount32 == UInt32.max || offset32 == UInt32.max
        guard needsZip64 else {
            return DirectoryLocation(
                entryCount: Int(entries),
                byteCount: UInt64(byteCount32),
                offset: UInt64(offset32)
            )
        }
        guard endRecord.offset >= 20 else { throw SafeZIPError.invalidArchive }
        try handle.seek(toOffset: endRecord.offset - 20)
        let locatorData = try handle.read(upToCount: 20) ?? Data()
        var locator = ByteReader(data: locatorData)
        guard try locator.readUInt32() == 0x07064b50,
              try locator.readUInt32() == 0
        else { throw SafeZIPError.invalidArchive }
        let zip64Offset = try locator.readUInt64()
        guard try locator.readUInt32() == 1, zip64Offset < fileSize else {
            throw SafeZIPError.multiDiskArchiveUnsupported
        }
        try handle.seek(toOffset: zip64Offset)
        let zip64Data = try handle.read(upToCount: 56) ?? Data()
        var zip64 = ByteReader(data: zip64Data)
        guard try zip64.readUInt32() == 0x06064b50 else { throw SafeZIPError.invalidArchive }
        _ = try zip64.readUInt64()
        try zip64.skip(4)
        guard try zip64.readUInt32() == 0, try zip64.readUInt32() == 0 else {
            throw SafeZIPError.multiDiskArchiveUnsupported
        }
        let entriesOnDisk64 = try zip64.readUInt64()
        let entries64 = try zip64.readUInt64()
        guard entriesOnDisk64 == entries64, entries64 <= UInt64(Int.max) else {
            throw SafeZIPError.multiDiskArchiveUnsupported
        }
        return DirectoryLocation(
            entryCount: Int(entries64),
            byteCount: try zip64.readUInt64(),
            offset: try zip64.readUInt64()
        )
    }

    private func localDataOffset(for entry: Entry, handle: FileHandle, fileSize: UInt64) throws -> UInt64 {
        guard entry.localHeaderOffset <= fileSize, 30 <= fileSize - entry.localHeaderOffset else {
            throw SafeZIPError.invalidArchive
        }
        try handle.seek(toOffset: entry.localHeaderOffset)
        let data = try handle.read(upToCount: 30) ?? Data()
        var reader = ByteReader(data: data)
        guard try reader.readUInt32() == 0x04034b50 else { throw SafeZIPError.invalidArchive }
        try reader.skip(2)
        let localFlags = try reader.readUInt16()
        let localMethod = try reader.readUInt16()
        try reader.skip(16)
        let nameLength = UInt64(try reader.readUInt16())
        let extraLength = UInt64(try reader.readUInt16())
        guard localFlags == entry.flags, localMethod == entry.compressionMethod else {
            throw SafeZIPError.invalidArchive
        }
        let headerSize = UInt64(30) + nameLength + extraLength
        guard headerSize <= fileSize - entry.localHeaderOffset else { throw SafeZIPError.invalidArchive }
        let offset = entry.localHeaderOffset + headerSize
        guard entry.compressedSize <= fileSize - offset else { throw SafeZIPError.invalidArchive }
        return offset
    }

    private struct Zip64Values {
        var uncompressed: UInt64?
        var compressed: UInt64?
        var offset: UInt64?
        var disk: UInt32?
    }

    private func zip64Values(
        _ data: Data,
        needsUncompressed: Bool,
        needsCompressed: Bool,
        needsOffset: Bool,
        needsDisk: Bool
    ) throws -> Zip64Values {
        var reader = ByteReader(data: data)
        while reader.remaining >= 4 {
            let identifier = try reader.readUInt16()
            let size = Int(try reader.readUInt16())
            let field = try reader.readData(count: size)
            guard identifier == 0x0001 else { continue }
            var zip64 = ByteReader(data: field)
            var result = Zip64Values()
            if needsUncompressed { result.uncompressed = try zip64.readUInt64() }
            if needsCompressed { result.compressed = try zip64.readUInt64() }
            if needsOffset { result.offset = try zip64.readUInt64() }
            if needsDisk { result.disk = try zip64.readUInt32() }
            return result
        }
        return Zip64Values()
    }

    private func required<T>(_ value: T?) throws -> T {
        guard let value else { throw SafeZIPError.invalidArchive }
        return value
    }

    private func decodedName(_ data: Data, flags: UInt16) throws -> String {
        if let value = String(data: data, encoding: .utf8) { return value }
        if flags & 0x0800 == 0, data.allSatisfy({ $0 < 0x80 }) {
            return String(decoding: data, as: UTF8.self)
        }
        throw SafeZIPError.unsupportedFilenameEncoding
    }
}

private struct ByteReader {
    let data: Data
    private(set) var offset = 0

    var remaining: Int { data.count - offset }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = [UInt8](try readData(count: 2))
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = [UInt8](try readData(count: 4))
        let lower = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
        let upper = UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        return lower | upper
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readData(count: 8)
        return bytes.enumerated().reduce(UInt64(0)) { result, item in
            result | UInt64(item.element) << UInt64(item.offset * 8)
        }
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw SafeZIPError.invalidArchive }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func skip(_ count: Int) throws {
        _ = try readData(count: count)
    }
}
