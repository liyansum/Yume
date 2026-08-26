import Foundation
import XCTest
@testable import YumeApplication
import YumeDomain

@MainActor
final class ImportCoordinatorTests: XCTestCase {
    func testStartAdvancePauseAndResumePersistCheckpoints() async throws {
        let storage = FakeImportStagingStorage()
        let taskID = fixedTaskID(lastByte: 1)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = ImportCoordinator(storage: storage, now: { now })

        let started = try await coordinator.startTask(id: taskID)
        XCTAssertEqual(started.state, .active(stage: .picked))

        let advanced = try await coordinator.apply(.advance(to: .validatingSource), to: taskID)
        XCTAssertEqual(updatedManifest(from: advanced)?.state, .active(stage: .validatingSource))

        let paused = try await coordinator.apply(.pause, to: taskID)
        XCTAssertEqual(updatedManifest(from: paused)?.state, .paused(stage: .validatingSource))

        let repeatedPause = try await coordinator.apply(.pause, to: taskID)
        XCTAssertEqual(updatedManifest(from: repeatedPause)?.state, .paused(stage: .validatingSource))

        let resumed = try await coordinator.apply(.resume, to: taskID)
        XCTAssertEqual(updatedManifest(from: resumed)?.state, .active(stage: .validatingSource))
        let persistedManifest = await storage.manifest(for: taskID)
        XCTAssertEqual(persistedManifest?.updatedAt, now)
    }

    func testCancelCleansTaskAndRepeatedCancelIsExplicitlyIdempotent() async throws {
        let storage = FakeImportStagingStorage()
        let taskID = fixedTaskID(lastByte: 2)
        let coordinator = ImportCoordinator(storage: storage)
        _ = try await coordinator.startTask(id: taskID)

        let cancelled = try await coordinator.apply(.cancel, to: taskID)
        XCTAssertEqual(cancelled, .removed(taskID: taskID, finalState: .cancelled))
        let taskStillExists = try await storage.containsStagingTask(id: taskID)
        XCTAssertFalse(taskStillExists)

        let repeated = try await coordinator.apply(.cancel, to: taskID)
        XCTAssertEqual(repeated, .alreadyAbsent(taskID: taskID))
    }

    func testMissingTaskRejectsNonTerminalMutation() async throws {
        let storage = FakeImportStagingStorage()
        let taskID = fixedTaskID(lastByte: 3)
        let coordinator = ImportCoordinator(storage: storage)

        do {
            _ = try await coordinator.apply(.pause, to: taskID)
            XCTFail("Expected a missing task error")
        } catch {
            XCTAssertEqual(error as? ImportCoordinatorError, .taskNotFound(taskID))
        }

        do {
            _ = try await coordinator.apply(.fail(code: "  "), to: taskID)
            XCTFail("Expected action validation before the absent-task shortcut")
        } catch {
            XCTAssertEqual(error as? ImportTransitionError, .emptyFailureCode)
        }
    }

    func testRecoveryPausesActiveTasksAndCleansTerminalResidue() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let activeID = fixedTaskID(lastByte: 1)
        let pausedID = fixedTaskID(lastByte: 2)
        let terminalID = fixedTaskID(lastByte: 3)
        let unreadableID = fixedTaskID(lastByte: 4)
        let cleanupFailureID = fixedTaskID(lastByte: 5)
        let checkpointFailureID = fixedTaskID(lastByte: 6)
        let storage = FakeImportStagingStorage(
            manifests: [
                StagingManifest(
                    taskID: activeID,
                    state: .active(stage: .extractingToStaging),
                    createdAt: .distantPast
                ),
                StagingManifest(
                    taskID: pausedID,
                    state: .paused(stage: .budgeting),
                    createdAt: .distantPast
                ),
                StagingManifest(
                    taskID: terminalID,
                    state: .failed(code: "fixture.failure"),
                    createdAt: .distantPast
                ),
                StagingManifest(
                    taskID: unreadableID,
                    state: .active(stage: .picked),
                    createdAt: .distantPast
                ),
                StagingManifest(
                    taskID: cleanupFailureID,
                    state: .cancelled,
                    createdAt: .distantPast
                ),
                StagingManifest(
                    taskID: checkpointFailureID,
                    state: .active(stage: .copyingToStaging),
                    createdAt: .distantPast
                )
            ],
            unreadableTaskIDs: [unreadableID],
            updateFailureTaskIDs: [checkpointFailureID],
            cleanupFailureTaskIDs: [cleanupFailureID]
        )
        let coordinator = ImportCoordinator(storage: storage, now: { now })

