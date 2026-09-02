import Foundation
import YumeDomain

public enum PlaySessionError: Error, Equatable, Sendable {
    case gameNotFound
    case gameNotRunnable(GameID)
    case runtimeUnavailable(EngineID)
    case sessionAlreadyActive(active: GameID)
}

public struct GamePlaySession: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let content: GameContentLocation
    public let launchPlan: LaunchPlan
    public let rtpMountRoots: [URL]

    public init(
        id: UUID = UUID(),
        content: GameContentLocation,
        launchPlan: LaunchPlan,
        rtpMountRoots: [URL] = []
    ) {
        self.id = id
        self.content = content
        self.launchPlan = launchPlan
        self.rtpMountRoots = rtpMountRoots
    }
}

/// Guarantees at most one active play session and gates launching on the
/// engine catalog so detection-only engines can never reach a runtime.
public actor PlaySessionCoordinator {
    private let library: any GameLibrary
    private let contentProvider: any GameContentProvider
    private let catalog: GameEngineCatalog
    private let runtimePackageStore: (any GameRuntimePackageStore)?
    private var activeID: GameID?

    public init(
        library: any GameLibrary,
        contentProvider: any GameContentProvider,
        catalog: GameEngineCatalog,
        runtimePackageStore: (any GameRuntimePackageStore)? = nil
    ) {
        self.library = library
        self.contentProvider = contentProvider
        self.catalog = catalog
        self.runtimePackageStore = runtimePackageStore
        self.activeID = nil
    }

    public func activeGameID() -> GameID? {
        activeID
    }

    public func start(gameID: GameID) async throws -> GamePlaySession {
        // A second presentation of the same game is still a second runtime
        // session. Native engines own process-global SDL/Ruby/Python state,
        // so allowing it races two providers just as surely as launching a
        // different game does.
        if let active = activeID {
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
        let launchPlan = GameLaunchAdapters.plan(for: game)
        if case .notPlanned = launchPlan.kind {
            throw PlaySessionError.runtimeUnavailable(game.engine.id)
        }
        let rtpMountRoots = try await runtimePackageStore?.rtpMountRoots(for: game) ?? []
        activeID = gameID
        return GamePlaySession(
            content: location,
            launchPlan: launchPlan,
            rtpMountRoots: rtpMountRoots
        )
    }

    /// Ends the active session (if any) and returns its game ID.
    @discardableResult
    public func stop() -> GameID? {
        defer { activeID = nil }
        return activeID
    }
}
