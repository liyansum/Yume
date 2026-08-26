import YumeApplication
import YumeDomain

public actor InMemoryGameLibrary: GameLibrary {
    private var games: [ImportedGame]

    public init(games: [ImportedGame] = []) {
        self.games = games
    }

    public func allGames() async throws -> [ImportedGame] {
        games
    }

    public func replaceGames(with games: [ImportedGame]) {
        self.games = games
    }
}
