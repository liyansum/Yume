import Foundation
import PLzmaSDK
import YumeDomain

public struct SevenZipArchiveInspection: Sendable, Equatable {
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

public enum Safe7zError: Error, Equatable, Sendable {
    case sourceIsNotFileURL
    case sourceMissing
    case sourceIsSymbolicLink
    case invalidArchive
    case passwordRequired
    case incorrectPasswordOrCorruptArchive
    case unsafePath
    case duplicatePath
    case entryLimitExceeded
    case pathLimitExceeded
    case expandedSizeLimitExceeded
    case compressionRatioLimitExceeded
    case destinationAlreadyExists
    case extractionFailed
}

/// A constrained 7-Zip reader around the vendored PLzmaSDK. The upstream
/// decoder never chooses output paths: every item is validated first and is
/// then bound to an exact file stream under a newly-created destination.
public struct Safe7zExtractor: Sendable {
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
        let item: PLzmaSDK.Item
        let relativePath: StorageRelativePath
        let isDirectory: Bool
        let byteCount: UInt64
    }

    private struct OpenedArchive {
        let decoder: PLzmaSDK.Decoder
        let items: [ValidatedItem]
        let inspection: SevenZipArchiveInspection
    }

    private let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public func inspect(_ sourceURL: URL, password: String? = nil) throws -> SevenZipArchiveInspection {
        try open(sourceURL, password: password).inspection
    }

    public func extract(
        _ sourceURL: URL,
        to destinationURL: URL,
        password: String? = nil
    ) throws -> SevenZipArchiveInspection {
        let archive = try open(sourceURL, password: password)
        guard !archive.inspection.containsEncryptedEntries || password?.isEmpty == false else {
            throw Safe7zError.passwordRequired
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw Safe7zError.destinationAlreadyExists
        }

        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        do {
            let streams = try ItemOutStreamArray(capacity: Size(archive.inspection.fileCount))
            var expectedFiles: [(URL, UInt64)] = []

            for entry in archive.items {
                try Task.checkCancellation()
                let outputURL = destinationURL
                    .appendingPathComponent(entry.relativePath.rawValue, isDirectory: entry.isDirectory)
                    .standardizedFileURL
                guard outputURL.path.hasPrefix(destinationURL.standardizedFileURL.path + "/") else {
                    throw Safe7zError.unsafePath
                }
                if entry.isDirectory {
                    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
                    continue
                }
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let outputStream = try OutStream(path: Path(outputURL.path))
                try streams.add(item: entry.item, stream: outputStream)
                expectedFiles.append((outputURL, entry.byteCount))
            }

            guard try archive.decoder.extract(itemsToStreams: streams) else {
                throw Safe7zError.extractionFailed
            }
            for (url, expectedSize) in expectedFiles {
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ])
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      UInt64(values.fileSize ?? -1) == expectedSize
                else { throw Safe7zError.extractionFailed }
            }
        } catch let error as Safe7zError {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        } catch let error as PLzmaSDK.Exception {
            try? FileManager.default.removeItem(at: destinationURL)
            throw mapped(error, passwordWasProvided: password?.isEmpty == false, duringExtraction: true)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
        return archive.inspection
    }

    private func open(_ sourceURL: URL, password: String?) throws -> OpenedArchive {
        guard sourceURL.isFileURL else { throw Safe7zError.sourceIsNotFileURL }
        let values = try sourceURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isSymbolicLink != true else { throw Safe7zError.sourceIsSymbolicLink }
        guard values.isRegularFile == true, let sourceSize = values.fileSize, sourceSize > 0 else {
            throw Safe7zError.sourceMissing
        }
        let signature: Data
        do {
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? handle.close() }
            signature = try handle.read(upToCount: 6) ?? Data()
        }
        guard signature.elementsEqual([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]) else {
            throw Safe7zError.invalidArchive
        }

        do {
            let input = try InStream(path: Path(sourceURL.path))
            let decoder = try Decoder(stream: input, fileType: .sevenZ)
            try decoder.setPassword(password?.isEmpty == false ? password : nil)
            guard try decoder.open() else { throw Safe7zError.invalidArchive }
            let count = Int(try decoder.count())
            guard count <= limits.maximumEntryCount else { throw Safe7zError.entryLimitExceeded }

            var validated: [ValidatedItem] = []
            validated.reserveCapacity(count)
            var foldedPaths: Set<String> = []
            var totalExpanded: UInt64 = 0
            var containsEncryptedEntries = false

            for index in 0..<count {
                let item = try decoder.item(at: Size(index))
                let rawPath = try item.path().description
                    .replacingOccurrences(of: "\\", with: "/")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !rawPath.isEmpty,
                      rawPath.utf8.count <= limits.maximumPathByteCount
                else { throw Safe7zError.pathLimitExceeded }
                let relativePath: StorageRelativePath
                do {
                    relativePath = try StorageRelativePath(rawValue: rawPath)
                } catch {
                    throw Safe7zError.unsafePath
                }
                let folded = rawPath.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                guard foldedPaths.insert(folded).inserted else {
                    throw Safe7zError.duplicatePath
                }
                let addition = totalExpanded.addingReportingOverflow(item.size)
                guard !addition.overflow,
                      addition.partialValue <= UInt64(limits.maximumExpandedByteCount)
                else { throw Safe7zError.expandedSizeLimitExceeded }
                totalExpanded = addition.partialValue
                containsEncryptedEntries = containsEncryptedEntries || item.encrypted
                validated.append(
                    ValidatedItem(
                        item: item,
                        relativePath: relativePath,
                        isDirectory: item.isDir,
                        byteCount: item.size
                    )
                )
            }

            if sourceSize > 0,
               totalExpanded / UInt64(sourceSize) > UInt64(limits.maximumOverallCompressionRatio) {
                throw Safe7zError.compressionRatioLimitExceeded
            }
            let inspection = SevenZipArchiveInspection(
                entryCount: count,
                fileCount: validated.filter { !$0.isDirectory }.count,
                compressedByteCount: Int64(sourceSize),
                uncompressedByteCount: Int64(totalExpanded),
                containsEncryptedEntries: containsEncryptedEntries
            )
            return OpenedArchive(decoder: decoder, items: validated, inspection: inspection)
        } catch let error as Safe7zError {
            throw error
        } catch let error as PLzmaSDK.Exception {
            throw mapped(error, passwordWasProvided: password?.isEmpty == false, duringExtraction: false)
        } catch {
            throw Safe7zError.invalidArchive
        }
    }

    private func mapped(
        _ exception: PLzmaSDK.Exception,
        passwordWasProvided: Bool,
        duringExtraction: Bool
    ) -> Safe7zError {
        let description = "\(exception.what) \(exception.reason)".lowercased()
        let mentionsEncryption = description.contains("password")
            || description.contains("encrypted")
            || description.contains("crypto")
        if passwordWasProvided {
            return .incorrectPasswordOrCorruptArchive
        }
        if mentionsEncryption {
            return .passwordRequired
        }
        if !duringExtraction {
            // A 7z archive with an encrypted header is intentionally
            // indistinguishable from a damaged next-header to the decoder
            // until a password is supplied. The signature was validated
            // before this point; one password prompt is the safe resolution.
            return .passwordRequired
        }
        return duringExtraction ? .extractionFailed : .invalidArchive
    }
}
