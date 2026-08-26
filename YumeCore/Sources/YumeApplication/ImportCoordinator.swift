import Foundation
import YumeDomain

public enum ImportMutationResult: Equatable, Sendable {
    case updated(StagingManifest)
    case removed(taskID: ImportTaskID, finalState: ImportState)
    case alreadyAbsent(taskID: ImportTaskID)
}

public enum ImportCoordinatorError: Error, Equatable, Sendable {
    case taskNotFound(ImportTaskID)
}

public enum ImportRecoveryIssueKind: Hashable, Sendable {
    case unreadableManifest
    case checkpointWriteFailed
    case terminalCleanupFailed
}

public struct ImportRecoveryIssue: Hashable, Sendable {
    public let taskID: ImportTaskID
    public let kind: ImportRecoveryIssueKind

    public init(taskID: ImportTaskID, kind: ImportRecoveryIssueKind) {
        self.taskID = taskID
        self.kind = kind
    }
}

public struct ImportRecoveryReport: Equatable, Sendable {
    public let recovered: [StagingManifest]
    public let discardedTerminalTaskIDs: [ImportTaskID]
    public let issues: [ImportRecoveryIssue]

    public init(
        recovered: [StagingManifest],
        discardedTerminalTaskIDs: [ImportTaskID],
        issues: [ImportRecoveryIssue]
    ) {
        self.recovered = recovered
        self.discardedTerminalTaskIDs = discardedTerminalTaskIDs
        self.issues = issues
    }
}

public actor ImportCoordinator {
    private let storage: any ImportStagingStorage
    private let now: @Sendable () -> Date

    public init(
        storage: any ImportStagingStorage,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storage = storage
        self.now = now
    }

    public func startTask(id: ImportTaskID = ImportTaskID()) async throws -> StagingManifest {
        if try await storage.containsStagingTask(id: id) {
            return try await storage.loadManifest(for: id)
        }

        _ = try await storage.createStagingTask(id: id, createdAt: now())
        return try await storage.loadManifest(for: id)
    }

    public func apply(
        _ action: ImportAction,
        to taskID: ImportTaskID
    ) async throws -> ImportMutationResult {
        try ImportStateMachine.validate(action: action)

        guard try await storage.containsStagingTask(id: taskID) else {
            if action.isTerminalRequest {
                return .alreadyAbsent(taskID: taskID)
            }
            throw ImportCoordinatorError.taskNotFound(taskID)
        }

        var manifest = try await storage.loadManifest(for: taskID)
        let nextState = try ImportStateMachine.transition(from: manifest.state, action: action)

        if nextState != manifest.state {
            let updatedAt = now()
            try await storage.updateState(nextState, for: taskID, updatedAt: updatedAt)
            manifest.transition(to: nextState, at: updatedAt)
        }

        if nextState.isTerminal {
            try await storage.discardStagingTask(id: taskID)
            return .removed(taskID: taskID, finalState: nextState)
        }

        return .updated(manifest)
    }

    public func recoverInterruptedTasks() async throws -> ImportRecoveryReport {
        let taskIDs = try await storage.stagingTaskIDs()
        var recovered: [StagingManifest] = []
        var discardedTerminalTaskIDs: [ImportTaskID] = []
        var issues: [ImportRecoveryIssue] = []

        for taskID in taskIDs {
            let manifest: StagingManifest
            do {
                manifest = try await storage.loadManifest(for: taskID)
            } catch {
                issues.append(ImportRecoveryIssue(taskID: taskID, kind: .unreadableManifest))
                continue
            }

            if manifest.state.isTerminal {
                do {
                    try await storage.discardStagingTask(id: taskID)
                    discardedTerminalTaskIDs.append(taskID)
                } catch {
                    issues.append(ImportRecoveryIssue(taskID: taskID, kind: .terminalCleanupFailed))
                }
                continue
            }

            switch manifest.state {
            case let .active(stage):
                let pausedState = ImportState.paused(stage: stage)
                let updatedAt = now()
                do {
                    try await storage.updateState(pausedState, for: taskID, updatedAt: updatedAt)
                    var pausedManifest = manifest
                    pausedManifest.transition(to: pausedState, at: updatedAt)
                    recovered.append(pausedManifest)
                } catch {
                    issues.append(ImportRecoveryIssue(taskID: taskID, kind: .checkpointWriteFailed))
                }
            case .paused:
                recovered.append(manifest)
            case .cancelled, .failed(_), .completed(_):
                break
            }
        }

        return ImportRecoveryReport(
            recovered: recovered,
            discardedTerminalTaskIDs: discardedTerminalTaskIDs,
            issues: issues
        )
    }
}

private extension ImportAction {
    var isTerminalRequest: Bool {
        switch self {
        case .cancel, .fail(_), .complete(_):
            true
        case .advance(_), .pause, .resume:
            false
        }
    }
}

private extension ImportState {
    var isTerminal: Bool {
        switch self {
        case .cancelled, .failed(_), .completed(_):
            true
        case .active(_), .paused(_):
            false
        }
    }
}
