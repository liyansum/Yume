import Foundation
import XCTest
@testable import YumeDomain

final class GameModelsTests: XCTestCase {
    func testImportedGameRoundTripsThroughJSON() throws {
        let game = ImportedGame(
            id: GameID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            title: "Moonlit Archive",
            engine: EngineDescriptor(
                id: EngineID(rawValue: "fixture.engine"),
                displayName: "Fixture Engine",
                compatibilityVersion: "0.1"
            ),
            compatibilityStatus: .notEvaluated,
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            installedByteCount: 512
        )

        let encoded = try JSONEncoder().encode(game)
        let decoded = try JSONDecoder().decode(ImportedGame.self, from: encoded)

        XCTAssertEqual(decoded, game)
    }

    func testImportStatePreservesStage() throws {
        let state = ImportState.paused(stage: .extractingToStaging)
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ImportState.self, from: encoded)

        XCTAssertEqual(decoded, state)
    }
}
