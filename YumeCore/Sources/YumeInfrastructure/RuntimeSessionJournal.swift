import Foundation

/// A small synchronous breadcrumb file written before entering a native ABI.
/// Async app logs alone cannot preserve the stage when that ABI aborts or
/// blocks UIKit. The independent heartbeat records a stall without invoking
/// the engine or trying to recover unsafe native state.
public final class RuntimeSessionJournal: @unchecked Sendable {
    public struct Milestone: Codable, Sendable {
        public let event: String
        public let elapsedMilliseconds: Int
        public let metadata: [String: String]
    }

    public struct Report: Codable, Sendable {
        public let schemaVersion: Int
        public let sessionID: UUID
        public let startedAt: Date
        public let metadata: [String: String]
        public var updatedAt: Date
        public var endedAt: Date?
        public var recoveryReportedAt: Date?
        public var lastEvent: String
        public var lastError: String?
        public var firstFrameAt: Date?
        public var eventCount: Int
        public var milestones: [Milestone]
    }

    public let url: URL
    private let lock = NSLock()
    private var report: Report
    private let startedUptime = ProcessInfo.processInfo.systemUptime
    private var lastWriteUptime: TimeInterval = 0
    private var heartbeatUptime = ProcessInfo.processInfo.systemUptime
    private var lastStallUptime: TimeInterval = 0
    private var suspended = false
    private var timer: DispatchSourceTimer?

    public init(directoryURL: URL, sessionID: UUID, metadata: [String: String]) throws {
        url = directoryURL.appendingPathComponent("session-\(sessionID.uuidString.lowercased()).json")
        let now = Date()
        report = Report(schemaVersion: 1, sessionID: sessionID, startedAt: now,
                        metadata: metadata, updatedAt: now, lastEvent: "launch.prepared",
                        eventCount: 0, milestones: [])
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try persist()
    }

    deinit { timer?.cancel() }

    public func record(_ event: String, isError: Bool = false, metadata: [String: String] = [:]) throws {
        try lock.withLock {
            guard report.endedAt == nil else { return }
            let now = Date()
            let uptime = ProcessInfo.processInfo.systemUptime
            report.updatedAt = now
            report.eventCount += 1
            let routine = ["native.engine-log", "web.resource-served", "web.runtime-snapshot", "web.input-dispatched"].contains(event)
                || event.hasPrefix("web.console-")
            if !routine { report.lastEvent = event }
            if isError { report.lastError = event }
            if event == "native.first-frame" || event == "web.first-frame" { report.firstFrameAt = report.firstFrameAt ?? now }
            if event == "native.released" || event == "web.stopped" {
                report.endedAt = now
                timer?.cancel()
                timer = nil
            }
            if !routine || isError {
                report.milestones.append(Milestone(event: event,
                    elapsedMilliseconds: Int(max(0, uptime - startedUptime) * 1000),
                    metadata: metadata.mapValues { String($0.prefix(4000)) }))
                if report.milestones.count > 80 { report.milestones.removeFirst(report.milestones.count - 80) }
            }
            if !routine || isError || uptime - lastWriteUptime >= 2 {
                try persist()
                lastWriteUptime = uptime
            }
        }
    }

    public func setSuspended(_ value: Bool) {
        lock.withLock {
            suspended = value
            heartbeatUptime = ProcessInfo.processInfo.systemUptime
        }
    }

    public func startMonitoring() {
        lock.withLock {
            guard timer == nil, report.endedAt == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            source.schedule(deadline: .now() + 2, repeating: 2)
            source.setEventHandler { [weak self] in self?.checkHeartbeat() }
            timer = source
            source.resume()
        }
    }

    private func checkHeartbeat() {
        let delay: TimeInterval? = lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            guard !suspended, report.endedAt == nil,
                  now - heartbeatUptime > 8, now - lastStallUptime > 10 else { return nil }
            lastStallUptime = now
            return now - heartbeatUptime
        }
        if let delay {
            try? record("host.main-thread-unresponsive", isError: true,
                        metadata: ["delaySeconds": String(format: "%.1f", delay)])
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            lock.withLock { heartbeatUptime = ProcessInfo.processInfo.systemUptime }
        }
    }

    /// An unfinished session indicates interruption, not a proven native crash
    /// (force quit and OS memory termination leave the same evidence).
    public static func recoverInterrupted(in directoryURL: URL) throws -> [Report] {
        let files = try FileManager.default.contentsOfDirectory(at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        var recovered: [Report] = []
        for file in files where file.lastPathComponent.hasPrefix("session-") && file.pathExtension == "json" {
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  (attributes.fileSize ?? 0) <= 1_048_576,
                  var report = try? JSONDecoder().decode(Report.self, from: Data(contentsOf: file)),
                  report.endedAt == nil, report.recoveryReportedAt == nil else { continue }
            report.recoveryReportedAt = Date()
            let data = try JSONEncoder().encode(report)
            try data.write(to: file, options: .atomic)
            recovered.append(report)
        }
        return recovered
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
