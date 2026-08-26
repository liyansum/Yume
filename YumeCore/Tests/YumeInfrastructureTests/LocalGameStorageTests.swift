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
        XCTAssertTrue(
            try storage.layout.staging.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
        )
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
