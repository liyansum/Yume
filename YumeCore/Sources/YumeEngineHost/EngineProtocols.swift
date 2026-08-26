import Foundation
import YumeDomain

public struct PreparedGame: Sendable, Hashable {
    public let gameID: GameID
    public let engineID: EngineID

    public init(gameID: GameID, engineID: EngineID) {
        self.gameID = gameID
        self.engineID = engineID
    }
}

public struct EngineContext: Sendable {
    public let sessionID: UUID

    public init(sessionID: UUID) {
        self.sessionID = sessionID
    }
}

public enum EngineEvent: Sendable, Equatable {
    case started
    case paused
    case resumed
    case stopped
    case warning(code: String)
    case failed(code: String)
}

public protocol EnginePlayer: AnyObject {
    var events: AsyncStream<EngineEvent> { get }

    func start() async throws
    func pause()
    func resume()
    func stop() async
}

public protocol GameEngineAdapter: Sendable {
    var descriptor: EngineDescriptor { get }

    func prepare(game: ImportedGame, context: EngineContext) async throws -> PreparedGame

    @MainActor
    func makePlayer(for game: PreparedGame, context: EngineContext) throws -> any EnginePlayer
}
