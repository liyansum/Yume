import Foundation
import YumeDomain

public enum PlaySessionError: Error, Equatable, Sendable {
    case gameNotFound
    case gameNotRunnable(GameID)
    case runtimeUnavailable(EngineID)
    case sessionAlreadyActive(active: GameID)
}

/// Guarantees at most one active play session and gates launching on the
/// engine catalog so detection-only engines can never reach a runtime.
public actor PlaySessionCoordinator {
    private let library: any GameLibrary
    private let contentProvider: any GameContentProvider
    private let catalog: GameEngineCatalog
    private var activeGameID: GameID?

    public init(
        library: any GameLibrary,
        contentProvider: any GameContentProvider,
        catalog: GameEngineCatalog
    ) {
        self.library = library
        self.contentProvider = contentProvider
        self.catalog = catalog
        self.activeGameID = nil
    }

    public func activeGameID() -> GameID? {
        activeGameID
    }

    public func start(gameID: GameID) async throws -> GameContentLocation {
        if let active = activeGameID, active != gameID {
            throw PlaySessionError.sessionAlreadyActive(active: active)
        }

        guard let game = try await library.game(id: gameID) else {
            throw PlaySessionError.gameNotFound
        }
        guard game.compatibilityStatus == .runnable else {
            throw PlaySessionError.gameNotRunnable(gameID)
        }
        guard catalog.canHostRuntime(for: game.engine.id) else {
            throw PlaySessionError.runtimeUnavailable(game.engine.id)
        }

        let location = try await contentProvider.contentLocation(for: gameID)
        activeGameID = gameID
        return location
    }

    /// Ends the active session (if any) and returns its game ID.
    @discardableResult
    public func stop() -> GameID? {
        defer { activeGameID = nil }
        return activeGameID
    }
}
