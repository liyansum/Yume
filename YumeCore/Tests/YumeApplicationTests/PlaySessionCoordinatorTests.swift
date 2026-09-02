import Foundation
import XCTest
import YumeDomain
@testable import YumeApplication

final class GameEngineCatalogTests: XCTestCase {
    func testCatalogDerivesHostingKindsFromDetectorAvailability() {
        let catalog = GameEngineCatalog(detectors: [
            CatalogFixtureDetector(id: "rpg-maker-mv", runtimeAvailable: true),
            CatalogFixtureDetector(id: "tyranoscript", runtimeAvailable: true),
            CatalogFixtureDetector(id: "renpy"),
            CatalogFixtureDetector(id: "flash")
        ])

        XCTAssertEqual(catalog.hostingKind(for: EngineID(rawValue: "rpg-maker-mv")), .restrictedWeb)
        XCTAssertEqual(catalog.hostingKind(for: EngineID(rawValue: "tyranoscript")), .restrictedWeb)
        XCTAssertEqual(catalog.hostingKind(for: EngineID(rawValue: "renpy")), .detectionOnly)
        XCTAssertEqual(catalog.hostingKind(for: EngineID(rawValue: "flash")), .detectionOnly)
        XCTAssertEqual(
            catalog.runnableEngineIDs,
            [EngineID(rawValue: "rpg-maker-mv"), EngineID(rawValue: "tyranoscript")]
        )
    }

    func testDedicatedRuntimeEnginesAreHostableWithoutWebShell() {
        let catalog = GameEngineCatalog(
            detectors: [CatalogFixtureDetector(id: "onscripter", runtimeAvailable: true)],
            webHostedEngines: []
        )

        XCTAssertEqual(catalog.hostingKind(for: EngineID(rawValue: "onscripter")), .dedicatedRuntime)
        XCTAssertTrue(catalog.canHostRuntime(for: EngineID(rawValue: "onscripter")))
    }

    func testUnknownEnginesDefaultToDetectionOnly() {
        let catalog = GameEngineCatalog(detectors: [])
        XCTAssertFalse(catalog.canHostRuntime(for: EngineID(rawValue: "anything")))
        XCTAssertNil(catalog.entry(for: EngineID(rawValue: "anything")))
        XCTAssertEqual(catalog.hostingKind(for: EngineID(rawValue: "anything")), .detectionOnly)
    }
}

@MainActor
final class PlaySessionCoordinatorTests: XCTestCase {
    func testStartReturnsLocationAndBlocksSecondGameWhileActive() async throws {
        let first = makeGame(engineID: "rpg-maker-mz")
        let second = makeGame(engineID: "rpg-maker-mv")
        let coordinator = makeCoordinator(games: [first, second])

        let location = try await coordinator.start(gameID: first.id)
        XCTAssertEqual(location.content.game.id, first.id)
        let activeAfterFirst = await coordinator.activeGameID()
        XCTAssertEqual(activeAfterFirst, first.id)

        do {
            _ = try await coordinator.start(gameID: second.id)
            XCTFail("Expected session exclusivity violation")
        } catch let error as PlaySessionError {
            XCTAssertEqual(error, .sessionAlreadyActive(active: first.id))
        }
    }

    func testStartingSameGameAgainIsRejectedWhileSessionIsActive() async throws {
        let game = makeGame(engineID: "rpg-maker-mz")
        let coordinator = makeCoordinator(games: [game])

        _ = try await coordinator.start(gameID: game.id)
        do {
            _ = try await coordinator.start(gameID: game.id)
            XCTFail("Expected session exclusivity violation")
        } catch let error as PlaySessionError {
            XCTAssertEqual(error, .sessionAlreadyActive(active: game.id))
        }
    }

    func testStopReleasesExclusiveSlot() async throws {
        let first = makeGame(engineID: "rpg-maker-mz")
        let second = makeGame(engineID: "rpg-maker-mv")
        let coordinator = makeCoordinator(games: [first, second])

        _ = try await coordinator.start(gameID: first.id)
        let stopped = await coordinator.stop()
        XCTAssertEqual(stopped, first.id)
        let activeAfterStop = await coordinator.activeGameID()
        XCTAssertNil(activeAfterStop)

        _ = try await coordinator.start(gameID: second.id)
        let activeAfterSecondStart = await coordinator.activeGameID()
        XCTAssertEqual(activeAfterSecondStart, second.id)
    }

