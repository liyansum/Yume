import Foundation
import YumeDomain

public enum RGSSADError: Error, Equatable, Sendable {
    case sourceIsNotFileURL
    case sourceMissing
    case sourceIsSymbolicLink
    case magicMismatch
    case versionThreeUnsupported
    case truncatedIndex
    case unsafePath
    case duplicatePath
    case entryLimitExceeded
    case pathLimitExceeded
    case expandedSizeLimitExceeded
    case outOfBounds
    case destinationAlreadyExists
}

public struct RGSSADLimits: Sendable, Equatable {
    public let maximumEntryCount: Int
    public let maximumPathByteCount: Int
    public let maximumExpandedByteCount: Int64

    public init(
        maximumEntryCount: Int = 100_000,
        maximumPathByteCount: Int = 1_024,
        maximumExpandedByteCount: Int64 = 4 * 1_073_741_824
    ) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumPathByteCount = maximumPathByteCount
        self.maximumExpandedByteCount = maximumExpandedByteCount
    }
}

public struct RGSSADEntry: Sendable, Equatable {
    public let relativePath: StorageRelativePath
    public let offset: UInt64
    public let byteCount: UInt64

    public init(relativePath: StorageRelativePath, offset: UInt64, byteCount: UInt64) {
        self.relativePath = relativePath
        self.offset = offset
        self.byteCount = byteCount
    }
}

public struct RGSSArchive: Sendable {
    private static let headerV1: [UInt8] = Array("RGSSAD\0\u{01}".utf8)
    private static let headerPrefix: [UInt8] = Array("RGSSAD\0".utf8)
    private static let initialKey: UInt32 = 0xDEAD_CAFE
    private static let copyBufferByteCount = 65_536

    private let limits: RGSSADLimits

    public init(limits: RGSSADLimits = RGSSADLimits()) {
        self.limits = limits
    }

    public func index(at url: URL) throws -> [RGSSADEntry] {
        guard url.isFileURL else { throw RGSSADError.sourceIsNotFileURL }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw RGSSADError.sourceIsSymbolicLink }
        guard values.isRegularFile == true else { throw RGSSADError.sourceMissing }

        let fileSize = UInt64(values.fileSize ?? 0)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: Self.headerV1.count),
              [UInt8](header) == Self.headerV1
        else {
            try handle.seek(toOffset: 0)
            if let raw = try handle.read(upToCount: 8), [UInt8](raw.prefix(7)) == Self.headerPrefix,
               raw[raw.startIndex + 7] == 0x03
            {
                throw RGSSADError.versionThreeUnsupported
            }
            throw RGSSADError.magicMismatch
        }

        var reader = SequentialReader(handle: handle)
        var key = Self.initialKey

        var entries: [RGSSADEntry] = []
        var foldedPaths: Set<String> = []
        var totalByteCount: UInt64 = 0
        var minimumDataOffset = UInt64(Self.headerV1.count)

        while true {
            guard reader.hasBytes else { break }
            do {
                let rawNameLength = try reader.readUInt32(key: &key)
                key = key &* 7 &+ 3
                let nameLength = Int(rawNameLength)
                guard nameLength > 0, nameLength <= limits.maximumPathByteCount else {
                    break
                }

                var nameBytes = [UInt8]()
                nameBytes.reserveCapacity(nameLength)
                for _ in 0..<nameLength {
                    let byte = try reader.readByte()
                    nameBytes.append(byte ^ UInt8(truncatingIfNeeded: key & 0xFF))
                    key = key &* 7 &+ 3
                }
                guard let name = String(bytes: nameBytes, encoding: .utf8)?
                    .replacingOccurrences(of: "\\", with: "/")
                else { break }

                let rawOffset = try reader.readUInt32(key: &key)
                key = key &* 7 &+ 3
                let rawSize = try reader.readUInt32(key: &key)
                key = key &* 7 &+ 3

                let offset = UInt64(rawOffset)
                let size = UInt64(rawSize)

                guard offset >= minimumDataOffset,
                      size > 0,
                      offset < fileSize,
                      size <= fileSize - offset,
                      name.utf8.count <= limits.maximumPathByteCount,
                      let relativePath = try? StorageRelativePath(rawValue: name)
                else { break }

                let folded = name.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                guard foldedPaths.insert(folded).inserted else { throw RGSSADError.duplicatePath }
                guard entries.count < limits.maximumEntryCount else { throw RGSSADError.entryLimitExceeded }

                let addition = totalByteCount.addingReportingOverflow(size)
                guard !addition.overflow,
                      addition.partialValue <= UInt64(limits.maximumExpandedByteCount)
                else { throw RGSSADError.expandedSizeLimitExceeded }
                totalByteCount = addition.partialValue

                entries.append(
                    RGSSADEntry(relativePath: relativePath, offset: offset, byteCount: size)
                )
                minimumDataOffset = offset + size
            } catch let error as RGSSADError {
                throw error
            } catch {
                break
            }
        }

        guard !entries.isEmpty else { throw RGSSADError.truncatedIndex }
        return entries
    }

    public func extract(_ entry: RGSSADEntry, from sourceURL: URL, to destinationURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw RGSSADError.destinationAlreadyExists
        }
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }
        do {
            let fileSize = try UInt64(handle.seekToEnd())
            guard entry.offset < fileSize, entry.byteCount <= fileSize - entry.offset else {
                throw RGSSADError.outOfBounds
            }
            try handle.seek(toOffset: entry.offset)
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: destinationURL)
            defer { try? output.close() }

            var remaining = entry.byteCount
            while remaining > 0 {
                let requested = Int(min(UInt64(Self.copyBufferByteCount), remaining))
                guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else {
                    throw RGSSADError.outOfBounds
                }
                try output.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }
}

private struct SequentialReader {
    let handle: FileHandle
    private var buffer: [UInt8] = []
    private var position = 0
    private var exhausted = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    var hasBytes: Bool {
        if position < buffer.count { return true }
        refill()
        return position < buffer.count
    }

    mutating func readByte() throws -> UInt8 {
        if position >= buffer.count {
            refill()
            guard position < buffer.count else { throw RGSSADError.truncatedIndex }
        }
        defer { position += 1 }
        return buffer[position]
    }

    mutating func readUInt32(key: inout UInt32) throws -> UInt32 {
        var value: UInt32 = 0
        for shift in 0..<4 {
            let byte = try readByte()
            value |= UInt32(byte) << (8 * UInt32(shift))
        }
        return value ^ key
    }

    private mutating func refill() {
        guard !exhausted else { return }
        if position > 0 {
            buffer.removeSubrange(..<position)
            position = 0
        }
        guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else {
            exhausted = true
            return
        }
        buffer.append(contentsOf: [UInt8](chunk))
    }
}
