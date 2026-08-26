import Foundation
import XCTest
@testable import YumeApplication
import YumeDomain

final class LibraryQueryTests: XCTestCase {
    private let engine = EngineDescriptor(
        id: EngineID(rawValue: "fixture.engine"),
        displayName: "Fixture Engine",
        compatibilityVersion: "0.1"
    )

    func testSearchMatchesTitleAndEngineName() {
        let games = [
            makeGame(id: 1, title: "Paper Kingdom", lastPlayed: 10),
            makeGame(id: 2, title: "Moonlit Archive", lastPlayed: 20)
        ]

        XCTAssertEqual(
            LibraryQuery(searchText: "moon").apply(to: games).map(\.title),
            ["Moonlit Archive"]
        )
        XCTAssertEqual(
            LibraryQuery(searchText: "fixture").apply(to: games).count,
            2
        )
    }

    func testRecentlyPlayedPlacesNeverPlayedGamesLast() {
        let games = [
            makeGame(id: 1, title: "Never Played", lastPlayed: nil),
            makeGame(id: 2, title: "Older", lastPlayed: 10),
            makeGame(id: 3, title: "Newer", lastPlayed: 20)
        ]

        let result = LibraryQuery(sort: .recentlyPlayed).apply(to: games)

        XCTAssertEqual(result.map(\.title), ["Newer", "Older", "Never Played"])
    }

    func testTitleSortUsesNaturalOrdering() {
        let games = [
            makeGame(id: 1, title: "Game 10", lastPlayed: nil),
            makeGame(id: 2, title: "Game 2", lastPlayed: nil)
        ]

        let result = LibraryQuery(sort: .title).apply(to: games)

        XCTAssertEqual(result.map(\.title), ["Game 2", "Game 10"])
    }

    private func makeGame(id: UInt8, title: String, lastPlayed: TimeInterval?) -> ImportedGame {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[15] = id
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))

        return ImportedGame(
            id: GameID(rawValue: uuid),
            title: title,
            engine: engine,
            compatibilityStatus: .notEvaluated,
            importedAt: .distantPast,
            lastPlayedAt: lastPlayed.map { Date(timeIntervalSince1970: $0) },
            installedByteCount: Int64(id)
        )
    }
}
