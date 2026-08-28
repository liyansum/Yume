import Foundation
import YumeDomain

public struct PreparedGame: Sendable, Hashable {
    public let gameID: GameID
    public let engineID: EngineID
    public let contentRootURL: URL
    public let saveRootURL: URL
    public let derivedRootURL: URL
    public let logRootURL: URL
    public let rtpMountRoots: [URL]

    public init(
        gameID: GameID,
        engineID: EngineID,
        contentRootURL: URL,
        saveRootURL: URL,
        derivedRootURL: URL,
        logRootURL: URL,
        rtpMountRoots: [URL] = []
    ) {
        self.gameID = gameID
        self.engineID = engineID
        self.contentRootURL = contentRootURL
        self.saveRootURL = saveRootURL
        self.derivedRootURL = derivedRootURL
        self.logRootURL = logRootURL
        self.rtpMountRoots = rtpMountRoots
    }
}

public struct EngineContext: Sendable {
    public let sessionID: UUID
    public let localeIdentifier: String
    public let networkingAllowed: Bool

    public init(
        sessionID: UUID,
        localeIdentifier: String = "en",
        networkingAllowed: Bool = false
    ) {
        self.sessionID = sessionID
        self.localeIdentifier = localeIdentifier
        self.networkingAllowed = networkingAllowed
    }
}

public enum EngineEvent: Sendable, Equatable {
    case started
    case firstFrame
    case paused
    case resumed
    case stopped
    case warning(code: String)
    case failed(code: String)
}

public enum EngineInputAction: String, Codable, Sendable, CaseIterable {
    case up
    case down
    case left
    case right
    case confirm
    case cancel
    case menu
    case pageUp
    case pageDown
    case pointerPrimary
    case fastForward
    case autoMode
    case history
}

public enum EngineInputEvent: Sendable, Equatable {
    case button(action: EngineInputAction, pressed: Bool)
    case pointer(x: Double, y: Double, pressed: Bool)
    case text(String)
}

public protocol EnginePlayer: AnyObject, Sendable {
    var events: AsyncStream<EngineEvent> { get }

    func start() async throws
    func pause() async
    func resume() async
    func send(_ input: EngineInputEvent) async
    func stop() async
}

public protocol GameEngineAdapter: Sendable {
    var descriptor: EngineDescriptor { get }
    var runtimeIdentifier: String { get }

    func prepare(game: ImportedGame, context: EngineContext) async throws -> PreparedGame

    @MainActor
    func makePlayer(for game: PreparedGame, context: EngineContext) throws -> any EnginePlayer
}

public enum EngineSessionState: Sendable, Equatable {
    case idle
    case preparing(gameID: GameID, engineID: EngineID)
    case ready(gameID: GameID, engineID: EngineID)
    case running(gameID: GameID, engineID: EngineID)
    case paused(gameID: GameID, engineID: EngineID)
    case stopping(gameID: GameID, engineID: EngineID)
    case failed(gameID: GameID?, engineID: EngineID?, code: String)
}

public enum EngineSessionTransitionError: Error, Sendable, Equatable {
    case invalidTransition(from: EngineSessionState, operation: String)
}

/// Shared lifecycle gate for every native runtime. It deliberately owns no UI
/// or engine globals; adapters use it to guarantee one linear session and to
/// make pause/termination failures observable instead of silently diverging.
public actor EngineSessionLifecycle {
    public private(set) var state: EngineSessionState = .idle

    public init() {}

    public func beginPreparing(gameID: GameID, engineID: EngineID) throws {
        guard state == .idle else { throw invalid("beginPreparing") }
        state = .preparing(gameID: gameID, engineID: engineID)
    }

    public func markReady() throws {
        guard case let .preparing(gameID, engineID) = state else { throw invalid("markReady") }
        state = .ready(gameID: gameID, engineID: engineID)
    }

    public func markRunning() throws {
        switch state {
        case let .ready(gameID, engineID), let .paused(gameID, engineID):
            state = .running(gameID: gameID, engineID: engineID)
        default:
            throw invalid("markRunning")
        }
    }

    public func markPaused() throws {
        guard case let .running(gameID, engineID) = state else { throw invalid("markPaused") }
        state = .paused(gameID: gameID, engineID: engineID)
    }

    public func beginStopping() throws {
        switch state {
        case let .ready(gameID, engineID),
             let .running(gameID, engineID),
             let .paused(gameID, engineID):
            state = .stopping(gameID: gameID, engineID: engineID)
        default:
            throw invalid("beginStopping")
        }
    }

    public func finishStopping() throws {
        guard case .stopping = state else { throw invalid("finishStopping") }
        state = .idle
    }

    public func fail(code: String) {
        switch state {
        case let .preparing(gameID, engineID),
             let .ready(gameID, engineID),
             let .running(gameID, engineID),
             let .paused(gameID, engineID),
             let .stopping(gameID, engineID):
            state = .failed(gameID: gameID, engineID: engineID, code: code)
        case .idle:
            state = .failed(gameID: nil, engineID: nil, code: code)
        case let .failed(gameID, engineID, _):
            state = .failed(gameID: gameID, engineID: engineID, code: code)
        }
    }

    public func resetAfterFailure() throws {
        guard case .failed = state else { throw invalid("resetAfterFailure") }
        state = .idle
    }

    private func invalid(_ operation: String) -> EngineSessionTransitionError {
        .invalidTransition(from: state, operation: operation)
    }
}
