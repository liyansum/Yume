import CLibarchive
import CYumeZlib
import Foundation
import YumeDomain

public struct RARArchiveInspection: Sendable, Equatable {
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

public enum SafeRARError: Error, Equatable, Sendable {
    case sourceIsNotFileURL
    case sourceMissing
    case sourceIsSymbolicLink
    case invalidArchive
    case encryptedArchiveUnsupported
    case unsafePath
    case symbolicLinkEntry
    case duplicatePath
    case entryLimitExceeded
    case pathLimitExceeded
    case expandedSizeLimitExceeded
    case compressionRatioLimitExceeded
    case destinationAlreadyExists
    case extractionFailed
}

/// Read-only RAR/RAR5 extractor around the vendored libarchive readers.
/// Encrypted RAR is detected and rejected; Yume never uses UnRAR.
public struct SafeRARExtractor: Sendable {
    public struct Limits: Sendable, Equatable {
        public let maximumEntryCount: Int
        public let maximumPathByteCount: Int
        public let maximumExpandedByteCount: Int64
        public let maximumOverallCompressionRatio: Int64

        public init(
            maximumEntryCount: Int = 250_000,
            maximumPathByteCount: Int = 1_024,
            maximumExpandedByteCount: Int64 = 100 * 1_073_741_824,
            maximumOverallCompressionRatio: Int64 = 200
        ) {
            self.maximumEntryCount = maximumEntryCount
            self.maximumPathByteCount = maximumPathByteCount
            self.maximumExpandedByteCount = maximumExpandedByteCount
            self.maximumOverallCompressionRatio = maximumOverallCompressionRatio
        }
    }

    private struct ValidatedItem {
        let relativePath: StorageRelativePath
        let isDirectory: Bool
        let byteCount: Int64
    }

    private static let markerRAR4: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
    private static let markerRAR5: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01]
    private static let copyBufferByteCount = 65_536

