import Foundation
import YumeApplication

public actor LocalDiagnosticStore: DiagnosticStore {
    public enum StoreError: Error, Equatable, Sendable {
        case directoryIsNotFileURL
        case invalidLogEntry
    }

    private static let currentLogName = "yume.jsonl"
    private static let maximumLogByteCount: UInt64 = 20 * 1_024 * 1_024
    private static let maximumArchiveCount = 7

    private let directoryURL: URL
    private let fileManager = FileManager.default

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL.standardizedFileURL
    }

    public func record(_ entry: DiagnosticEntry) async throws {
        try prepareDirectory()
        var data = try encoder().encode(entry)
        data.append(0x0A)
        let current = currentLogURL
        let currentSize = try fileSize(at: current)
        if currentSize + UInt64(data.count) > Self.maximumLogByteCount {
            try rotateLogs()
        }

        if !fileManager.fileExists(atPath: current.path) {
            try data.write(to: current, options: [.atomic])
        } else {
            let handle = try FileHandle(forUpdating: current)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                let last = try handle.read(upToCount: 1)
                try handle.seekToEnd()
                if last?.last != 0x0A { try handle.write(contentsOf: Data([0x0A])) }
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }
    }

    public func recentEntries(limit: Int) async throws -> [DiagnosticEntry] {
        try prepareDirectory()
        guard limit > 0 else { return [] }
        var entries: [DiagnosticEntry] = []
        // A process can die between a JSONL write and its newline. Preserve
        // valid entries and continue into rotations instead of failing the
        // entire diagnostics screen on the one damaged line we need to inspect.
        for url in [currentLogURL] + (1...Self.maximumArchiveCount).map(archivedLogURL) {
            guard entries.count < limit, fileManager.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            for line in data.split(separator: 0x0A).reversed() {
                if let entry = try? decoder().decode(DiagnosticEntry.self, from: Data(line)) {
                    entries.append(entry)
                    if entries.count == limit { break }
                }
            }
        }
        return entries

    }

    public func makeExport() async throws -> URL {
        let entries = try await recentEntries(limit: 2_000)
        let exportRoot = directoryURL.appendingPathComponent("Exports", isDirectory: true)
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableExportRoot = exportRoot
        try mutableExportRoot.setResourceValues(resourceValues)
        let exportURL = exportRoot.appendingPathComponent(
            "Yume-Diagnostics-\(UUID().uuidString.lowercased()).json"
        )
        let data = try encoder(prettyPrinted: true).encode(entries)
        try data.write(to: exportURL, options: [.atomic])
        return exportURL
    }

    private var currentLogURL: URL {
        directoryURL.appendingPathComponent(Self.currentLogName)
    }

    private func prepareDirectory() throws {
        guard directoryURL.isFileURL else { throw StoreError.directoryIsNotFileURL }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directoryURL
        try mutableDirectory.setResourceValues(values)
    }

    private func rotateLogs() throws {
        let oldest = archivedLogURL(index: Self.maximumArchiveCount)
        try? fileManager.removeItem(at: oldest)
        if Self.maximumArchiveCount > 1 {
            for index in stride(from: Self.maximumArchiveCount - 1, through: 1, by: -1) {
                let source = archivedLogURL(index: index)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.moveItem(at: source, to: archivedLogURL(index: index + 1))
            }
        }
        if fileManager.fileExists(atPath: currentLogURL.path) {
            try fileManager.moveItem(at: currentLogURL, to: archivedLogURL(index: 1))
        }
    }

    private func archivedLogURL(index: Int) -> URL {
        directoryURL.appendingPathComponent("yume.\(index).jsonl")
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(max(0, values.fileSize ?? 0))
    }

    private func encoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
