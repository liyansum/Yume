import Foundation
import YumeDomain

public struct StagingWorkspace: Sendable, Equatable {
    public let taskID: ImportTaskID
    public let contentRootURL: URL

    public init(taskID: ImportTaskID, contentRootURL: URL) {
        self.taskID = taskID
        self.contentRootURL = contentRootURL
    }
}

public protocol ImportStagingStorage: Sendable {
    func prepareStorage() async throws
    func stagingTaskIDs() async throws -> [ImportTaskID]
    func createStagingTask(id: ImportTaskID, createdAt: Date) async throws -> StagingWorkspace
    func loadManifest(for id: ImportTaskID) async throws -> StagingManifest
    func registerOwnedPath(
        _ path: StorageRelativePath,
        for id: ImportTaskID,
        updatedAt: Date
    ) async throws
    func updateState(
        _ state: ImportState,
        for id: ImportTaskID,
        updatedAt: Date
    ) async throws
    func discardStagingTask(id: ImportTaskID) async throws
}
