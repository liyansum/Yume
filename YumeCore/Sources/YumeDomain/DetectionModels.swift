import Foundation

public enum DetectionEvidenceKind: String, Codable, Hashable, Sendable {
    case requiredFile
    case characteristicFile
    case characteristicDirectory
    case metadata
    case unsupportedNativeComponent
}

public struct DetectionEvidence: Codable, Hashable, Sendable {
    public let relativePath: StorageRelativePath
    public let kind: DetectionEvidenceKind
    public let detailCode: String
    public let score: Int

    public init(
        relativePath: StorageRelativePath,
        kind: DetectionEvidenceKind,
        detailCode: String,
        score: Int
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.detailCode = detailCode
        self.score = score
    }
}

public enum CompatibilitySeverity: String, Codable, Hashable, Sendable {
    case information
    case warning
    case blocking
}

public struct CompatibilityIssue: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let severity: CompatibilitySeverity
    public let detailCode: String
    public let relativePath: StorageRelativePath?

    public init(
        id: String,
        severity: CompatibilitySeverity,
        detailCode: String,
        relativePath: StorageRelativePath? = nil
    ) {
        self.id = id
        self.severity = severity
        self.detailCode = detailCode
        self.relativePath = relativePath
    }
}

public struct CompatibilityReport: Codable, Hashable, Sendable {
    public let status: CompatibilityStatus
    public let issues: [CompatibilityIssue]

    public init(status: CompatibilityStatus, issues: [CompatibilityIssue] = []) {
        self.status = status
        self.issues = issues
    }
}

public struct ProbeResult: Codable, Hashable, Sendable {
    public let engine: EngineDescriptor
    public let rootRelativePath: StorageRelativePath
    public let confidence: Int
    public let evidence: [DetectionEvidence]
    public let compatibility: CompatibilityReport

    public init(
        engine: EngineDescriptor,
        rootRelativePath: StorageRelativePath,
        confidence: Int,
        evidence: [DetectionEvidence],
        compatibility: CompatibilityReport
    ) {
        self.engine = engine
        self.rootRelativePath = rootRelativePath
        self.confidence = min(max(confidence, 0), 100)
        self.evidence = evidence
        self.compatibility = compatibility
    }
}

public enum DetectionDecision: Hashable, Sendable {
    case noMatch
    case selected(ProbeResult)
    case ambiguous([ProbeResult])
}

public struct GameManifest: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public var game: ImportedGame
    public let contentRoot: StorageRelativePath
    public let detection: ProbeResult
    public var saveLibraryID: SaveLibraryID?

    public init(
        game: ImportedGame,
        contentRoot: StorageRelativePath,
        detection: ProbeResult,
        saveLibraryID: SaveLibraryID? = nil
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.game = game
        self.contentRoot = contentRoot
        self.detection = detection
        self.saveLibraryID = saveLibraryID
    }
}
