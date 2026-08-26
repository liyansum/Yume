import Foundation

public struct GameID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public let rawValue: UUID

    public var id: UUID { rawValue }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }
}

public struct EngineID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct EngineDescriptor: Codable, Hashable, Sendable {
    public let id: EngineID
    public let displayName: String
    public let compatibilityVersion: String

    public init(id: EngineID, displayName: String, compatibilityVersion: String) {
        self.id = id
        self.displayName = displayName
        self.compatibilityVersion = compatibilityVersion
    }
}

public enum CompatibilityStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case runnable
    case conversionRequired
    case partiallyCompatible
    case unsupported
    case notEvaluated
}

public struct ImportedGame: Codable, Hashable, Sendable, Identifiable {
    public let id: GameID
    public var title: String
    public var engine: EngineDescriptor
    public var compatibilityStatus: CompatibilityStatus
    public var importedAt: Date
    public var lastPlayedAt: Date?
    public var installedByteCount: Int64

    public init(
        id: GameID = GameID(),
        title: String,
        engine: EngineDescriptor,
        compatibilityStatus: CompatibilityStatus,
        importedAt: Date,
        lastPlayedAt: Date? = nil,
        installedByteCount: Int64
    ) {
        self.id = id
        self.title = title
        self.engine = engine
        self.compatibilityStatus = compatibilityStatus
        self.importedAt = importedAt
        self.lastPlayedAt = lastPlayedAt
        self.installedByteCount = installedByteCount
    }
}
