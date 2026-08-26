import Foundation
import YumeDomain

public struct StagedSourceSummary: Sendable, Equatable {
    public let sourceRelativePath: StorageRelativePath
    public let byteCount: Int64
    public let fileCount: Int
    public let contentFingerprint: String

    public init(
        sourceRelativePath: StorageRelativePath,
        byteCount: Int64,
        fileCount: Int,
        contentFingerprint: String
    ) {
        self.sourceRelativePath = sourceRelativePath
        self.byteCount = byteCount
        self.fileCount = fileCount
        self.contentFingerprint = contentFingerprint
    }
}

public protocol GameImportStorage: ImportStagingStorage {
    func validateDirectorySource(at sourceURL: URL) async throws -> StorageBudget
    func validateZIPSource(at sourceURL: URL) async throws -> StorageBudget
    func stageDirectory(
        at sourceURL: URL,
        for taskID: ImportTaskID
    ) async throws -> StagedSourceSummary
    func stageZIP(
        at sourceURL: URL,
        for taskID: ImportTaskID
    ) async throws -> StagedSourceSummary
    func detectionSnapshots(for taskID: ImportTaskID) async throws -> [DetectionSnapshot]
    func game(matchingContentFingerprint fingerprint: String) async throws -> ImportedGame?
    func commitStagedGame(
        taskID: ImportTaskID,
        manifest: GameManifest,
        replacing existingGameID: GameID?
    ) async throws
}

public enum DuplicateImportResolution: Hashable, Sendable {
    case cancel
    case keepBoth
    case replaceExisting
}

public enum GameImportError: Error, Equatable, Sendable {
    case insufficientStorage(StorageBudget)
    case noSupportedGameFound
    case ambiguousDetection([ProbeResult])
    case unsupportedGame(CompatibilityReport)
    case duplicateGame(ImportedGame)
}

public enum GameImportProgress: Equatable, Sendable {
    case validating
    case budgeting(StorageBudget)
    case copying
    case detecting
    case committing
}