    func testDetectionOnlyEngineIsRejectedBeforeContentAccess() async throws {
        let game = makeGame(engineID: "renpy")
        let provider = CountingContentProvider(locations: [:])
        let coordinator = PlaySessionCoordinator(
            library: FakeGameLibrary(games: [game]),
            contentProvider: provider,
            catalog: GameEngineCatalog(detectors: [
                CatalogFixtureDetector(id: "renpy")
            ])
        )

        do {
            _ = try await coordinator.start(gameID: game.id)
            XCTFail("Expected detection-only rejection")
        } catch let error as PlaySessionError {
            XCTAssertEqual(error, .runtimeUnavailable(EngineID(rawValue: "renpy")))
        }
        let accessCount = await provider.accessCount
        XCTAssertEqual(accessCount, 0, "Content must not be touched for detection-only engines")
        let active = await coordinator.activeGameID()
        XCTAssertNil(active)
    }

    func testMissingAndNonRunnableGamesAreRejected() async throws {
        let runnable = makeGame(engineID: "rpg-maker-mz")
        var unsupported = makeGame(engineID: "rpg-maker-mv")
        unsupported.compatibilityStatus = .unsupported

        let coordinator = makeCoordinator(games: [runnable], extraGames: [unsupported])

        do {
            _ = try await coordinator.start(gameID: GameID())
            XCTFail("Expected missing-game rejection")
        } catch let error as PlaySessionError {
            XCTAssertEqual(error, .gameNotFound)
        }

        do {
            _ = try await coordinator.start(gameID: unsupported.id)
            XCTFail("Expected non-runnable rejection")
        } catch let error as PlaySessionError {
            XCTAssertEqual(error, .gameNotRunnable(unsupported.id))
        }
    }
}

extension GameEngineCatalogTests: @unchecked Sendable {}
extension PlaySessionCoordinatorTests: @unchecked Sendable {}

private struct CatalogFixtureDetector: GameDetector {
    let descriptor: EngineDescriptor
    let runtimeAvailable: Bool

    init(id: String, runtimeAvailable: Bool = false) {
        self.descriptor = EngineDescriptor(
            id: EngineID(rawValue: id),
            displayName: id,
            compatibilityVersion: "test"
        )
        self.runtimeAvailable = runtimeAvailable
    }

    func probe(_ snapshot: DetectionSnapshot) -> ProbeResult? {
        nil
    }
}

private func makeGame(engineID: String) -> ImportedGame {
    ImportedGame(
        title: "Fixture \(engineID)",
        engine: EngineDescriptor(
            id: EngineID(rawValue: engineID),
            displayName: engineID,
            compatibilityVersion: "test"
        ),
        compatibilityStatus: .runnable,
        importedAt: Date(timeIntervalSince1970: 1_700_000_000),
        installedByteCount: 128
    )
}

private func makeLocation(game: ImportedGame) -> GameContentLocation {
    GameContentLocation(
        game: game,
        rootURL: URL(fileURLWithPath: "/tmp/yume-fixture/\(game.id.rawValue.uuidString)"),
        saveRootURL: URL(fileURLWithPath: "/tmp/yume-fixture/\(game.id.rawValue.uuidString)/saves"),
        webEntryPoint: try! StorageRelativePath(rawValue: "index.html")
    )
}

private func makeCoordinator(
    games: [ImportedGame],
    extraGames: [ImportedGame] = []
) -> PlaySessionCoordinator {
    let allGames = games + extraGames
    let locations = Dictionary(uniqueKeysWithValues: allGames.map { ($0.id, makeLocation(game: $0)) })
    return PlaySessionCoordinator(
        library: FakeGameLibrary(games: allGames),
        contentProvider: FakeContentProvider(locations: locations),
        catalog: GameEngineCatalog(detectors: [
            CatalogFixtureDetector(id: "rpg-maker-mz", runtimeAvailable: true),
            CatalogFixtureDetector(id: "rpg-maker-mv", runtimeAvailable: true),
            CatalogFixtureDetector(id: "renpy")
        ])
    )
}

private actor FakeGameLibrary: GameLibrary {
    private let games: [ImportedGame]

    init(games: [ImportedGame]) {
        self.games = games
    }

    func allGames() async throws -> [ImportedGame] {
        games
    }

    func markPlayed(id: GameID, at date: Date) async throws {}
}

private struct FakeContentProvider: GameContentProvider {
    let locations: [GameID: GameContentLocation]

    func contentLocation(for id: GameID) async throws -> GameContentLocation {
        guard let location = locations[id] else {
            throw GameContentError.gameNotFound
        }
        return location
    }
}

private actor CountingContentProvider: GameContentProvider {
    let locations: [GameID: GameContentLocation]
    private(set) var accessCount = 0

    init(locations: [GameID: GameContentLocation]) {
        self.locations = locations
    }

    func contentLocation(for id: GameID) async throws -> GameContentLocation {
        accessCount += 1
        guard let location = locations[id] else {
            throw GameContentError.gameNotFound
        }
        return location
    }
}
