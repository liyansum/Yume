import Foundation
import YumeDomain

public struct GameContentLocation: Sendable, Identifiable, Equatable {
    public let game: ImportedGame
    public let rootURL: URL
    public let saveRootURL: URL
    public let derivedRootURL: URL
    public let logRootURL: URL
    /// Present for browser-hosted games. Native runtimes consume `rootURL`
    /// directly and therefore do not need a synthetic index.html.
    public let webEntryPoint: StorageRelativePath?
    /// Primary content selected by detection (for example a SWF). Runtime
    /// adapters may ignore it when the engine discovers its own project files.
    public let runtimeEntryPoint: StorageRelativePath?

    public var id: GameID { game.id }

    public init(
        game: ImportedGame,
        rootURL: URL,
        saveRootURL: URL,
        derivedRootURL: URL? = nil,
        logRootURL: URL? = nil,
        webEntryPoint: StorageRelativePath? = nil,
        runtimeEntryPoint: StorageRelativePath? = nil
    ) {
        self.game = game
        self.rootURL = rootURL
        self.saveRootURL = saveRootURL
        self.derivedRootURL = derivedRootURL
            ?? rootURL.deletingLastPathComponent().appendingPathComponent("derived", isDirectory: true)
        self.logRootURL = logRootURL
            ?? rootURL.deletingLastPathComponent().appendingPathComponent("logs", isDirectory: true)
        self.webEntryPoint = webEntryPoint
        self.runtimeEntryPoint = runtimeEntryPoint
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
