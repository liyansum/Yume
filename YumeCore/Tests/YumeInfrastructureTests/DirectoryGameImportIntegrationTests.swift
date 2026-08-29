import Foundation
import XCTest
import YumeApplication
import YumeDomain
@testable import YumeInfrastructure

@MainActor
final class DirectoryGameImportIntegrationTests: XCTestCase {
    private func makeStorage(for fixture: ImportFixture) -> LocalGameStorage {
        LocalGameStorage(baseURL: fixture.storageRoot) { _ in
            LocalGameStorage.VolumeCapacity(
                availableByteCount: 100 * 1_073_741_824,
                totalByteCount: 100 * 1_073_741_824
            )
        }
    }

    func testRPGMakerMZFolderImportsAtomicallyAndPersistsInLibrary() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.makeMZGame()
        let storage = makeStorage(for: fixture)
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

    func testPackagedRPGMakerVXAceFolderImportsWithoutExtractedDataDirectory() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.makePackagedVXAceGame()
        let storage = makeStorage(for: fixture)
        let service = DirectoryGameImportService(
            storage: storage,
            detectors: BuiltInGameDetectors.registry
        )

        let imported = try await service.importDirectory(at: fixture.sourceRoot)
        let location = try await storage.contentLocation(for: imported.id)

        XCTAssertEqual(imported.engine.id.rawValue, "rgss")
        XCTAssertEqual(imported.compatibilityStatus, .runnable)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: location.rootURL.appendingPathComponent("Game.rgss3a").path
            )
        )
    }

    func testRPGMakerMZZIPImportsThroughExtractionDetectionAndCommit() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let archiveURL = fixture.container.appendingPathComponent("Fixture Game.zip")
        try ImportZIPBuilder.make([
            .init(name: "Fixture Game/index.html", data: Data("<!doctype html>".utf8), crc32: 0x87b9ec48),
            .init(
                name: "Fixture Game/js/rmmz_core.js",
                data: Data("// self-authored test runtime marker".utf8),
                crc32: 0x6462440d
            ),
            .init(
                name: "Fixture Game/data/System.json",
                data: Data("{\"gameTitle\":\"Fixture\"}".utf8),
                crc32: 0x30c550a9
            )
        ]).write(to: archiveURL)

        let storage = makeStorage(for: fixture)
        let service = DirectoryGameImportService(
            storage: storage,
            detectors: BuiltInGameDetectors.registry,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let imported = try await service.importZIP(at: archiveURL)
        let location = try await storage.contentLocation(for: imported.id)

        XCTAssertEqual(imported.engine.id.rawValue, "rpg-maker-mz")
        XCTAssertEqual(imported.title, "Fixture Game")
        XCTAssertEqual(location.webEntryPoint?.rawValue, "index.html")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: location.rootURL.appendingPathComponent("js/rmmz_core.js").path
            )
        )
        let stagingTaskIDs = try await storage.stagingTaskIDs()
        XCTAssertTrue(stagingTaskIDs.isEmpty)
    }

    func testEncrypted7zImportsWithTransientPassword() async throws {
        let fixture = try ImportFixture()
        let archive = try SevenZipFixture()
        defer {
            fixture.remove()
            archive.remove()
        }
        try archive.makeArchive(
            [
                ("Fixture Game/index.html", Data("<!doctype html>".utf8)),
                (
                    "Fixture Game/js/rmmz_core.js",
                    Data("// self-authored test runtime marker".utf8)
                ),
                ("Fixture Game/data/System.json", Data("{}".utf8))
            ],
            password: "temporary-password",
            encryptHeader: true
        )
        let storage = makeStorage(for: fixture)
        let service = DirectoryGameImportService(
            storage: storage,
            detectors: BuiltInGameDetectors.registry
        )

        let imported = try await service.import7z(
            at: archive.archiveURL,
            password: "temporary-password"
        )
        let location = try await storage.contentLocation(for: imported.id)

        XCTAssertEqual(imported.engine.id.rawValue, "rpg-maker-mz")
        XCTAssertEqual(location.webEntryPoint?.rawValue, "index.html")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: location.rootURL.appendingPathComponent("data/System.json").path
            )
        )
        let stagingTaskIDs = try await storage.stagingTaskIDs()
        XCTAssertTrue(stagingTaskIDs.isEmpty)
    }

    func testUnsupportedNativePluginFailsClosedAndCleansStaging() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.makeMZGame(nativePlugin: true)
        let storage = makeStorage(for: fixture)
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
        let rootNames = try FileManager.default.contentsOfDirectory(atPath: fixture.sourceRoot.path)
        guard rootNames.contains("data"), rootNames.contains("DATA") else {
            throw XCTSkip("The test volume is case-insensitive and cannot represent both paths")
        }
        let storage = makeStorage(for: fixture)

        do {
            _ = try await storage.validateDirectorySource(at: fixture.sourceRoot)
            XCTFail("Expected case-insensitive path collision rejection")
        } catch let error as LocalGameStorage.StorageError {
            guard case .caseInsensitivePathCollision = error else {
                return XCTFail("Unexpected storage error: \(error)")
            }
        }
    }

    func testInsufficientCapacityFailsBeforeCopyAndCleansStaging() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.makeMZGame()
        let storage = LocalGameStorage(baseURL: fixture.storageRoot) { _ in
            LocalGameStorage.VolumeCapacity(
                availableByteCount: 1_024,
                totalByteCount: 100 * 1_073_741_824
            )
        }
        let service = DirectoryGameImportService(
            storage: storage,
            detectors: BuiltInGameDetectors.registry
        )

        do {
            _ = try await service.importDirectory(at: fixture.sourceRoot)
            XCTFail("Expected the production reserve to reject the import")
        } catch let GameImportError.insufficientStorage(budget) {
            XCTAssertFalse(budget.hasSufficientCapacity)
            XCTAssertEqual(budget.availableByteCount, 1_024)
            XCTAssertEqual(budget.reserveByteCount, 5 * 1_073_741_824)
        }

        let taskIDs = try await storage.stagingTaskIDs()
        let games = try await storage.allGames()
        XCTAssertTrue(taskIDs.isEmpty)
        XCTAssertTrue(games.isEmpty)
    }

    func testMarkPlayedAndRemoveUpdatePersistentLibrary() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try fixture.makeMZGame()
        let storage = makeStorage(for: fixture)
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
        let storage = makeStorage(for: fixture)
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
        let storage = makeStorage(for: fixture)
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
        let storage = makeStorage(for: fixture)
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
        let storage = makeStorage(for: fixture)
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
        let storage = makeStorage(for: fixture)
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
        let storage = makeStorage(for: fixture)
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

    func makePackagedVXAceGame() throws {
        try write("[Game]\nLibrary=System/RGSS301.dll\n", to: "Game.ini")
        try write("self-authored executable placeholder", to: "Game.exe")
        var archive = Data(Array("RGSSAD\0".utf8))
        archive.append(0x03)
        archive.append(Data(repeating: 0xA5, count: 32))
        try archive.write(to: sourceRoot.appendingPathComponent("Game.rgss3a"))
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

private enum ImportZIPBuilder {
    struct Entry {
        let name: String
        let data: Data
        let crc32: UInt32
    }

    static func make(_ entries: [Entry]) -> Data {
        var archive = Data()
        var centralDirectory = Data()

        for entry in entries {
            let name = Data(entry.name.utf8)
            let localOffset = UInt32(archive.count)
            archive.appendLittleEndian(UInt32(0x04034b50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(entry.crc32)
            archive.appendLittleEndian(UInt32(entry.data.count))
            archive.appendLittleEndian(UInt32(entry.data.count))
            archive.appendLittleEndian(UInt16(name.count))
            archive.appendLittleEndian(UInt16(0))
            archive.append(name)
            archive.append(entry.data)

            centralDirectory.appendLittleEndian(UInt32(0x02014b50))
            centralDirectory.appendLittleEndian(UInt16(0x0314))
            centralDirectory.appendLittleEndian(UInt16(20))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(entry.crc32)
            centralDirectory.appendLittleEndian(UInt32(entry.data.count))
            centralDirectory.appendLittleEndian(UInt32(entry.data.count))
            centralDirectory.appendLittleEndian(UInt16(name.count))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt32(0x81a40000))
            centralDirectory.appendLittleEndian(localOffset)
            centralDirectory.append(name)
        }

        let centralOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.appendLittleEndian(UInt32(0x06054b50))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt32(centralDirectory.count))
        archive.appendLittleEndian(centralOffset)
        archive.appendLittleEndian(UInt16(0))
        return archive
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
