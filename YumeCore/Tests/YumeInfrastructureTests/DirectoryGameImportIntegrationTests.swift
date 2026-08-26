import Foundation
import XCTest
import YumeApplication
import YumeDomain
@testable import YumeInfrastructure

@MainActor
final class DirectoryGameImportIntegrationTests: XCTestCase {
    func testRPGMakerMZFolderImportsAtomicallyAndPersistsInLibrary() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.makeMZGame()
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)
        let service = DirectoryGameImportService(
            storage: storage,
            detectors: BuiltInGameDetectors.registry,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let imported = try await service.importDirectory(at: fixture.sourceRoot)
        let games = try await storage.allGames()
        let taskIDs = try await storage.stagingTaskIDs()
        let installedRoot = storage.layout.games.appendingPathComponent(
            imported.id.rawValue.uuidString.lowercased(),
            isDirectory: true
        )

        XCTAssertEqual(games, [imported])
        XCTAssertEqual(imported.engine.id.rawValue, "rpg-maker-mz")
        XCTAssertEqual(imported.compatibilityStatus, .runnable)
        XCTAssertGreaterThan(imported.installedByteCount, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: installedRoot.appendingPathComponent("original/js/rmmz_core.js").path
            )
        )
        XCTAssertTrue(taskIDs.isEmpty)
    }

    func testUnsupportedNativePluginFailsClosedAndCleansStaging() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.makeMZGame(nativePlugin: true)
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)
        let service = DirectoryGameImportService(
            storage: storage,
            detectors: BuiltInGameDetectors.registry
        )

        do {
            _ = try await service.importDirectory(at: fixture.sourceRoot)
            XCTFail("Expected the native plugin to block the import")
        } catch let GameImportError.unsupportedGame(report) {
            XCTAssertEqual(report.status, .unsupported)
        }

        let games = try await storage.allGames()
        let taskIDs = try await storage.stagingTaskIDs()
        XCTAssertTrue(games.isEmpty)
        XCTAssertTrue(taskIDs.isEmpty)
    }

    func testCaseInsensitiveCollisionIsRejectedBeforeCopy() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.makeMZGame()
        try fixture.write("duplicate", to: "DATA/system.json")
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)

        do {
            _ = try await storage.validateDirectorySource(at: fixture.sourceRoot)
            XCTFail("Expected case-insensitive path collision rejection")
        } catch let error as LocalGameStorage.StorageError {
            guard case .caseInsensitivePathCollision = error else {
                return XCTFail("Unexpected storage error: \(error)")
            }
        }
    }

    func testMarkPlayedAndRemoveUpdatePersistentLibrary() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.makeMZGame()
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)
        let service = DirectoryGameImportService(
            storage: storage,
            detectors: BuiltInGameDetectors.registry
        )
        let imported = try await service.importDirectory(at: fixture.sourceRoot)
        let playedAt = Date(timeIntervalSince1970: 1_800_000_000)

        try await storage.markPlayed(id: imported.id, at: playedAt)
        let updatedGame = try await storage.game(id: imported.id)
        XCTAssertEqual(updatedGame?.lastPlayedAt, playedAt)

        try await storage.removeGame(id: imported.id, policy: .preserveSaves)
        let removedGame = try await storage.game(id: imported.id)
        XCTAssertNil(removedGame)
    }

    func testSaveExportAndImportRoundTripReplacesSaveDirectory() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.makeMZGame()
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)
        let service = DirectoryGameImportService(
            storage: storage,
            detectors: BuiltInGameDetectors.registry
        )
        let imported = try await service.importDirectory(at: fixture.sourceRoot)
        let location = try await storage.contentLocation(for: imported.id)
        let saveURL = location.saveRootURL.appendingPathComponent("slot1.json")
        try Data("original-save".utf8).write(to: saveURL)

        let packageURL = try await storage.exportSaves(for: imported.id)
        try Data("changed-save".utf8).write(to: saveURL)
        try await storage.importSaves(from: packageURL, for: imported.id)

        XCTAssertEqual(try Data(contentsOf: saveURL), Data("original-save".utf8))
    }

    func testRemovingGameCanPreserveSavesAsDetachedData() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.makeMZGame()
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)
        let service = DirectoryGameImportService(
            storage: storage,
            detectors: BuiltInGameDetectors.registry
        )
        let imported = try await service.importDirectory(at: fixture.sourceRoot)
        let location = try await storage.contentLocation(for: imported.id)
        try Data("keep-me".utf8).write(
            to: location.saveRootURL.appendingPathComponent("slot1.json")
        )

        let breakdown = try await storage.storageBreakdown(for: imported.id)
        try await storage.removeGame(id: imported.id, policy: .preserveSaves)
        let detachedSave = storage.layout.detachedSaves.appendingPathComponent(
            "\(imported.id.rawValue.uuidString.lowercased())/saves/slot1.json"
        )

        XCTAssertEqual(breakdown.saveByteCount, Int64("keep-me".utf8.count))
        XCTAssertEqual(try Data(contentsOf: detachedSave), Data("keep-me".utf8))
        let removed = try await storage.game(id: imported.id)
        XCTAssertNil(removed)
    }

    func testDuplicateImportIsRejectedWithoutChangingExistingGame() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.makeMZGame()
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)
        let service = DirectoryGameImportService(
            storage: storage,
            detectors: BuiltInGameDetectors.registry
        )
        let first = try await service.importDirectory(at: fixture.sourceRoot)

        do {
            _ = try await service.importDirectory(at: fixture.sourceRoot)
            XCTFail("Expected duplicate import rejection")
        } catch let GameImportError.duplicateGame(existing) {
            XCTAssertEqual(existing.id, first.id)
        }

        let games = try await storage.allGames()
        let stagingTaskIDs = try await storage.stagingTaskIDs()
        XCTAssertEqual(games.map(\.id), [first.id])
        XCTAssertEqual(games.first?.contentFingerprint, first.contentFingerprint)
        XCTAssertTrue(stagingTaskIDs.isEmpty)
    }

    func testExactReimportReattachesPreservedSaves() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.makeMZGame()
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)
        let service = DirectoryGameImportService(
            storage: storage,
            detectors: BuiltInGameDetectors.registry
        )
        let first = try await service.importDirectory(at: fixture.sourceRoot)
        let firstLocation = try await storage.contentLocation(for: first.id)
        try Data("reattach-me".utf8).write(
            to: firstLocation.saveRootURL.appendingPathComponent("slot2.json")
        )
        try await storage.removeGame(id: first.id, policy: .preserveSaves)

        let second = try await service.importDirectory(at: fixture.sourceRoot)
        let secondLocation = try await storage.contentLocation(for: second.id)
        let restored = try Data(
            contentsOf: secondLocation.saveRootURL.appendingPathComponent("slot2.json")
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.contentFingerprint, second.contentFingerprint)
        XCTAssertEqual(restored, Data("reattach-me".utf8))
        let detachedEntries = try FileManager.default.contentsOfDirectory(
            atPath: storage.layout.detachedSaves.path
        )
        XCTAssertTrue(detachedEntries.isEmpty)
    }

    func testDuplicateCanBeKeptAsSecondCopy() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.makeMZGame()
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)
        let service = DirectoryGameImportService(
            storage: storage,
            detectors: BuiltInGameDetectors.registry
        )
        let first = try await service.importDirectory(at: fixture.sourceRoot)
        let second = try await service.importDirectory(
            at: fixture.sourceRoot,
            resolveDuplicate: { _ in .keepBoth }
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.contentFingerprint, second.contentFingerprint)
        let keptGames = try await storage.allGames()
        XCTAssertEqual(keptGames.count, 2)
    }

    func testDuplicateReplacementKeepsIdentityAndSaves() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.makeMZGame()
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)
        let service = DirectoryGameImportService(
            storage: storage,
            detectors: BuiltInGameDetectors.registry
        )
        let first = try await service.importDirectory(at: fixture.sourceRoot)
        let firstLocation = try await storage.contentLocation(for: first.id)
        try Data("replacement-save".utf8).write(
            to: firstLocation.saveRootURL.appendingPathComponent("slot3.json")
        )

        let replacement = try await service.importDirectory(
            at: fixture.sourceRoot,
            resolveDuplicate: { _ in .replaceExisting }
        )
        let replacementLocation = try await storage.contentLocation(for: replacement.id)
        let savedData = try Data(
            contentsOf: replacementLocation.saveRootURL.appendingPathComponent("slot3.json")
        )

        XCTAssertEqual(replacement.id, first.id)
        XCTAssertEqual(savedData, Data("replacement-save".utf8))
        let replacedGames = try await storage.allGames()
        XCTAssertEqual(replacedGames.count, 1)
    }
}

extension DirectoryGameImportIntegrationTests: @unchecked Sendable {}

private struct ImportFixture {
    let container: URL
    let storageRoot: URL
    let sourceRoot: URL

    init() throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "yume-import-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        storageRoot = container.appendingPathComponent("Application Support/Yume", isDirectory: true)
        sourceRoot = container.appendingPathComponent("Fixture Game", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    }

    func makeMZGame(nativePlugin: Bool = false) throws {
        try write("<!doctype html>", to: "index.html")
        try write("// self-authored test runtime marker", to: "js/rmmz_core.js")
        try write("{\"gameTitle\":\"Fixture\"}", to: "data/System.json")
        if nativePlugin {
            try write("not executable fixture data", to: "native/plugin.node")
        }
    }

    func write(_ value: String, to relativePath: String) throws {
        let url = sourceRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }
}