public actor DirectoryGameImportService {
    public typealias ProgressHandler = @Sendable (GameImportProgress) async -> Void
    public typealias DetectionResolver = @Sendable ([ProbeResult]) async -> ProbeResult?
    public typealias DuplicateResolver = @Sendable (ImportedGame) async -> DuplicateImportResolution

    private let storage: any GameImportStorage
    private let coordinator: ImportCoordinator
    private let detectors: DetectorRegistry
    private let now: @Sendable () -> Date
    private let diagnostics: (any DiagnosticStore)?

    public init(
        storage: any GameImportStorage,
        detectors: DetectorRegistry,
        diagnostics: (any DiagnosticStore)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storage = storage
        self.coordinator = ImportCoordinator(storage: storage, now: now)
        self.detectors = detectors
        self.diagnostics = diagnostics
        self.now = now
    }

    public func recoverInterruptedTasks() async throws -> ImportRecoveryReport {
        try await coordinator.recoverInterruptedTasks()
    }

    public func importDirectory(
        at sourceURL: URL,
        progress: ProgressHandler? = nil,
        resolveDetection: DetectionResolver? = nil,
        resolveDuplicate: DuplicateResolver? = nil
    ) async throws -> ImportedGame {
        try await importSource(
            .directory,
            at: sourceURL,
            progress: progress,
            resolveDetection: resolveDetection,
            resolveDuplicate: resolveDuplicate
        )
    }

    public func importZIP(
        at sourceURL: URL,
        progress: ProgressHandler? = nil,
        resolveDetection: DetectionResolver? = nil,
        resolveDuplicate: DuplicateResolver? = nil
    ) async throws -> ImportedGame {
        try await importSource(
            .zip,
            at: sourceURL,
            progress: progress,
            resolveDetection: resolveDetection,
            resolveDuplicate: resolveDuplicate
        )
    }

    private enum SourceKind {
        case directory
        case zip
    }

    private func importSource(
        _ sourceKind: SourceKind,
        at sourceURL: URL,
        progress: ProgressHandler?,
        resolveDetection: DetectionResolver?,
        resolveDuplicate: DuplicateResolver?
    ) async throws -> ImportedGame {
        let taskID = ImportTaskID()
        _ = try await coordinator.startTask(id: taskID)
        await record(.information, code: "import.started", taskID: taskID)

        do {
            await progress?(.validating)
            try await advance(taskID, to: .validatingSource)
            let budget: StorageBudget
            switch sourceKind {
            case .directory:
                budget = try await storage.validateDirectorySource(at: sourceURL)
            case .zip:
                budget = try await storage.validateZIPSource(at: sourceURL)
            }

            try await advance(taskID, to: .budgeting)
            await progress?(.budgeting(budget))
            guard budget.hasSufficientCapacity else {
                throw GameImportError.insufficientStorage(budget)
            }

            try await advance(taskID, to: .copyingToStaging)
            await progress?(.copying)
            let summary: StagedSourceSummary
            switch sourceKind {
            case .directory:
                summary = try await storage.stageDirectory(at: sourceURL, for: taskID)
            case .zip:
                summary = try await storage.stageZIP(at: sourceURL, for: taskID)
            }
            var replacementGame: ImportedGame?
            if let duplicate = try await storage.game(
                matchingContentFingerprint: summary.contentFingerprint
            ) {
                let resolution = await resolveDuplicate?(duplicate) ?? .cancel
                switch resolution {
                case .cancel:
                    throw GameImportError.duplicateGame(duplicate)
                case .keepBoth:
                    break
                case .replaceExisting:
                    replacementGame = duplicate
                }
            }

            try await advance(taskID, to: .detectingRoots)
            await progress?(.detecting)
            let snapshots = try await storage.detectionSnapshots(for: taskID)
            let candidates = snapshots.flatMap { snapshot -> [ProbeResult] in
                switch detectors.decide(snapshot) {
                case .noMatch: []
                case let .selected(result): [result]
                case let .ambiguous(results): results
                }
            }.sorted(by: Self.preferredProbe)

            guard !candidates.isEmpty else {
                throw GameImportError.noSupportedGameFound
            }

            let selected: ProbeResult
            if candidates.count == 1 {
                selected = candidates[0]
            } else if let resolveDetection,
                      let resolved = await resolveDetection(candidates),
                      candidates.contains(resolved) {
                try await advance(taskID, to: .resolvingAmbiguity)
                selected = resolved
            } else {
                throw GameImportError.ambiguousDetection(candidates)
            }

            try await advance(taskID, to: .scanningCompatibility)
            guard selected.compatibility.status != .unsupported else {
                throw GameImportError.unsupportedGame(selected.compatibility)
            }

            let game = ImportedGame(
                id: replacementGame?.id ?? GameID(),
                title: Self.displayTitle(for: sourceURL),
                engine: selected.engine,
                compatibilityStatus: selected.compatibility.status,
                importedAt: now(),
                lastPlayedAt: replacementGame?.lastPlayedAt,
                installedByteCount: summary.byteCount,
                contentFingerprint: summary.contentFingerprint
            )
            let manifest = GameManifest(
                game: game,
                contentRoot: selected.rootRelativePath,
                detection: selected
            )

            try await advance(taskID, to: .validatingCommit)
            await progress?(.committing)
            try await storage.commitStagedGame(
                taskID: taskID,
                manifest: manifest,
                replacing: replacementGame?.id
            )
            try await advance(taskID, to: .committed)
            _ = try await coordinator.apply(.complete(gameIDs: [game.id]), to: taskID)
            await record(
                .information,
                code: "import.completed",
                taskID: taskID,
                gameID: game.id,
                metadata: ["engine": game.engine.id.rawValue]
            )
            return game
        } catch {
            if let manifest = try? await storage.loadManifest(for: taskID) {
                switch manifest.state {
                case .active(.committed), .paused(.committed), .completed:
                    break
                case .active, .paused:
                    _ = try? await coordinator.apply(.fail(code: Self.errorCode(error)), to: taskID)
                case .cancelled, .failed:
                    break
                }
            }
            await record(
                .error,
                code: Self.errorCode(error),
                taskID: taskID
            )
            throw error
        }
    }

    private func advance(_ taskID: ImportTaskID, to stage: ImportStage) async throws {
        _ = try await coordinator.apply(.advance(to: stage), to: taskID)
    }

    private static func preferredProbe(_ lhs: ProbeResult, _ rhs: ProbeResult) -> Bool {
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        return lhs.rootRelativePath.rawValue < rhs.rootRelativePath.rawValue
    }

    private static func displayTitle(for sourceURL: URL) -> String {
        let title = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled Game" : title
    }

    private static func errorCode(_ error: any Error) -> String {
        switch error {
        case GameImportError.insufficientStorage: "import.insufficientStorage"
        case GameImportError.noSupportedGameFound: "import.noSupportedGame"
        case GameImportError.ambiguousDetection: "import.ambiguous"
        case GameImportError.unsupportedGame: "import.unsupported"
        case GameImportError.duplicateGame: "import.duplicate"
        default: "import.failed"
        }
    }

    private func record(
        _ level: DiagnosticLevel,
        code: String,
        taskID: ImportTaskID,
        gameID: GameID? = nil,
        metadata: [String: String] = [:]
    ) async {
        try? await diagnostics?.record(
            DiagnosticEntry(
                timestamp: now(),
                level: level,
                subsystem: "import",
                code: code,
                taskID: taskID,
                gameID: gameID,
                metadata: metadata
            )
        )
    }
}
