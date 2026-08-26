import Foundation

public struct ImportTaskID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public let rawValue: UUID

    public var id: UUID { rawValue }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }
}

public enum ImportStage: String, Codable, CaseIterable, Hashable, Sendable {
    case picked
    case validatingSource
    case budgeting
    case copyingToStaging
    case extractingToStaging
    case detectingRoots
    case resolvingAmbiguity
    case scanningCompatibility
    case awaitingConversionConsent
    case convertingDerivedData
    case validatingCommit
    case committed
}

public enum ImportState: Codable, Equatable, Sendable {
    case active(stage: ImportStage)
    case paused(stage: ImportStage)
    case cancelled
    case failed(code: String)
    case completed(gameIDs: [GameID])
}