        let report = try await coordinator.recoverInterruptedTasks()

        XCTAssertEqual(report.recovered.map(\.taskID), [activeID, pausedID])
        XCTAssertEqual(report.recovered[0].state, .paused(stage: .extractingToStaging))
        XCTAssertEqual(report.recovered[0].updatedAt, now)
        XCTAssertEqual(report.recovered[1].state, .paused(stage: .budgeting))
        XCTAssertEqual(report.discardedTerminalTaskIDs, [terminalID])
        XCTAssertEqual(
            Set(report.issues),
            Set([
                ImportRecoveryIssue(taskID: unreadableID, kind: .unreadableManifest),
                ImportRecoveryIssue(taskID: cleanupFailureID, kind: .terminalCleanupFailed),
                ImportRecoveryIssue(taskID: checkpointFailureID, kind: .checkpointWriteFailed)
            ])
        )
    }

    private func updatedManifest(from result: ImportMutationResult) -> StagingManifest? {
        guard case let .updated(manifest) = result else {
            XCTFail("Expected an updated manifest")
            return nil
        }
        return manifest
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

private actor FakeImportStagingStorage: ImportStagingStorage {
    enum FakeError: Error, Sendable {
        case unreadable
        case updateFailed
        case cleanupFailed
    }

    private var manifests: [ImportTaskID: StagingManifest]
    private let unreadableTaskIDs: Set<ImportTaskID>
    private let updateFailureTaskIDs: Set<ImportTaskID>
    private let cleanupFailureTaskIDs: Set<ImportTaskID>

    init(
        manifests: [StagingManifest] = [],
        unreadableTaskIDs: Set<ImportTaskID> = [],
        updateFailureTaskIDs: Set<ImportTaskID> = [],
        cleanupFailureTaskIDs: Set<ImportTaskID> = []
    ) {
        self.manifests = Dictionary(uniqueKeysWithValues: manifests.map { ($0.taskID, $0) })
        self.unreadableTaskIDs = unreadableTaskIDs
        self.updateFailureTaskIDs = updateFailureTaskIDs
        self.cleanupFailureTaskIDs = cleanupFailureTaskIDs
    }

    func prepareStorage() async throws {}

    func stagingTaskIDs() async throws -> [ImportTaskID] {
        manifests.keys.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }

    func containsStagingTask(id: ImportTaskID) async throws -> Bool {
        manifests[id] != nil
    }

    func createStagingTask(
        id: ImportTaskID,
        createdAt: Date
    ) async throws -> StagingWorkspace {
        if manifests[id] == nil {
            manifests[id] = StagingManifest(taskID: id, createdAt: createdAt)
        }
        return StagingWorkspace(
            taskID: id,
            contentRootURL: URL(fileURLWithPath: "/tmp/yume-fixture/\(id.rawValue.uuidString)")
        )
    }

    func loadManifest(for id: ImportTaskID) async throws -> StagingManifest {
        guard !unreadableTaskIDs.contains(id), let manifest = manifests[id] else {
            throw FakeError.unreadable
        }
        return manifest
    }

    func registerOwnedPath(
        _ path: StorageRelativePath,
        for id: ImportTaskID,
        updatedAt: Date
    ) async throws {
        guard var manifest = manifests[id] else { throw FakeError.unreadable }
        manifest.registerOwnedPath(path, at: updatedAt)
        manifests[id] = manifest
    }

    func updateState(
        _ state: ImportState,
        for id: ImportTaskID,
        updatedAt: Date
    ) async throws {
        guard !updateFailureTaskIDs.contains(id) else { throw FakeError.updateFailed }
        guard var manifest = manifests[id] else { throw FakeError.unreadable }
        manifest.transition(to: state, at: updatedAt)
        manifests[id] = manifest
    }

    func discardStagingTask(id: ImportTaskID) async throws {
        guard !cleanupFailureTaskIDs.contains(id) else { throw FakeError.cleanupFailed }
        manifests[id] = nil
    }

    func manifest(for id: ImportTaskID) -> StagingManifest? {
        manifests[id]
    }
}
