import Foundation
import YumeApplication
import YumeDomain

public actor InMemoryGameLibrary: GameLibrary, GameMaintenance {
    private var games: [ImportedGame]

    public init(games: [ImportedGame] = []) {
        self.games = games
    }

    public func allGames() async throws -> [ImportedGame] {
        games
    }

    public func game(id: GameID) async throws -> ImportedGame? {
        games.first { $0.id == id }
    }

    public func removeGame(id: GameID, policy: GameRemovalPolicy) async throws {
        games.removeAll { $0.id == id }
    }

    public func storageBreakdown(for id: GameID) async throws -> GameStorageBreakdown {
        let game = games.first { $0.id == id }
        return GameStorageBreakdown(
            gameID: id,
            originalByteCount: game?.installedByteCount ?? 0,
            derivedByteCount: 0,
            saveByteCount: 0,
            logByteCount: 0
        )
    }

    public func markPlayed(id: GameID, at date: Date) async throws {
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        games[index].lastPlayedAt = date
    }

    public func replaceGames(with games: [ImportedGame]) {
        self.games = games
    }
}
