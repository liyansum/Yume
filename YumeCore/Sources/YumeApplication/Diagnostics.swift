import Foundation
import YumeDomain

public enum DiagnosticLevel: String, Codable, Hashable, Sendable {
    case information
    case warning
    case error
}

public struct DiagnosticEntry: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let level: DiagnosticLevel
    public let subsystem: String
    public let code: String
    public let taskID: ImportTaskID?
    public let gameID: GameID?
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: DiagnosticLevel,
        subsystem: String,
        code: String,
        taskID: ImportTaskID? = nil,
        gameID: GameID? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.subsystem = subsystem
        self.code = code
        self.taskID = taskID
        self.gameID = gameID
        self.metadata = metadata
    }
}

public protocol DiagnosticStore: Sendable {
    func record(_ entry: DiagnosticEntry) async throws
    func recentEntries(limit: Int) async throws -> [DiagnosticEntry]
    func makeExport() async throws -> URL
}