    private let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public static func matchesRARMagic(at sourceURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: sourceURL) else { return false }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 8)) ?? Data()
        return matchesRARMagic(prefix)
    }

    public func inspect(_ sourceURL: URL) throws -> RARArchiveInspection {
        try walk(sourceURL, destinationURL: nil)
    }

    public func extract(
        _ sourceURL: URL,
        to destinationURL: URL
    ) throws -> RARArchiveInspection {
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw SafeRARError.destinationAlreadyExists
        }
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        do {
            return try walk(sourceURL, destinationURL: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private func walk(
        _ sourceURL: URL,
        destinationURL: URL?
    ) throws -> RARArchiveInspection {
        let sourceSize = try validatedSourceSize(sourceURL)
        let archive = try openArchive(sourceURL)
        defer { _ = archive_read_free(archive) }

        var foldedPaths: Set<String> = []
        var entryCount = 0
        var fileCount = 0
        var totalExpanded: Int64 = 0
        var sawEncryption = false

        while true {
            try Task.checkCancellation()
            var entry: OpaquePointer?
            let headerStatus = archive_read_next_header(archive, &entry)
            if headerStatus == ARCHIVE_EOF { break }
            guard headerStatus == ARCHIVE_OK || headerStatus == ARCHIVE_WARN, let entry else {
                throw mappedArchiveError(archive, fallback: .invalidArchive)
            }
            entryCount += 1
            guard entryCount <= limits.maximumEntryCount else { throw SafeRARError.entryLimitExceeded }

            if archive_entry_is_encrypted(entry) != 0 {
                sawEncryption = true
                throw SafeRARError.encryptedArchiveUnsupported
            }

            let fileType = UInt32(archive_entry_filetype(entry))
            if fileType == 0o120000 { throw SafeRARError.symbolicLinkEntry }
            let isDirectory = fileType == 0o040000
            let relativePath = try validatedPath(for: entry)
            let folded = relativePath.rawValue.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard foldedPaths.insert(folded).inserted else { throw SafeRARError.duplicatePath }

            let size = archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : 0
            if !isDirectory {
                fileCount += 1
                let addition = totalExpanded.addingReportingOverflow(size)
                guard !addition.overflow,
                      addition.partialValue <= limits.maximumExpandedByteCount
                else { throw SafeRARError.expandedSizeLimitExceeded }
                totalExpanded = addition.partialValue
            }

            if let destinationURL {
                let outputURL = destinationURL
                    .appendingPathComponent(relativePath.rawValue, isDirectory: isDirectory)
                    .standardizedFileURL
                guard outputURL.path.hasPrefix(destinationURL.standardizedFileURL.path + "/") else {
                    throw SafeRARError.unsafePath
                }
                if isDirectory {
                    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
                    _ = archive_read_data_skip(archive)
                } else {
                    try FileManager.default.createDirectory(
                        at: outputURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try writeEntry(archive, to: outputURL, expectedSize: size)
                }
            } else {
                _ = archive_read_data_skip(archive)
            }
        }

        if sourceSize > 0, totalExpanded / sourceSize > limits.maximumOverallCompressionRatio {
            throw SafeRARError.compressionRatioLimitExceeded
        }
        return RARArchiveInspection(
            entryCount: entryCount,
            fileCount: fileCount,
            compressedByteCount: sourceSize,
            uncompressedByteCount: totalExpanded,
            containsEncryptedEntries: sawEncryption
        )
    }

    private func validatedSourceSize(_ sourceURL: URL) throws -> Int64 {
        guard sourceURL.isFileURL else { throw SafeRARError.sourceIsNotFileURL }
        let values = try sourceURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isSymbolicLink != true else { throw SafeRARError.sourceIsSymbolicLink }
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw SafeRARError.sourceMissing
        }
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 8) ?? Data()
        guard Self.matchesRARMagic(prefix) else { throw SafeRARError.invalidArchive }
        return Int64(size)
    }

    private func openArchive(_ sourceURL: URL) throws -> OpaquePointer {
        guard let archive = archive_read_new() else { throw SafeRARError.invalidArchive }
        archive_read_support_filter_none(archive)
        archive_read_support_format_empty(archive)
        archive_read_support_format_rar(archive)
        archive_read_support_format_rar5(archive)
        let opened = sourceURL.path.withCString { path in
            archive_read_open_filename(archive, path, 16_384)
        }
        guard opened == ARCHIVE_OK else {
            archive_read_free(archive)
            throw mappedArchiveError(archive, fallback: .invalidArchive)
        }
        return archive
    }

    private func validatedPath(for entry: OpaquePointer) throws -> StorageRelativePath {
        let raw = pathname(for: entry)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !raw.isEmpty, raw.utf8.count <= limits.maximumPathByteCount else {
            throw SafeRARError.pathLimitExceeded
        }
        do {
            return try StorageRelativePath(rawValue: raw)
        } catch {
            throw SafeRARError.unsafePath
        }
    }

    private func pathname(for entry: OpaquePointer) -> String {
        if let utf8 = archive_entry_pathname_utf8(entry) {
            return String(cString: utf8)
        }
        if let bytes = archive_entry_pathname(entry) {
            var length = 0
            while bytes[length] != 0 { length += 1 }
            let data = Data(bytes: bytes, count: length)
            if let decoded = ArchiveFilenameDecoder.decode(data) {
                return decoded
            }
            return String(cString: bytes)
        }
        return "entry"
    }

    private func writeEntry(
        _ archive: OpaquePointer,
        to outputURL: URL,
        expectedSize: Int64
    ) throws {
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw SafeRARError.extractionFailed
        }
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        var written: Int64 = 0
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.copyBufferByteCount)
        defer { buffer.deallocate() }
        while true {
            let count = archive_read_data(archive, buffer, Self.copyBufferByteCount)
            if count == 0 { break }
            guard count > 0 else { throw mappedArchiveError(archive, fallback: .extractionFailed) }
            written += Int64(count)
            guard written <= limits.maximumExpandedByteCount else {
                throw SafeRARError.expandedSizeLimitExceeded
            }
            handle.write(Data(bytes: buffer, count: Int(count)))
        }
        if expectedSize > 0, written != expectedSize {
            throw SafeRARError.extractionFailed
        }
    }

    private func mappedArchiveError(
        _ archive: OpaquePointer,
        fallback: SafeRARError
    ) -> SafeRARError {
        let message = archive_error_string(archive).map { String(cString: $0).lowercased() } ?? ""
        if message.contains("password")
            || message.contains("encrypt")
            || message.contains("unsupported encryption") {
            return .encryptedArchiveUnsupported
        }
        return fallback
    }

    private static func matchesRARMagic(_ prefix: Data) -> Bool {
        let bytes = [UInt8](prefix)
        if bytes.starts(with: markerRAR4) { return true }
        if bytes.starts(with: markerRAR5) { return true }
        return false
    }
}

enum ArchiveFilenameDecoder {
    static func decode(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8),
           utf8.utf8.elementsEqual(data) {
            return utf8
        }
        var output = [UInt8](repeating: 0, count: max(8, data.count * 4 + 1))
        var length: UInt32 = 0
        let status = data.withUnsafeBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return -1
            }
            return output.withUnsafeMutableBufferPointer { outBuffer in
                outBuffer.baseAddress?.withMemoryRebound(to: CChar.self, capacity: outBuffer.count) { chars in
                    yume_decode_archive_filename(
                        base,
                        UInt32(data.count),
                        chars,
                        UInt32(outBuffer.count),
                        &length
                    )
                } ?? -1
            }
        }
        guard status == 0 else { return nil }
        return String(decoding: output.prefix(Int(length)), as: UTF8.self)
    }
}
