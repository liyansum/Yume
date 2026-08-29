import Foundation
import YumeDomain

public protocol GameLibrary: Sendable {
    func allGames() async throws -> [ImportedGame]
    func game(id: GameID) async throws -> ImportedGame?
    func markPlayed(id: GameID, at date: Date) async throws
}

public extension GameLibrary {
    func game(id: GameID) async throws -> ImportedGame? {
        try await allGames().first { $0.id == id }
    }
}

public enum GameRemovalPolicy: String, Codable, Hashable, Sendable {
    case preserveSaves
    case deleteSaves
}

public struct GameStorageBreakdown: Codable, Hashable, Sendable, Identifiable {
    public let gameID: GameID
    public let originalByteCount: Int64
    public let derivedByteCount: Int64
    public let saveByteCount: Int64
    public let logByteCount: Int64

    public var totalByteCount: Int64 {
        [originalByteCount, derivedByteCount, saveByteCount, logByteCount]
            .reduce(0) { partial, value in
                let addition = partial.addingReportingOverflow(value)
                return addition.overflow ? Int64.max : addition.partialValue
            }
    }

    public var id: GameID { gameID }

    public init(
        gameID: GameID,
        originalByteCount: Int64,
        derivedByteCount: Int64,
        saveByteCount: Int64,
        logByteCount: Int64
    ) {
        self.gameID = gameID
        self.originalByteCount = max(0, originalByteCount)
        self.derivedByteCount = max(0, derivedByteCount)
        self.saveByteCount = max(0, saveByteCount)
        self.logByteCount = max(0, logByteCount)
    }
}

public protocol GameMaintenance: Sendable {
    func storageBreakdown(for id: GameID) async throws -> GameStorageBreakdown
    func removeGame(id: GameID, policy: GameRemovalPolicy) async throws
    func renameGame(id: GameID, title: String) async throws
}

public struct GameSaveLibrary: Codable, Hashable, Sendable, Identifiable {
    public let id: SaveLibraryID
    public var title: String
    public let engine: EngineDescriptor
    public let contentFingerprint: String?
    public let createdAt: Date
    public var modifiedAt: Date
    public let byteCount: Int64
    public let boundGameID: GameID?

    public init(
        id: SaveLibraryID,
        title: String,
        engine: EngineDescriptor,
        contentFingerprint: String?,
        createdAt: Date,
        modifiedAt: Date,
        byteCount: Int64,
        boundGameID: GameID?
    ) {
        self.id = id
        self.title = title
        self.engine = engine
        self.contentFingerprint = contentFingerprint
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.byteCount = max(0, byteCount)
        self.boundGameID = boundGameID
    }
}

public enum SaveLibraryError: Error, Equatable, Sendable {
    case gameNotFound
    case saveLibraryNotFound
    case engineMismatch
    case alreadyBound(GameID)
    case cannotDeleteBoundLibrary
    case invalidTitle
}

public protocol GameSaveLibraryManaging: Sendable {
    func saveLibraries() async throws -> [GameSaveLibrary]
    func saveLibrary(for gameID: GameID) async throws -> GameSaveLibrary
    func bindSaveLibrary(_ saveLibraryID: SaveLibraryID, to gameID: GameID) async throws
    func deleteSaveLibrary(id: SaveLibraryID) async throws
}

public enum LibrarySort: String, CaseIterable, Codable, Hashable, Sendable {
    case recentlyPlayed
    case title
    case recentlyImported
    case size
}

public struct LibraryQuery: Sendable, Equatable {
    public var searchText: String
    public var sort: LibrarySort

    public init(searchText: String = "", sort: LibrarySort = .recentlyPlayed) {
        self.searchText = searchText
        self.sort = sort
    }

    public func apply(to games: [ImportedGame]) -> [ImportedGame] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmedSearch.isEmpty
            ? games
            : games.filter { game in
                game.title.localizedCaseInsensitiveContains(trimmedSearch)
                    || game.engine.displayName.localizedCaseInsensitiveContains(trimmedSearch)
            }

        return filtered.sorted(by: comparator)
    }

    private func comparator(_ lhs: ImportedGame, _ rhs: ImportedGame) -> Bool {
        switch sort {
        case .recentlyPlayed:
            let lhsDate = lhs.lastPlayedAt ?? .distantPast
            let rhsDate = rhs.lastPlayedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
        case .title:
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        case .recentlyImported:
            if lhs.importedAt != rhs.importedAt { return lhs.importedAt > rhs.importedAt }
        case .size:
            if lhs.installedByteCount != rhs.installedByteCount {
                return lhs.installedByteCount > rhs.installedByteCount
            }
        }

        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }
}
