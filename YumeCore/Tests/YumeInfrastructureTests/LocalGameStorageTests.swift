import Foundation
import XCTest
import YumeDomain
@testable import YumeInfrastructure

@MainActor
final class LocalGameStorageTests: XCTestCase {
    func testPrepareCreatesFixedLayout() async throws {
        let fixture = try TemporaryStorageFixture()
        defer { fixture.remove() }
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)

        try await storage.prepareStorage()

        for url in [
            storage.layout.games,
            storage.layout.staging,
            storage.layout.cache,
            storage.layout.diagnostics
        ] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }

        XCTAssertFalse(
            try storage.layout.games.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
        )
        #if !os(Linux)
        XCTAssertTrue(
            try storage.layout.staging.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
        )
        #endif
    }

    func testManifestRoundTripAndOwnedPathDeduplication() async throws {
        let fixture = try TemporaryStorageFixture()
        defer { fixture.remove() }
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)
        let taskID = fixedTaskID(lastByte: 1)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let ownedPath = try StorageRelativePath(rawValue: "www/data/System.json")

        let workspace = try await storage.createStagingTask(id: taskID, createdAt: createdAt)
        try await storage.registerOwnedPath(ownedPath, for: taskID, updatedAt: createdAt.addingTimeInterval(1))
        try await storage.registerOwnedPath(ownedPath, for: taskID, updatedAt: createdAt.addingTimeInterval(2))
        try await storage.updateState(
            .paused(stage: .copyingToStaging),
            for: taskID,
            updatedAt: createdAt.addingTimeInterval(3)
        )
        let manifest = try await storage.loadManifest(for: taskID)

        XCTAssertEqual(workspace.taskID, taskID)
        XCTAssertEqual(workspace.contentRootURL.lastPathComponent, "content")
        XCTAssertEqual(manifest.taskID, taskID)
        XCTAssertEqual(manifest.createdAt, createdAt)
        XCTAssertEqual(manifest.updatedAt, createdAt.addingTimeInterval(3))
        XCTAssertEqual(manifest.ownedPaths, [ownedPath])
        XCTAssertEqual(manifest.state, .paused(stage: .copyingToStaging))
    }

    func testStagingTaskDiscoveryReturnsStableOrder() async throws {
        let fixture = try TemporaryStorageFixture()
        defer { fixture.remove() }
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)
        let laterTask = fixedTaskID(lastByte: 2)
        let earlierTask = fixedTaskID(lastByte: 1)
        _ = try await storage.createStagingTask(id: laterTask, createdAt: .distantPast)
        _ = try await storage.createStagingTask(id: earlierTask, createdAt: .distantPast)

        let discovered = try await storage.stagingTaskIDs()

        XCTAssertEqual(discovered, [earlierTask, laterTask])
    }

    func testStagingTaskDiscoveryReportsUnexpectedEntries() async throws {
        let fixture = try TemporaryStorageFixture()
        defer { fixture.remove() }
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)
        try await storage.prepareStorage()
        let unexpectedEntry = storage.layout.staging.appendingPathComponent("unknown-entry")
        try Data("unexpected".utf8).write(to: unexpectedEntry)

        do {
            _ = try await storage.stagingTaskIDs()
            XCTFail("Expected discovery to report an unexpected staging entry")
        } catch {
            XCTAssertEqual(
                error as? LocalGameStorage.StorageError,
                .unexpectedStagingEntry("unknown-entry")
            )
        }
    }

    func testDiscardIsIdempotentAndDoesNotTouchGamesOrSiblingTask() async throws {
        let fixture = try TemporaryStorageFixture()
        defer { fixture.remove() }
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)
        let firstTask = fixedTaskID(lastByte: 1)
        let secondTask = fixedTaskID(lastByte: 2)

        let firstWorkspace = try await storage.createStagingTask(id: firstTask, createdAt: .distantPast)
        let secondWorkspace = try await storage.createStagingTask(id: secondTask, createdAt: .distantPast)
        let committedSentinel = storage.layout.games.appendingPathComponent("committed-sentinel")
        try Data("keep".utf8).write(to: committedSentinel)

        try await storage.discardStagingTask(id: firstTask)
        try await storage.discardStagingTask(id: firstTask)

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstWorkspace.contentRootURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondWorkspace.contentRootURL.path))
        XCTAssertEqual(try Data(contentsOf: committedSentinel), Data("keep".utf8))
    }

    func testExistingWorkspaceWithoutManifestIsNotSilentlyDeleted() async throws {
        let fixture = try TemporaryStorageFixture()
        defer { fixture.remove() }
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)
        let taskID = fixedTaskID(lastByte: 3)
        try await storage.prepareStorage()

        let orphan = storage.layout.staging.appendingPathComponent(
            taskID.rawValue.uuidString.lowercased(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        let sentinel = orphan.appendingPathComponent("unknown-data")
        try Data("keep".utf8).write(to: sentinel)

        do {
            _ = try await storage.createStagingTask(id: taskID, createdAt: .distantPast)
            XCTFail("Expected workspace creation to reject an unowned existing directory")
        } catch {
            XCTAssertEqual(
                error as? LocalGameStorage.StorageError,
                .workspaceAlreadyExistsWithoutManifest
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testWorkspaceSymlinkIsRejectedWithoutTouchingTarget() async throws {
        let fixture = try TemporaryStorageFixture()
        defer { fixture.remove() }
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)
        let taskID = fixedTaskID(lastByte: 4)
        let workspace = try await storage.createStagingTask(id: taskID, createdAt: .distantPast)
        let taskRoot = workspace.contentRootURL.deletingLastPathComponent()
        let relocatedTaskRoot = fixture.container.appendingPathComponent("relocated-task", isDirectory: true)
        try FileManager.default.moveItem(at: taskRoot, to: relocatedTaskRoot)
        try FileManager.default.createSymbolicLink(at: taskRoot, withDestinationURL: relocatedTaskRoot)
        let targetSentinel = relocatedTaskRoot.appendingPathComponent("target-sentinel")
        try Data("keep".utf8).write(to: targetSentinel)

        do {
            _ = try await storage.loadManifest(for: taskID)
            XCTFail("Expected manifest loading to reject a workspace symlink")
        } catch {
            XCTAssertEqual(
                error as? LocalGameStorage.StorageError,
                .symbolicLinkAtManagedPath
            )
        }

        do {
            try await storage.discardStagingTask(id: taskID)
            XCTFail("Expected cleanup to reject a workspace symlink")
        } catch {
            XCTAssertEqual(
                error as? LocalGameStorage.StorageError,
                .symbolicLinkAtManagedPath
            )
        }
        XCTAssertEqual(try Data(contentsOf: targetSentinel), Data("keep".utf8))
    }

    func testRPGMakerRTPImportFindsWrappedAssetRootWithoutChangingSource() async throws {
        let fixture = try TemporaryStorageFixture()
        defer { fixture.remove() }
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)
        let wrapper = fixture.container.appendingPathComponent("vx ace/app", isDirectory: true)
        try writeRTPFixture(at: wrapper, sentinel: "ace")

        let package = try await storage.importRPGMakerRTP(
            variant: .vxAce,
            from: wrapper.deletingLastPathComponent()
        )

        XCTAssertEqual(package.id, "rgss-vx-ace")
        XCTAssertEqual(package.engineID, EngineID(rawValue: "rgss"))
        XCTAssertEqual(package.variant, .vxAce)
        XCTAssertEqual(package.fileCount, 2)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: storage.layout.rtp
                    .appendingPathComponent("rgss/rgss-vx-ace/Audio/BGM/theme.ogg")
                    .path
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: wrapper.appendingPathComponent("Audio/BGM/theme.ogg")),
            Data("ace".utf8)
        )
    }

    func testRPGMakerRTPVariantsMountOnlyForMatchingRGSSGeneration() async throws {
        let fixture = try TemporaryStorageFixture()
        defer { fixture.remove() }
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)
        let xpSource = fixture.container.appendingPathComponent("RTP XP", isDirectory: true)
        let aceSource = fixture.container.appendingPathComponent("RTP VX Ace/app", isDirectory: true)
        try writeRTPFixture(at: xpSource, sentinel: "xp")
        try writeRTPFixture(at: aceSource, sentinel: "ace")
        _ = try await storage.importRPGMakerRTP(variant: .xp, from: xpSource)
        _ = try await storage.importRPGMakerRTP(
            variant: .vxAce,
            from: aceSource.deletingLastPathComponent()
        )
        let xpGame = try writeRGSSGame(
            in: storage,
            scriptsPath: "Data/Scripts.rxdata"
        )
        let aceGame = try writeRGSSGame(
            in: storage,
            scriptsPath: "Game.rgss3a"
        )

        let xpMounts = try await storage.rtpMountRoots(for: xpGame)
        let aceMounts = try await storage.rtpMountRoots(for: aceGame)

        XCTAssertEqual(xpMounts.map(\.lastPathComponent), ["rgss-xp"])
        XCTAssertEqual(aceMounts.map(\.lastPathComponent), ["rgss-vx-ace"])

        let vxSource = fixture.container.appendingPathComponent("RTP VX", isDirectory: true)
        try writeRTPFixture(at: vxSource, sentinel: "vx")
        _ = try await storage.importRPGMakerRTP(variant: .vx, from: vxSource)
        let vxGame = try writeRGSSGame(
            in: storage,
            scriptsPath: "Data/Scripts.rvdata"
        )
        let vxMounts = try await storage.rtpMountRoots(for: vxGame)
        let xpMountsAfterVX = try await storage.rtpMountRoots(for: xpGame)
        let aceMountsAfterVX = try await storage.rtpMountRoots(for: aceGame)
        XCTAssertEqual(vxMounts.map(\.lastPathComponent), ["rgss-vx"])
        XCTAssertEqual(xpMountsAfterVX.map(\.lastPathComponent), ["rgss-xp"])
        XCTAssertEqual(aceMountsAfterVX.map(\.lastPathComponent), ["rgss-vx-ace"])
    }

    func testRPGMakerRTPImportAcceptsEachStandardAssetDirectoryAndInstallerWrappers() async throws {
        let fixture = try TemporaryStorageFixture()
        defer { fixture.remove() }
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)

        let layouts: [(RPGMakerRTPVariant, String)] = [
            (.xp, "Audio"),
            (.vx, "Graphics"),
            (.vxAce, "Fonts")
        ]
        for (variant, assetDirectoryName) in layouts {
            let wrapper = fixture.container.appendingPathComponent(
                "RTP-\(variant.rawValue)",
                isDirectory: true
            )
            let app = wrapper.appendingPathComponent("app", isDirectory: true)
            let assetDirectory = app.appendingPathComponent(assetDirectoryName, isDirectory: true)
            try FileManager.default.createDirectory(
                at: assetDirectory,
                withIntermediateDirectories: true
            )
            try Data(variant.rawValue.utf8).write(
                to: assetDirectory.appendingPathComponent("asset.dat")
            )
            if variant == .xp {
                let sys = wrapper.appendingPathComponent("sys", isDirectory: true)
                try FileManager.default.createDirectory(at: sys, withIntermediateDirectories: true)
                try Data("installer".utf8).write(to: sys.appendingPathComponent("setup.dat"))
            }

            let package = try await storage.importRPGMakerRTP(
                variant: variant,
                from: wrapper
            )
            XCTAssertEqual(package.fileCount, 1)
            let importedRoot = storage.layout.rtp
                .appendingPathComponent("rgss", isDirectory: true)
                .appendingPathComponent(variant.packageID, isDirectory: true)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: importedRoot
                        .appendingPathComponent("\(assetDirectoryName)/asset.dat")
                        .path
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: importedRoot.appendingPathComponent("sys/setup.dat").path
                )
            )
        }
    }

    func testRPGMakerRTPImportRejectsUnrelatedAndDuplicatePackagesPrecisely() async throws {
        let fixture = try TemporaryStorageFixture()
        defer { fixture.remove() }
        let storage = LocalGameStorage(baseURL: fixture.storageRoot)
        let unrelated = fixture.container.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("not RTP".utf8).write(to: unrelated.appendingPathComponent("readme.txt"))

        do {
            _ = try await storage.importRPGMakerRTP(variant: .vx, from: unrelated)
            XCTFail("Expected an unrelated directory to fail")
        } catch {
            XCTAssertEqual(error as? RTPStoreError, .invalidRPGMakerLayout)
        }

        let emptyAssetRoot = fixture.container.appendingPathComponent(
            "empty-asset-root",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: emptyAssetRoot.appendingPathComponent("Audio", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("not an asset".utf8).write(
            to: emptyAssetRoot.appendingPathComponent("readme.txt")
        )
        do {
            _ = try await storage.importRPGMakerRTP(variant: .vx, from: emptyAssetRoot)
            XCTFail("Expected an empty standard asset directory to fail")
        } catch {
            XCTAssertEqual(error as? RTPStoreError, .invalidRPGMakerLayout)
        }

        let valid = fixture.container.appendingPathComponent("valid", isDirectory: true)
        try writeRTPFixture(at: valid, sentinel: "vx")
        _ = try await storage.importRPGMakerRTP(variant: .vx, from: valid)
        do {
            _ = try await storage.importRPGMakerRTP(variant: .vx, from: valid)
            XCTFail("Expected a duplicate generation to fail")
        } catch {
            XCTAssertEqual(error as? RTPStoreError, .duplicateVariant(.vx))
        }
    }

    private func writeRTPFixture(at root: URL, sentinel: String) throws {
        let audio = root.appendingPathComponent("Audio/BGM", isDirectory: true)
        let graphics = root.appendingPathComponent("Graphics/System", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: graphics, withIntermediateDirectories: true)
        try Data(sentinel.utf8).write(to: audio.appendingPathComponent("theme.ogg"))
        try Data("window".utf8).write(to: graphics.appendingPathComponent("Window.png"))
    }

    private func writeRGSSGame(
        in storage: LocalGameStorage,
        scriptsPath: String
    ) throws -> ImportedGame {
        let engine = EngineDescriptor(
            id: EngineID(rawValue: "rgss"),
            displayName: "RGSS",
            compatibilityVersion: "test"
        )
        let game = ImportedGame(
            title: scriptsPath,
            engine: engine,
            compatibilityStatus: .runnable,
            importedAt: Date(timeIntervalSince1970: 0),
            installedByteCount: 1
        )
        let evidence = DetectionEvidence(
            relativePath: try StorageRelativePath(rawValue: scriptsPath),
            kind: .requiredFile,
            detailCode: "rgss.scripts",
            score: 100
        )
        let manifest = GameManifest(
            game: game,
            contentRoot: try StorageRelativePath(rawValue: "original"),
            detection: ProbeResult(
                engine: engine,
                rootRelativePath: try StorageRelativePath(rawValue: "original"),
                confidence: 100,
                evidence: [evidence],
                compatibility: CompatibilityReport(status: .runnable)
            )
        )
        let gameRoot = storage.layout.games.appendingPathComponent(
            game.id.rawValue.uuidString.lowercased(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: gameRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: gameRoot.appendingPathComponent("manifest.json"))
        return game
    }

    private func fixedTaskID(lastByte: UInt8) -> ImportTaskID {
        ImportTaskID(
            rawValue: UUID(uuid: (
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, lastByte
            ))
        )
    }
}

extension LocalGameStorageTests: @unchecked Sendable {}

private struct TemporaryStorageFixture {
    let container: URL
    let storageRoot: URL

    init() throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "yume-storage-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        storageRoot = container.appendingPathComponent("Application Support/Yume", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }
}
