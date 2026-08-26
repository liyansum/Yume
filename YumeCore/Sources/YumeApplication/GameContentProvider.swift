import Foundation
import YumeDomain

public struct GameContentLocation: Sendable, Identifiable, Equatable {
    public let game: ImportedGame
    public let rootURL: URL
    public let saveRootURL: URL
    public let entryPoint: StorageRelativePath

    public var id: GameID { game.id }

    public init(
        game: ImportedGame,
        rootURL: URL,
        saveRootURL: URL,
        entryPoint: StorageRelativePath
    ) {
        self.game = game
        self.rootURL = rootURL
        self.saveRootURL = saveRootURL
        self.entryPoint = entryPoint
    }
}

public enum GameContentError: Error, Equatable, Sendable {
    case gameNotFound
    case runtimeUnavailable(EngineID)
    case entryPointMissing
}

public protocol GameContentProvider: Sendable {
    func contentLocation(for id: GameID) async throws -> GameContentLocation
}
