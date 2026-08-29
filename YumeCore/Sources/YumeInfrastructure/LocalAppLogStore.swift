import Foundation

public enum AppLogLevel: String, Sendable {
    case information = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

public struct AppLogFile: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let startedAt: Date
    public let byteCount: Int64
    public let isCurrent: Bool

    public init(
        id: String,
        url: URL,
        startedAt: Date,
        byteCount: Int64,
        isCurrent: Bool
    ) {
        self.id = id
        self.url = url
        self.startedAt = startedAt
        self.byteCount = max(0, byteCount)
        self.isCurrent = isCurrent
    }
}

/// Durable, human-readable logs with one file per app process launch.
/// Every append is synchronized so the last completed line survives a native
/// runtime abort or LiveContainer process termination.
public actor LocalAppLogStore {
    public enum StoreError: Error, Equatable, Sendable {
        case directoryIsNotFileURL
        case noActiveSession
    }

    private static let maximumSessionByteCount: UInt64 = 20 * 1_024 * 1_024
    private let directoryURL: URL
    private let exportDirectoryURL: URL
    private let fileManager: FileManager
    private var currentLogURL: URL?
    private var reachedSizeLimit = false

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.exportDirectoryURL = directoryURL
            .deletingLastPathComponent()
            .appendingPathComponent("AppLogExports", isDirectory: true)
            .standardizedFileURL
        self.fileManager = fileManager
    }

    @discardableResult
    public func startSession(metadata: [String: String] = [:]) throws -> AppLogFile {
        try prepareDirectory(directoryURL)
        let now = Date()
        let filename = "app-\(Self.filenameTimestamp(now))-\(UUID().uuidString.lowercased()).log"
        let url = directoryURL.appendingPathComponent(filename)
        currentLogURL = url
        reachedSizeLimit = false
        try appendLine(
            level: .information,
            subsystem: "app",
            message: "session.started",
            metadata: metadata,
            at: now
        )
        return try descriptor(for: url)
    }

    public func append(
        level: AppLogLevel = .information,
        subsystem: String,
        message: String,
        metadata: [String: String] = [:],
        at date: Date = Date()
    ) throws {
        guard currentLogURL != nil else { throw StoreError.noActiveSession }
        try appendLine(
            level: level,
            subsystem: subsystem,
            message: message,
            metadata: metadata,
            at: date
        )
    }

    public func logs() throws -> [AppLogFile] {
        try prepareDirectory(directoryURL)
        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .creationDateKey
            ],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "log" }
        .compactMap { try? descriptor(for: $0) }
        .sorted { $0.startedAt > $1.startedAt }
    }

    @discardableResult
    public func removeLogs(olderThan cutoff: Date) throws -> Int {
        var removed = 0
        for log in try logs() where !log.isCurrent && log.startedAt < cutoff {
            try fileManager.removeItem(at: log.url)
            removed += 1
        }
        return removed
    }

    public func removeAllLogs() throws {
        for log in try logs() {
            try fileManager.removeItem(at: log.url)
        }
        if fileManager.fileExists(atPath: exportDirectoryURL.path) {
            for export in try fileManager.contentsOfDirectory(
                at: exportDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                try fileManager.removeItem(at: export)
            }
        }
        currentLogURL = nil
        reachedSizeLimit = false
    }

    public func makeExport(additionalLogFiles: [URL] = []) throws -> URL {
        try prepareDirectory(exportDirectoryURL)
        let exportURL = exportDirectoryURL.appendingPathComponent(
            "Yume-App-Logs-\(Self.filenameTimestamp(Date())).txt"
        )
        var output = Data("Yume App Logs\nGenerated: \(Self.displayTimestamp(Date()))\n\n".utf8)
        let primaryLogs = try logs().map(\.url)
        var seenPaths: Set<String> = []
        let sources = (primaryLogs + additionalLogFiles)
            .filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
            .sorted { $0.path < $1.path }
        for source in sources {
            let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let maximumIncludedBytes = 8 * 1_024 * 1_024
            guard let handle = try? FileHandle(forReadingFrom: source) else { continue }
            defer { try? handle.close() }
            let size = max(0, values?.fileSize ?? 0)
            let offset = max(0, size - maximumIncludedBytes)
            if offset > 0 { try? handle.seek(toOffset: UInt64(offset)) }
            let data = (try? handle.readToEnd()) ?? Data()
            output.append(Data("===== \(source.lastPathComponent) (last \(data.count) bytes) =====\n".utf8))
            output.append(data)
            if data.last != 0x0A { output.append(0x0A) }
            output.append(0x0A)
        }
        try output.write(to: exportURL, options: [.atomic])
        return exportURL
    }

    private func appendLine(
        level: AppLogLevel,
        subsystem: String,
        message: String,
        metadata: [String: String],
        at date: Date
    ) throws {
        guard let currentLogURL else { throw StoreError.noActiveSession }
        if reachedSizeLimit { return }
        let size = try fileSize(at: currentLogURL)
        if size >= Self.maximumSessionByteCount {
            reachedSizeLimit = true
            return
        }

        let safeSubsystem = Self.singleLine(subsystem)
        let safeMessage = Self.singleLine(message)
        let metadataText = metadata
            .sorted { $0.key < $1.key }
            .map { "\(Self.singleLine($0.key))=\(Self.quoted($0.value))" }
            .joined(separator: " ")
        var line = "\(Self.displayTimestamp(date)) [\(level.rawValue)] [\(safeSubsystem)] \(safeMessage)"
        if !metadataText.isEmpty { line += " \(metadataText)" }
        line += "\n"
        let data = Data(line.utf8)

        if !fileManager.fileExists(atPath: currentLogURL.path) {
            try data.write(to: currentLogURL, options: [.atomic])
        } else {
            let handle = try FileHandle(forWritingTo: currentLogURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }
    }

    private func descriptor(for url: URL) throws -> AppLogFile {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey
        ])
        return AppLogFile(
            id: url.lastPathComponent,
            url: url,
            startedAt: Self.startedAtFromFilename(url.lastPathComponent)
                ?? values.contentModificationDate
                ?? values.creationDate
                ?? .distantPast,
            byteCount: Int64(max(0, values.fileSize ?? 0)),
            isCurrent: url.standardizedFileURL == currentLogURL?.standardizedFileURL
        )
    }

    private func prepareDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw StoreError.directoryIsNotFileURL }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(max(0, values.fileSize ?? 0))
    }

    private static func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func quoted(_ value: String) -> String {
        "\"\(singleLine(value).replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    private static func startedAtFromFilename(_ filename: String) -> Date? {
        let stem = (filename as NSString).deletingPathExtension
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "app" else { return nil }
        let encoded = parts[1...3].joined(separator: "-")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.date(from: encoded)
    }

    private static func displayTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
