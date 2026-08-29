import Foundation
import YumeApplication
import YumeDomain

public actor LocalGameStorage: GameImportStorage, GameLibrary, GameContentProvider, GameMaintenance, GameSaveTransfer, GameSaveLibraryManaging, GameRuntimePackageStore {
    public struct VolumeCapacity: Sendable, Equatable {
        public let availableByteCount: Int64
        public let totalByteCount: Int64

        public init(availableByteCount: Int64, totalByteCount: Int64) {
            self.availableByteCount = max(0, availableByteCount)
            self.totalByteCount = max(0, totalByteCount)
        }
    }

    public typealias CapacityProvider = @Sendable (URL) throws -> VolumeCapacity

    public struct Layout: Sendable, Equatable {
        public let root: URL
        public let games: URL
        public let staging: URL
        public let cache: URL
        public let diagnostics: URL
        public let detachedSaves: URL
        public let saveLibraries: URL
        public let rtp: URL

        fileprivate init(root: URL) {
            self.root = root
            self.games = root.appendingPathComponent("Games", isDirectory: true)
            self.staging = root.appendingPathComponent("Staging", isDirectory: true)
            self.cache = root.appendingPathComponent("Cache", isDirectory: true)
            self.diagnostics = root.appendingPathComponent("Diagnostics", isDirectory: true)
            self.detachedSaves = root.appendingPathComponent("DetachedSaves", isDirectory: true)
            self.saveLibraries = root.appendingPathComponent("SaveLibraries", isDirectory: true)
            self.rtp = root.appendingPathComponent("RTP", isDirectory: true)
        }
    }

    public enum StorageError: Error, Equatable, Sendable {
        case baseURLIsNotFileURL
        case managedPathIsNotDirectory
        case symbolicLinkAtManagedPath
        case unexpectedStagingEntry(String)
        case workspaceAlreadyExistsWithoutManifest
        case manifestMissing
        case corruptManifest
        case mismatchedTaskID
        case unsupportedManifestVersion(Int)
        case sourceIsNotFileURL
        case sourceIsNotDirectory
        case unsupportedSourceEntry(String)
        case sourceLimitExceeded
        case sourcePathTooLong
        case caseInsensitivePathCollision(String)
        case stagedContentAlreadyExists
        case stagedContentMissing
        case gameAlreadyExists
        case corruptGameManifest
        case unsupportedGameManifestVersion(Int)
        case detachedSavesAlreadyExist
        case corruptSaveLibraryManifest
    }

    public nonisolated let layout: Layout

    private static let manifestFileName = "manifest.json"
    private static let contentDirectoryName = "content"
    private static let originalDirectoryName = "original"
    private static let derivedDirectoryName = "derived"
    private static let savesDirectoryName = "saves"
    private static let saveFilesDirectoryName = "files"
    private static let logsDirectoryName = "logs"
    private static let maximumSourceEntryCount = 250_000
    private static let maximumRelativePathByteCount = 1_024
    private static let maximumSaveTransferFileCount = 10_000
    private static let maximumSaveTransferByteCount = 100 * 1_024 * 1_024

    private let fileManager: FileManager
    private let capacityProvider: CapacityProvider

    public init(baseURL: URL) {
        self.layout = Layout(root: baseURL.standardizedFileURL)
        self.fileManager = .default
        self.capacityProvider = { try LocalGameStorage.systemVolumeCapacity(at: $0) }
    }

    public init(baseURL: URL, capacityProvider: @escaping CapacityProvider) {
        self.layout = Layout(root: baseURL.standardizedFileURL)
        self.fileManager = .default
        self.capacityProvider = capacityProvider
    }

    public func prepareStorage() async throws {
        guard layout.root.isFileURL else {
            throw StorageError.baseURLIsNotFileURL
        }

        try ensureManagedDirectory(layout.root)
        try ensureManagedDirectory(layout.games)
        try ensureManagedDirectory(layout.staging, excludedFromBackup: true)
        try ensureManagedDirectory(layout.cache, excludedFromBackup: true)
        try ensureManagedDirectory(layout.diagnostics, excludedFromBackup: true)
        try ensureManagedDirectory(layout.detachedSaves, excludedFromBackup: false)
        try ensureManagedDirectory(layout.saveLibraries, excludedFromBackup: false)
        try ensureManagedDirectory(layout.rtp, excludedFromBackup: true)
    }

    public func createStagingTask(
        id: ImportTaskID,
        createdAt: Date = Date()
    ) async throws -> StagingWorkspace {
        try await prepareStorage()

        let taskRoot = taskRootURL(for: id)
        let manifestURL = manifestURL(for: id)
        let contentRoot = contentRootURL(for: id)

        if fileManager.fileExists(atPath: taskRoot.path) {
            try rejectSymbolicLink(at: taskRoot)
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                throw StorageError.workspaceAlreadyExistsWithoutManifest
            }

            _ = try loadAndValidateManifest(at: manifestURL, expectedTaskID: id)
            try ensureManagedDirectory(contentRoot, excludedFromBackup: true)
            return StagingWorkspace(taskID: id, contentRootURL: contentRoot)
        }

        try ensureManagedDirectory(taskRoot, excludedFromBackup: true)
        try ensureManagedDirectory(contentRoot, excludedFromBackup: true)

        let manifest = StagingManifest(taskID: id, createdAt: createdAt)
        try writeManifest(manifest, to: manifestURL)
        return StagingWorkspace(taskID: id, contentRootURL: contentRoot)
    }

    public func stagingTaskIDs() async throws -> [ImportTaskID] {
        try await prepareStorage()
        let entries = try fileManager.contentsOfDirectory(
            at: layout.staging,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )

        var taskIDs: [ImportTaskID] = []
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw StorageError.symbolicLinkAtManagedPath
            }
            guard values.isDirectory == true, let uuid = UUID(uuidString: entry.lastPathComponent) else {
                throw StorageError.unexpectedStagingEntry(entry.lastPathComponent)
            }

            taskIDs.append(ImportTaskID(rawValue: uuid))
        }

        return taskIDs.sorted {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }
    }

    public func containsStagingTask(id: ImportTaskID) async throws -> Bool {
        let taskRoot = taskRootURL(for: id)
        guard fileManager.fileExists(atPath: taskRoot.path) else { return false }

        try validateExistingManagedDirectory(layout.root)
        try validateExistingManagedDirectory(layout.staging)
        try validateExistingManagedDirectory(taskRoot)
        return true
    }

    public func loadManifest(for id: ImportTaskID) async throws -> StagingManifest {
        try validateExistingWorkspaceRoot(for: id)
        let url = manifestURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw StorageError.manifestMissing
        }
        return try loadAndValidateManifest(at: url, expectedTaskID: id)
    }

    public func registerOwnedPath(
        _ path: StorageRelativePath,
        for id: ImportTaskID,
        updatedAt: Date = Date()
    ) async throws {
        var manifest = try await loadManifest(for: id)
        manifest.registerOwnedPath(path, at: updatedAt)
        try writeManifest(manifest, to: manifestURL(for: id))
    }

    public func updateState(
        _ state: ImportState,
        for id: ImportTaskID,
        updatedAt: Date = Date()
    ) async throws {
        var manifest = try await loadManifest(for: id)
        manifest.transition(to: state, at: updatedAt)
        try writeManifest(manifest, to: manifestURL(for: id))
    }

    public func discardStagingTask(id: ImportTaskID) async throws {
        let taskRoot = taskRootURL(for: id)
        guard fileManager.fileExists(atPath: taskRoot.path) else { return }

        try validateExistingManagedDirectory(layout.root)
        try validateExistingManagedDirectory(layout.staging)
        try validateExistingManagedDirectory(taskRoot)
        makeTreeWritable(at: taskRoot)
        try fileManager.removeItem(at: taskRoot)
    }

    public func validateDirectorySource(at sourceURL: URL) async throws -> StorageBudget {
        try await prepareStorage()
        guard sourceURL.isFileURL else { throw StorageError.sourceIsNotFileURL }
        let source = sourceURL.standardizedFileURL
        try rejectSymbolicLink(at: source)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw StorageError.sourceIsNotDirectory
        }

        let summary = try summarizeTree(at: source)
        return try storageBudget(
            sourceByteCount: summary.byteCount,
            requiredByteCount: summary.byteCount
        )
    }

    public func validateZIPSource(at sourceURL: URL, password: String?) async throws -> StorageBudget {
        try await prepareStorage()
        let inspection = try SafeZIPExtractor().inspect(sourceURL)
        guard !inspection.containsEncryptedEntries || password?.isEmpty == false else {
            throw SafeZIPError.passwordRequired
        }
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let archiveByteCount = Int64(truncating: attributes[.size] as? NSNumber ?? 0)
        return try storageBudget(
            sourceByteCount: archiveByteCount,
            requiredByteCount: inspection.uncompressedByteCount
        )
    }

    public func validate7zSource(at sourceURL: URL, password: String?) async throws -> StorageBudget {
        try await prepareStorage()
        let inspection = try Safe7zExtractor().inspect(sourceURL, password: password)
        guard !inspection.containsEncryptedEntries || password?.isEmpty == false else {
            throw Safe7zError.passwordRequired
        }
        return try storageBudget(
            sourceByteCount: inspection.compressedByteCount,
            requiredByteCount: inspection.uncompressedByteCount
        )
    }

    public func stageDirectory(
        at sourceURL: URL,
        for taskID: ImportTaskID
    ) async throws -> StagedSourceSummary {
        let workspace = try await createStagingTask(id: taskID, createdAt: Date())
        let source = sourceURL.standardizedFileURL
        let destination = workspace.contentRootURL.appendingPathComponent(
            Self.originalDirectoryName,
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw StorageError.stagedContentAlreadyExists
        }

        let summary = try copyValidatedTree(from: source, to: destination)
        let fingerprint = try contentFingerprint(at: destination)
        let relativePath = try StorageRelativePath(rawValue: Self.originalDirectoryName)
        try await registerOwnedPath(relativePath, for: taskID, updatedAt: Date())
        return StagedSourceSummary(
            sourceRelativePath: relativePath,
            byteCount: summary.byteCount,
            fileCount: summary.fileCount,
            contentFingerprint: fingerprint
        )
    }

    public func stageZIP(
        at sourceURL: URL,
        password: String?,
        for taskID: ImportTaskID
    ) async throws -> StagedSourceSummary {
        let workspace = try await createStagingTask(id: taskID, createdAt: Date())
        let destination = workspace.contentRootURL.appendingPathComponent(
            Self.originalDirectoryName,
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw StorageError.stagedContentAlreadyExists
        }

        let inspection = try SafeZIPExtractor().extract(
            sourceURL,
            to: destination,
            password: password
        )
        let fingerprint = try contentFingerprint(at: destination)
        let relativePath = try StorageRelativePath(rawValue: Self.originalDirectoryName)
        try await registerOwnedPath(relativePath, for: taskID, updatedAt: Date())
        return StagedSourceSummary(
            sourceRelativePath: relativePath,
            byteCount: inspection.uncompressedByteCount,
            fileCount: inspection.fileCount,
            contentFingerprint: fingerprint
        )
    }

    public func validateRARSource(at sourceURL: URL) async throws -> StorageBudget {
        try await prepareStorage()
        let inspection = try SafeRARExtractor().inspect(sourceURL)
        guard !inspection.containsEncryptedEntries else {
            throw SafeRARError.encryptedArchiveUnsupported
        }
        return try storageBudget(
            sourceByteCount: inspection.compressedByteCount,
            requiredByteCount: inspection.uncompressedByteCount
        )
    }

    public func stageRAR(
        at sourceURL: URL,
        for taskID: ImportTaskID
    ) async throws -> StagedSourceSummary {
        let workspace = try await createStagingTask(id: taskID, createdAt: Date())
        let destination = workspace.contentRootURL.appendingPathComponent(
            Self.originalDirectoryName,
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw StorageError.stagedContentAlreadyExists
        }

        let inspection = try SafeRARExtractor().extract(sourceURL, to: destination)
        let fingerprint = try contentFingerprint(at: destination)
        let relativePath = try StorageRelativePath(rawValue: Self.originalDirectoryName)
        try await registerOwnedPath(relativePath, for: taskID, updatedAt: Date())
        return StagedSourceSummary(
            sourceRelativePath: relativePath,
            byteCount: inspection.uncompressedByteCount,
            fileCount: inspection.fileCount,
            contentFingerprint: fingerprint
        )
    }

    public func stage7z(
        at sourceURL: URL,
        password: String?,
        for taskID: ImportTaskID
    ) async throws -> StagedSourceSummary {
        let workspace = try await createStagingTask(id: taskID, createdAt: Date())
        let destination = workspace.contentRootURL.appendingPathComponent(
            Self.originalDirectoryName,
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw StorageError.stagedContentAlreadyExists
        }

        let inspection = try Safe7zExtractor().extract(
            sourceURL,
            to: destination,
            password: password
        )
        let fingerprint = try contentFingerprint(at: destination)
        let relativePath = try StorageRelativePath(rawValue: Self.originalDirectoryName)
        try await registerOwnedPath(relativePath, for: taskID, updatedAt: Date())
        return StagedSourceSummary(
            sourceRelativePath: relativePath,
            byteCount: inspection.uncompressedByteCount,
            fileCount: inspection.fileCount,
            contentFingerprint: fingerprint
        )
    }

    public func detectionSnapshots(for taskID: ImportTaskID) async throws -> [DetectionSnapshot] {
        try validateExistingWorkspaceRoot(for: taskID)
        let original = contentRootURL(for: taskID).appendingPathComponent(
            Self.originalDirectoryName,
            isDirectory: true
        )
        try validateExistingManagedDirectory(original)

        let entries = try scannedEntries(at: original)
        var candidates: Set<String> = [""]
        for entry in entries where !entry.isDirectory {
            let components = entry.relativePath.split(separator: "/").dropLast().map(String.init)
            let maximumDepth = min(8, components.count)
            guard maximumDepth > 0 else { continue }
            for depth in 1...maximumDepth {
                candidates.insert(components.prefix(depth).joined(separator: "/"))
            }
        }

        return try candidates.sorted().compactMap { candidate -> DetectionSnapshot? in
            let prefix = candidate.isEmpty ? "" : candidate + "/"
            var files: Set<String> = []
            var directories: Set<String> = []

            for entry in entries {
                guard entry.relativePath.hasPrefix(prefix) else { continue }
                let descendant = String(entry.relativePath.dropFirst(prefix.count))
                guard !descendant.isEmpty else { continue }
                if entry.isDirectory {
                    directories.insert(descendant)
                } else {
                    files.insert(descendant)
                }
            }
            guard !files.isEmpty else { return nil }

            let rootPath = candidate.isEmpty
                ? Self.originalDirectoryName
                : Self.originalDirectoryName + "/" + candidate
            return DetectionSnapshot(
                rootRelativePath: try StorageRelativePath(rawValue: rootPath),
                regularFiles: files,
                directories: directories
            )
        }
    }

    public func commitStagedGame(
        taskID: ImportTaskID,
        manifest: GameManifest,
        replacing existingGameID: GameID? = nil
    ) async throws {
        try await prepareStorage()
        try validateExistingWorkspaceRoot(for: taskID)
        let content = contentRootURL(for: taskID)
        let original = content.appendingPathComponent(Self.originalDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: original.path) else {
            throw StorageError.stagedContentMissing
        }

        let destination = gameRootURL(for: manifest.game.id)
        let isReplacement = existingGameID == manifest.game.id
        guard isReplacement || !fileManager.fileExists(atPath: destination.path) else {
            throw StorageError.gameAlreadyExists
        }
        var committedManifest = manifest
        if isReplacement {
            guard fileManager.fileExists(atPath: destination.path) else {
                throw StorageError.corruptGameManifest
            }
            let existingManifest = try loadGameManifest(at: destination)
            guard existingManifest.game.engine.id == manifest.game.engine.id else {
                throw StorageError.corruptGameManifest
            }
            committedManifest.saveLibraryID = existingManifest.saveLibraryID
        }

        try ensureManagedDirectory(
            content.appendingPathComponent(Self.derivedDirectoryName, isDirectory: true),
            excludedFromBackup: true
        )
        let saves = content.appendingPathComponent(Self.savesDirectoryName, isDirectory: true)
        try ensureManagedDirectory(
            saves,
            excludedFromBackup: false
        )
        if isReplacement {
            let existingSaves = destination.appendingPathComponent(Self.savesDirectoryName, isDirectory: true)
            if fileManager.fileExists(atPath: existingSaves.path), !(try scannedEntries(at: existingSaves)).isEmpty {
                try fileManager.removeItem(at: saves)
                _ = try copyValidatedTree(from: existingSaves, to: saves)
            }
        }
        try ensureManagedDirectory(
            content.appendingPathComponent(Self.logsDirectoryName, isDirectory: true),
            excludedFromBackup: true
        )
        let restoredDetachedRoot = try copyMatchingDetachedSaves(
            for: manifest.game,
            to: saves
        )
        try makeTreeReadOnly(at: original)
        try writeGameManifest(committedManifest, to: content.appendingPathComponent(Self.manifestFileName))
        if isReplacement {
            let backup = taskRootURL(for: taskID).appendingPathComponent(
                "replacement-backup",
                isDirectory: true
            )
            try fileManager.moveItem(at: destination, to: backup)
            do {
                try fileManager.moveItem(at: content, to: destination)
            } catch {
                if !fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.moveItem(at: backup, to: destination)
                }
                throw error
            }
            makeTreeWritable(at: backup)
            try? fileManager.removeItem(at: backup)
        } else {
            try fileManager.moveItem(at: content, to: destination)
        }
        if let restoredDetachedRoot {
            try? fileManager.removeItem(at: restoredDetachedRoot)
        }
    }

    public func game(matchingContentFingerprint fingerprint: String) async throws -> ImportedGame? {
        guard !fingerprint.isEmpty else { return nil }
        return try await allGames().first { $0.contentFingerprint == fingerprint }
    }

    public func allGames() async throws -> [ImportedGame] {
        try await prepareStorage()
        let entries = try fileManager.contentsOfDirectory(
            at: layout.games,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )

        var games: [ImportedGame] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw StorageError.symbolicLinkAtManagedPath }
            guard values.isDirectory == true, UUID(uuidString: entry.lastPathComponent) != nil else {
                throw StorageError.corruptGameManifest
            }
            games.append(try loadGameManifest(at: entry).game)
        }
        return games
    }

    public func game(id: GameID) async throws -> ImportedGame? {
        try await prepareStorage()
        let root = gameRootURL(for: id)
        guard fileManager.fileExists(atPath: root.path) else { return nil }
        return try loadGameManifest(at: root).game
    }

    public func removeGame(id: GameID, policy: GameRemovalPolicy) async throws {
        try await prepareStorage()
        let root = gameRootURL(for: id)
        guard fileManager.fileExists(atPath: root.path) else { return }
        try validateExistingManagedDirectory(layout.root)
        try validateExistingManagedDirectory(layout.games)
        try validateExistingManagedDirectory(root)
        let save = try ensureSaveLibrary(for: root)
        makeTreeWritable(at: root)
        try fileManager.removeItem(at: root)
        if policy == .deleteSaves {
            try fileManager.removeItem(at: saveLibraryRootURL(for: save.library.id))
        }
    }

    public func storageBreakdown(for id: GameID) async throws -> GameStorageBreakdown {
        try await prepareStorage()
        let root = gameRootURL(for: id)
        let save = try ensureSaveLibrary(for: root)
        return GameStorageBreakdown(
            gameID: id,
            originalByteCount: try byteCountOfDirectory(
                root.appendingPathComponent(Self.originalDirectoryName, isDirectory: true)
            ),
            derivedByteCount: try byteCountOfDirectory(
                root.appendingPathComponent(Self.derivedDirectoryName, isDirectory: true)
            ),
            saveByteCount: try byteCountOfDirectory(save.filesURL),
            logByteCount: try byteCountOfDirectory(
                root.appendingPathComponent(Self.logsDirectoryName, isDirectory: true)
            )
        )
    }

    public func markPlayed(id: GameID, at date: Date) async throws {
        try await prepareStorage()
        let root = gameRootURL(for: id)
        var manifest = try loadGameManifest(at: root)
        manifest.game.lastPlayedAt = date
        try writeGameManifest(manifest, to: root.appendingPathComponent(Self.manifestFileName))
    }

    public func renameGame(id: GameID, title: String) async throws {
        try await prepareStorage()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SaveLibraryError.invalidTitle }
        let root = gameRootURL(for: id)
        var manifest = try loadGameManifest(at: root)
        let previousTitle = manifest.game.title
        manifest.game.title = String(trimmed.prefix(120))
        try writeGameManifest(manifest, to: root.appendingPathComponent(Self.manifestFileName))

        if let saveID = manifest.saveLibraryID {
            var saveManifest = try loadSaveLibraryManifest(id: saveID)
            if saveManifest.title == previousTitle {
                saveManifest.title = manifest.game.title
                saveManifest.modifiedAt = Date()
                try writeSaveLibraryManifest(saveManifest)
            }
        }
    }

    public func saveLibraries() async throws -> [GameSaveLibrary] {
        try await prepareStorage()
        let roots = try fileManager.contentsOfDirectory(
            at: layout.games,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for root in roots where UUID(uuidString: root.lastPathComponent) != nil {
            _ = try ensureSaveLibrary(for: root)
        }

        let bindings = try saveLibraryBindings()
        return try loadAllSaveLibraryManifests().map { manifest in
            GameSaveLibrary(
                id: manifest.id,
                title: manifest.title,
                engine: manifest.engine,
                contentFingerprint: manifest.contentFingerprint,
                createdAt: manifest.createdAt,
                modifiedAt: manifest.modifiedAt,
                byteCount: try byteCountOfDirectory(saveLibraryFilesURL(for: manifest.id)),
                boundGameID: bindings[manifest.id]
            )
        }.sorted {
            if ($0.boundGameID != nil) != ($1.boundGameID != nil) {
                return $0.boundGameID != nil
            }
            return $0.modifiedAt > $1.modifiedAt
        }
    }

    public func saveLibrary(for gameID: GameID) async throws -> GameSaveLibrary {
        try await prepareStorage()
        let root = gameRootURL(for: gameID)
        guard fileManager.fileExists(atPath: root.path) else {
            throw SaveLibraryError.gameNotFound
        }
        let ensured = try ensureSaveLibrary(for: root)
        return GameSaveLibrary(
            id: ensured.library.id,
            title: ensured.library.title,
            engine: ensured.library.engine,
            contentFingerprint: ensured.library.contentFingerprint,
            createdAt: ensured.library.createdAt,
            modifiedAt: ensured.library.modifiedAt,
            byteCount: try byteCountOfDirectory(ensured.filesURL),
            boundGameID: gameID
        )
    }

    public func bindSaveLibrary(
        _ saveLibraryID: SaveLibraryID,
        to gameID: GameID
    ) async throws {
        try await prepareStorage()
        let gameRoot = gameRootURL(for: gameID)
        guard fileManager.fileExists(atPath: gameRoot.path) else {
            throw SaveLibraryError.gameNotFound
        }
        _ = try ensureSaveLibrary(for: gameRoot)
        var gameManifest = try loadGameManifest(at: gameRoot)
        let saveManifest: SaveLibraryManifest
        do {
            saveManifest = try loadSaveLibraryManifest(id: saveLibraryID)
        } catch {
            throw SaveLibraryError.saveLibraryNotFound
        }
        guard saveManifest.engine == gameManifest.game.engine else {
            throw SaveLibraryError.engineMismatch
        }
        if let existing = try saveLibraryBindings()[saveLibraryID], existing != gameID {
            throw SaveLibraryError.alreadyBound(existing)
        }
        gameManifest.saveLibraryID = saveLibraryID
        try writeGameManifest(
            gameManifest,
            to: gameRoot.appendingPathComponent(Self.manifestFileName)
        )
    }

    public func deleteSaveLibrary(id: SaveLibraryID) async throws {
        try await prepareStorage()
        if let gameID = try saveLibraryBindings()[id] {
            let gameRoot = gameRootURL(for: gameID)
            var gameManifest = try loadGameManifest(at: gameRoot)
            let replacementID = SaveLibraryID()
            try ensureManagedDirectory(saveLibraryRootURL(for: replacementID), excludedFromBackup: false)
            try ensureManagedDirectory(saveLibraryFilesURL(for: replacementID), excludedFromBackup: false)
            try writeSaveLibraryManifest(
                SaveLibraryManifest(id: replacementID, game: gameManifest.game)
            )
            gameManifest.saveLibraryID = replacementID
            try writeGameManifest(
                gameManifest,
                to: gameRoot.appendingPathComponent(Self.manifestFileName)
            )
        }
        let root = saveLibraryRootURL(for: id)
        guard fileManager.fileExists(atPath: root.path) else {
            throw SaveLibraryError.saveLibraryNotFound
        }
        makeTreeWritable(at: root)
        try fileManager.removeItem(at: root)
    }

    public func contentLocation(for id: GameID) async throws -> GameContentLocation {
        try await prepareStorage()
        let gameRoot = gameRootURL(for: id)
        guard fileManager.fileExists(atPath: gameRoot.path) else {
            throw GameContentError.gameNotFound
        }
        let ensured = try ensureSaveLibrary(for: gameRoot)
        let manifest = ensured.manifest

        var contentRoot = gameRoot.appendingPathComponent(
            manifest.contentRoot.rawValue,
            isDirectory: true
        ).standardizedFileURL
        let nestedWebRoot = contentRoot.appendingPathComponent("www", isDirectory: true)
        if fileManager.fileExists(atPath: nestedWebRoot.appendingPathComponent("index.html").path) {
            contentRoot = nestedWebRoot
        }
        let entryPointNames = ["index.html", "tyrano.html", "game.html"]
        let entryPoint = entryPointNames.compactMap { name -> StorageRelativePath? in
            let url = contentRoot.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return try? StorageRelativePath(rawValue: name)
        }.first
        let runtimeEntryPoint = manifest.detection.evidence.first { evidence in
            evidence.kind == .requiredFile
                && !evidence.relativePath.rawValue.hasSuffix("/")
        }?.relativePath
        return GameContentLocation(
            game: manifest.game,
            rootURL: contentRoot,
            saveRootURL: ensured.filesURL,
            derivedRootURL: gameRoot.appendingPathComponent(Self.derivedDirectoryName, isDirectory: true),
            logRootURL: gameRoot.appendingPathComponent(Self.logsDirectoryName, isDirectory: true),
            webEntryPoint: entryPoint,
            runtimeEntryPoint: runtimeEntryPoint
        )
    }

    public func exportSaves(for id: GameID) async throws -> URL {
        try await prepareStorage()
        let gameRoot = gameRootURL(for: id)
        guard fileManager.fileExists(atPath: gameRoot.path) else {
            throw SaveTransferError.gameNotFound
        }
        let ensured = try ensureSaveLibrary(for: gameRoot)
        let manifest = ensured.manifest
        let saveRoot = ensured.filesURL
        let entries = try scannedEntries(at: saveRoot).filter { !$0.isDirectory }
        guard entries.count <= Self.maximumSaveTransferFileCount else {
            throw SaveTransferError.tooManyFiles
        }

        var totalByteCount = 0
        var files: [SaveTransferFile] = []
        for entry in entries.sorted(by: { $0.relativePath < $1.relativePath }) {
            let addition = totalByteCount.addingReportingOverflow(Int(entry.byteCount))
            guard !addition.overflow, addition.partialValue <= Self.maximumSaveTransferByteCount else {
                throw SaveTransferError.packageTooLarge
            }
            totalByteCount = addition.partialValue
            files.append(
                SaveTransferFile(
                    relativePath: try StorageRelativePath(rawValue: entry.relativePath),
                    data: try Data(contentsOf: entry.url, options: [.mappedIfSafe])
                )
            )
        }

        let package = SaveTransferPackage(
            gameID: id,
            engineID: manifest.game.engine.id,
            compatibilityVersion: manifest.game.engine.compatibilityVersion,
            exportedAt: Date(),
            files: files
        )
        let exportRoot = layout.cache.appendingPathComponent("SaveExports", isDirectory: true)
        try ensureManagedDirectory(exportRoot, excludedFromBackup: true)
        let safeTitle = manifest.game.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let exportURL = exportRoot.appendingPathComponent("\(safeTitle)-\(id.rawValue.uuidString).yumesave")
        let data = try encoder().encode(package)
        guard data.count <= Self.maximumSaveTransferByteCount * 2 else {
            throw SaveTransferError.packageTooLarge
        }
        try data.write(to: exportURL, options: [.atomic])
        return exportURL
    }

    public func importSaves(from packageURL: URL, for id: GameID) async throws {
        try await prepareStorage()
        let gameRoot = gameRootURL(for: id)
        guard fileManager.fileExists(atPath: gameRoot.path) else {
            throw SaveTransferError.gameNotFound
        }
        let ensured = try ensureSaveLibrary(for: gameRoot)
        let gameManifest = ensured.manifest
        let packageData = try Data(contentsOf: packageURL, options: [.mappedIfSafe])
        guard packageData.count <= Self.maximumSaveTransferByteCount * 2 else {
            throw SaveTransferError.packageTooLarge
        }

        let package: SaveTransferPackage
        do {
            package = try decoder().decode(SaveTransferPackage.self, from: packageData)
        } catch {
            throw SaveTransferError.corruptPackage
        }
        guard package.formatVersion == SaveTransferPackage.currentFormatVersion else {
            throw SaveTransferError.unsupportedFormatVersion(package.formatVersion)
        }
        guard package.gameID == id else { throw SaveTransferError.gameMismatch }
        guard package.engineID == gameManifest.game.engine.id,
              package.compatibilityVersion == gameManifest.game.engine.compatibilityVersion
        else { throw SaveTransferError.engineMismatch }
        guard package.files.count <= Self.maximumSaveTransferFileCount else {
            throw SaveTransferError.tooManyFiles
        }

        var paths: Set<StorageRelativePath> = []
        var totalByteCount = 0
        for file in package.files {
            guard paths.insert(file.relativePath).inserted else {
                throw SaveTransferError.duplicatePath(file.relativePath)
            }
            let addition = totalByteCount.addingReportingOverflow(file.data.count)
            guard !addition.overflow, addition.partialValue <= Self.maximumSaveTransferByteCount else {
                throw SaveTransferError.packageTooLarge
            }
            totalByteCount = addition.partialValue
        }

        let transactionID = UUID().uuidString.lowercased()
        let transactionRoot = layout.cache.appendingPathComponent("SaveImports/\(transactionID)", isDirectory: true)
        let replacement = transactionRoot.appendingPathComponent("replacement", isDirectory: true)
        let backup = transactionRoot.appendingPathComponent("backup", isDirectory: true)
        try ensureManagedDirectory(replacement, excludedFromBackup: true)

        do {
            for file in package.files {
                let destination = replacement.appendingPathComponent(file.relativePath.rawValue)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try file.data.write(to: destination, options: [.atomic])
            }

            let saves = ensured.filesURL
            try fileManager.moveItem(at: saves, to: backup)
            do {
                try fileManager.moveItem(at: replacement, to: saves)
                try fileManager.removeItem(at: backup)
                try? fileManager.removeItem(at: transactionRoot)
                var saveManifest = ensured.library
                saveManifest.modifiedAt = Date()
                try writeSaveLibraryManifest(saveManifest)
            } catch {
                if !fileManager.fileExists(atPath: saves.path) {
                    try? fileManager.moveItem(at: backup, to: saves)
                }
                throw error
            }
        } catch let error as SaveTransferError {
            try? fileManager.removeItem(at: transactionRoot)
            throw error
        } catch {
            try? fileManager.removeItem(at: transactionRoot)
            throw error
        }
    }

    public func readFileHead(
        for taskID: ImportTaskID,
        relativePath: StorageRelativePath,
        byteCount: Int
    ) async throws -> Data {
        try validateExistingWorkspaceRoot(for: taskID)
        let url = contentRootURL(for: taskID)
            .appendingPathComponent(relativePath.rawValue)
            .standardizedFileURL
        guard url.path.hasPrefix(contentRootURL(for: taskID).standardizedFileURL.path + "/") else {
            throw StorageError.unsupportedSourceEntry(relativePath.rawValue)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw StorageError.unsupportedSourceEntry(relativePath.rawValue)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: max(0, byteCount)) ?? Data()
    }

    public func listRTPPackages() async throws -> [RTPPackage] {
        try await prepareStorage()
        return try loadRTPIndex().packages
    }

    public func importRPGMakerRTP(
        from archiveURL: URL,
        variantHint: RPGMakerRTPVariant? = nil
    ) async throws -> [RTPPackage] {
        try await prepareStorage()
        let source = archiveURL.standardizedFileURL
        guard source.isFileURL else { throw RTPStoreError.sourceIsNotZIPArchive }
        let extensionName = source.pathExtension.lowercased()
        guard extensionName == "zip" || extensionName == "7z" else {
            throw RTPStoreError.sourceIsNotZIPArchive
        }
        let values: URLResourceValues
        do {
            values = try source.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch {
            throw RTPStoreError.sourceUnreadable
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RTPStoreError.sourceUnreadable
        }

        let extractionRoot = layout.cache.appendingPathComponent(
            "RTPImport-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        defer {
            if fileManager.fileExists(atPath: extractionRoot.path) {
                makeTreeWritable(at: extractionRoot)
                try? fileManager.removeItem(at: extractionRoot)
            }
        }
        do {
            if extensionName == "7z" {
                _ = try Safe7zExtractor().extract(source, to: extractionRoot)
            } else {
                _ = try SafeZIPExtractor().extract(source, to: extractionRoot)
            }
        } catch {
            throw RTPStoreError.invalidZIPArchive
        }

        let discovered = try discoverRPGMakerRTPRoots(
            archiveURL: source,
            extractionRoot: extractionRoot,
            variantHint: variantHint
        )
        var index = try loadRTPIndex()
        let alreadyImported = Set(index.packages.compactMap(\.variant))
        let pending = discovered.filter { !alreadyImported.contains($0.key) }
        if pending.isEmpty {
            if let first = discovered.keys.sorted(by: { $0.rawValue < $1.rawValue }).first {
                throw RTPStoreError.duplicateVariant(first)
            }
            throw RTPStoreError.unidentifiedRPGMakerVariant
        }

        let engine = EngineID(rawValue: "rgss")
        let engineDirectory = layout.rtp.appendingPathComponent(
            engine.rawValue,
            isDirectory: true
        )
        try ensureManagedDirectory(engineDirectory, excludedFromBackup: true)
        var createdDestinations: [URL] = []
        var packages: [RTPPackage] = []
        do {
            for variant in RPGMakerRTPVariant.allCases {
                guard let contentRoot = pending[variant] else { continue }
                let summary = try summarizeTree(at: contentRoot)
                guard summary.fileCount > 0 else { throw RTPStoreError.sourceIsEmpty }
                let destination = engineDirectory.appendingPathComponent(
                    variant.packageID,
                    isDirectory: true
                )
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw RTPStoreError.duplicateVariant(variant)
                }
                _ = try copyValidatedTree(from: contentRoot, to: destination)
                createdDestinations.append(destination)
                packages.append(RTPPackage(
                    id: variant.packageID,
                    engineID: engine,
                    variant: variant,
                    importedAt: Date(),
                    fileCount: summary.fileCount,
                    byteCount: summary.byteCount
                ))
            }
            for package in packages { index.upsert(package) }
            try writeRTPIndex(index)
            return packages
        } catch let error as RTPStoreError {
            for destination in createdDestinations {
                makeTreeWritable(at: destination)
                try? fileManager.removeItem(at: destination)
            }
            throw error
        } catch {
            for destination in createdDestinations {
                makeTreeWritable(at: destination)
                try? fileManager.removeItem(at: destination)
            }
            throw RTPStoreError.copyFailed
        }
    }

    public func importRPGMakerRTP(
        variant: RPGMakerRTPVariant,
        from directoryURL: URL
    ) async throws -> RTPPackage {
        try await prepareStorage()

        var index = try loadRTPIndex()
        guard !index.packages.contains(where: { $0.variant == variant }) else {
            throw RTPStoreError.duplicateVariant(variant)
        }

        let source = directoryURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RTPStoreError.sourceIsNotDirectory
        }
        let contentRoot = try resolveRPGMakerRTPRoot(at: source)
        let summary: TreeSummary
        do {
            summary = try summarizeTree(at: contentRoot)
        } catch {
            throw RTPStoreError.sourceUnreadable
        }
        guard summary.fileCount > 0 else { throw RTPStoreError.sourceIsEmpty }

        let engine = EngineID(rawValue: "rgss")
        let name = variant.packageID
        let engineDirectory = layout.rtp.appendingPathComponent(engine.rawValue, isDirectory: true)
        let destination = engineDirectory.appendingPathComponent(name, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw RTPStoreError.duplicateVariant(variant)
        }
        try ensureManagedDirectory(engineDirectory, excludedFromBackup: true)

        do {
            _ = try copyValidatedTree(from: contentRoot, to: destination)
            let package = RTPPackage(
                id: name,
                engineID: engine,
                variant: variant,
                importedAt: Date(),
                fileCount: summary.fileCount,
                byteCount: summary.byteCount
            )
            index.upsert(package)
            try writeRTPIndex(index)
            return package
        } catch {
            try? fileManager.removeItem(at: destination)
            throw RTPStoreError.copyFailed
        }
    }

    public func removeRTPPackage(id: String) async throws {
        try await prepareStorage()
        var index = try loadRTPIndex()
        guard let package = index.packages.first(where: { $0.id == id }) else {
            throw RTPStoreError.packageNotFound
        }

        let engineDirectory = layout.rtp.appendingPathComponent(package.engineID.rawValue, isDirectory: true)
        let packageURL = engineDirectory.appendingPathComponent(id, isDirectory: true)
        if fileManager.fileExists(atPath: packageURL.path) {
            try validateExistingManagedDirectory(packageURL)
            makeTreeWritable(at: packageURL)
            try fileManager.removeItem(at: packageURL)
        }
        index.remove(id: id)
        try writeRTPIndex(index)
    }

    public func rtpMountRoots(for game: ImportedGame) async throws -> [URL] {
        try await prepareStorage()
        let rgssVariant = try detectedRPGMakerRTPVariant(for: game)
        return try loadRTPIndex().packages
            .filter { package in
                guard package.engineID == game.engine.id else { return false }
                guard game.engine.id.rawValue == "rgss" else { return true }
                guard let wanted = rgssVariant else { return true }
                guard let packageVariant = package.variant else { return true }
                return packageVariant == wanted
            }
            .map { package in
                layout.rtp
                    .appendingPathComponent(package.engineID.rawValue, isDirectory: true)
                    .appendingPathComponent(package.id, isDirectory: true)
            }
    }

    /// Accepts either the actual RTP root or common installer wrappers such as
    /// `VX/app` and `XP/{sys,app}`. A root is recognized when it directly
    /// contains at least one standard asset directory (Audio, Graphics or
    /// Fonts); RTP distributions are not required to ship all three. The
    /// source tree is inspected only and is never renamed, moved or modified.
    private func resolveRPGMakerRTPRoot(at selectedRoot: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: selectedRoot.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw RTPStoreError.sourceIsNotDirectory
        }

        func isRTPRoot(_ candidate: URL) throws -> Bool {
            let children = try fileManager.contentsOfDirectory(
                at: candidate,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            let assetDirectoryNames: Set<String> = ["audio", "graphics", "fonts"]
            for child in children {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { continue }
                guard values.isDirectory == true,
                      assetDirectoryNames.contains(child.lastPathComponent.lowercased())
                else { continue }

                var enumerationError: Error?
                guard let enumerator = fileManager.enumerator(
                    at: child,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, error in
                        enumerationError = error
                        return false
                    }
                ) else {
                    throw RTPStoreError.sourceUnreadable
                }
                while let asset = enumerator.nextObject() as? URL {
                    let assetValues = try asset.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                    )
                    if assetValues.isSymbolicLink == true {
                        enumerator.skipDescendants()
                    } else if assetValues.isRegularFile == true {
                        return true
                    }
                }
                if enumerationError != nil {
                    throw RTPStoreError.sourceUnreadable
                }
            }
            return false
        }

        do {
            if try isRTPRoot(selectedRoot) { return selectedRoot }

            let selectedComponents = selectedRoot.standardizedFileURL.pathComponents.count
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: selectedRoot,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                throw RTPStoreError.sourceUnreadable
            }

            var candidates: [URL] = []
            while let candidate = enumerator.nextObject() as? URL {
                let depth = candidate.standardizedFileURL.pathComponents.count - selectedComponents
                if depth > 3 {
                    enumerator.skipDescendants()
                    continue
                }
                let values = try candidate.resourceValues(forKeys: Set(keys))
                guard values.isSymbolicLink != true else {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isDirectory == true else { continue }
                if candidate.lastPathComponent.caseInsensitiveCompare("sys") == .orderedSame {
                    enumerator.skipDescendants()
                    continue
                }
                if try isRTPRoot(candidate) {
                    candidates.append(candidate)
                    enumerator.skipDescendants()
                }
            }
            if enumerationError != nil {
                throw RTPStoreError.sourceUnreadable
            }

            guard let minimumDepth = candidates.map({
                $0.standardizedFileURL.pathComponents.count
            }).min() else {
                throw RTPStoreError.invalidRPGMakerLayout
            }
            let nearest = candidates.filter {
                $0.standardizedFileURL.pathComponents.count == minimumDepth
            }
            let preferredAppRoots = nearest.filter {
                $0.lastPathComponent.caseInsensitiveCompare("app") == .orderedSame
            }
            if preferredAppRoots.count == 1, let appRoot = preferredAppRoots.first {
                return appRoot
            }
            guard nearest.count == 1, let resolved = nearest.first else {
                throw RTPStoreError.ambiguousRPGMakerLayout
            }
            return resolved
        } catch let error as RTPStoreError {
            throw error
        } catch {
            throw RTPStoreError.sourceUnreadable
        }
    }

    private func discoverRPGMakerRTPRoots(
        archiveURL: URL,
        extractionRoot: URL,
        variantHint: RPGMakerRTPVariant? = nil
    ) throws -> [RPGMakerRTPVariant: URL] {
        func token(_ value: String) -> String {
            value.lowercased().unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map(String.init)
                .joined()
        }

        func variantFromName(_ name: String) -> RPGMakerRTPVariant? {
            let t = token(name)
            if t.contains("vxace") || t.contains("rpgvxace") || t == "rtp100" {
                return .vxAce
            }
            if t.contains("xp") && !t.contains("vx") {
                return .xp
            }
            if t.contains("vx") {
                return .vx
            }
            return nil
        }

        func variantFromAncestors(of url: URL) -> RPGMakerRTPVariant? {
            let rootComponents = extractionRoot.standardizedFileURL.pathComponents
            let components = url.standardizedFileURL.pathComponents
            guard components.starts(with: rootComponents) else { return nil }
            for name in components.dropFirst(rootComponents.count).reversed() {
                if let variant = variantFromName(name) { return variant }
            }
            return nil
        }

        let rootDepth = extractionRoot.standardizedFileURL.pathComponents.count
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: extractionRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { throw RTPStoreError.sourceUnreadable }

        var rootsByVariant: [RPGMakerRTPVariant: [URL]] = [:]
        var unassigned: [URL] = []
        while let candidate = enumerator.nextObject() as? URL {
            let depth = candidate.standardizedFileURL.pathComponents.count - rootDepth
            if depth > 5 {
                enumerator.skipDescendants()
                continue
            }
            let values = try candidate.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                continue
            }
            guard values.isDirectory == true else { continue }
            if candidate.lastPathComponent.caseInsensitiveCompare("sys") == .orderedSame {
                enumerator.skipDescendants()
                continue
            }
            let isApp = candidate.lastPathComponent.caseInsensitiveCompare("app") == .orderedSame
            let isNamedGeneration = variantFromName(candidate.lastPathComponent) != nil
            guard isApp || isNamedGeneration else { continue }
            let contentRoot: URL
            do {
                contentRoot = try resolveRPGMakerRTPRoot(at: candidate)
            } catch {
                continue
            }
            enumerator.skipDescendants()
            if let variant = variantFromName(candidate.lastPathComponent)
                ?? variantFromAncestors(of: contentRoot)
                ?? variantFromAncestors(of: candidate) {
                rootsByVariant[variant, default: []].append(contentRoot)
            } else {
                unassigned.append(contentRoot)
            }
        }

        func preferredRoot(in urls: [URL]) -> URL {
            let unique = Array(Set(urls.map(\.standardizedFileURL)))
            let apps = unique.filter {
                $0.lastPathComponent.caseInsensitiveCompare("app") == .orderedSame
            }
            if apps.count == 1, let app = apps.first { return app }
            return unique.min {
                $0.pathComponents.count < $1.pathComponents.count
            } ?? unique[0]
        }

        var discovered: [RPGMakerRTPVariant: URL] = [:]
        for (variant, urls) in rootsByVariant {
            discovered[variant] = preferredRoot(in: urls)
        }

        if discovered.isEmpty && unassigned.isEmpty {
            unassigned = [try resolveRPGMakerRTPRoot(at: extractionRoot)]
        }

        if discovered.isEmpty {
            let clues = [token(archiveURL.deletingPathExtension().lastPathComponent)]
                + unassigned.map { token($0.deletingLastPathComponent().lastPathComponent) }
            var inferred: RPGMakerRTPVariant?
            var cluesConflict = false
            for clue in clues {
                guard let candidate = variantFromName(clue) else { continue }
                if let current = inferred, current != candidate {
                    cluesConflict = true
                    break
                }
                inferred = candidate
            }
            if cluesConflict { inferred = nil }
            if inferred == nil { inferred = variantHint }
            guard let inferred, !unassigned.isEmpty else {
                throw RTPStoreError.unidentifiedRPGMakerVariant
            }
            discovered[inferred] = preferredRoot(in: unassigned)
        }

        guard !discovered.isEmpty else {
            throw RTPStoreError.unidentifiedRPGMakerVariant
        }
        return discovered
    }

    private func detectedRPGMakerRTPVariant(for game: ImportedGame) throws -> RPGMakerRTPVariant? {
        guard game.engine.id.rawValue == "rgss" else { return nil }
        let gameRoot = gameRootURL(for: game.id)
        let manifest = try loadGameManifest(at: gameRoot)
        var paths = manifest.detection.evidence.map {
            $0.relativePath.rawValue.lowercased()
        }
        let original = gameRoot.appendingPathComponent("original", isDirectory: true)
        var iniVariant: RPGMakerRTPVariant?
        if fileManager.fileExists(atPath: original.path) {
            let enumerator = fileManager.enumerator(
                at: original,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            var visited = 0
            while let url = enumerator?.nextObject() as? URL, visited < 400 {
                visited += 1
                paths.append(url.lastPathComponent.lowercased())
                guard url.lastPathComponent.lowercased() == "game.ini" else { continue }
                let ini = (try? String(contentsOf: url, encoding: .utf8))
                    ?? (try? String(contentsOf: url, encoding: .shiftJIS))
                    ?? ""
                let lower = ini.lowercased()
                if lower.contains("rgss3") {
                    iniVariant = .vxAce
                } else if lower.contains("rgss2") {
                    iniVariant = .vx
                } else if lower.contains("rgss1") {
                    iniVariant = .xp
                }
            }
        }
        if let iniVariant {
            return iniVariant
        }
        if paths.contains(where: {
            $0.hasSuffix("scripts.rvdata2") || $0.hasSuffix(".rgss3a")
        }) { return .vxAce }
        if paths.contains(where: {
            $0.hasSuffix("scripts.rvdata") || $0.hasSuffix(".rgss2a")
        }) { return .vx }
        if paths.contains(where: {
            $0.hasSuffix("scripts.rxdata") || $0.hasSuffix(".rgssad")
        }) { return .xp }
        return nil
    }

    private func rtpIndexURL() -> URL {
        layout.rtp.appendingPathComponent("manifest.json")
    }

    private func loadRTPIndex() throws -> RTPIndex {
        let url = rtpIndexURL()
        guard fileManager.fileExists(atPath: url.path) else { return RTPIndex() }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let index = try decoder().decode(RTPIndex.self, from: data)
            guard index.formatVersion == RTPIndex.currentFormatVersion else {
                throw RTPStoreError.corruptIndex
            }
            return index
        } catch let error as RTPStoreError {
            throw error
        } catch {
            throw RTPStoreError.corruptIndex
        }
    }

    private func writeRTPIndex(_ index: RTPIndex) throws {
        let data = try encoder().encode(index)
        try data.write(to: rtpIndexURL(), options: [.atomic])
    }

    private func taskRootURL(for id: ImportTaskID) -> URL {
        layout.staging.appendingPathComponent(
            id.rawValue.uuidString.lowercased(),
            isDirectory: true
        )
    }

    private func gameRootURL(for id: GameID) -> URL {
        layout.games.appendingPathComponent(id.rawValue.uuidString.lowercased(), isDirectory: true)
    }

    private func saveLibraryRootURL(for id: SaveLibraryID) -> URL {
        layout.saveLibraries.appendingPathComponent(
            id.rawValue.uuidString.lowercased(),
            isDirectory: true
        )
    }

    private func saveLibraryFilesURL(for id: SaveLibraryID) -> URL {
        saveLibraryRootURL(for: id).appendingPathComponent(
            Self.saveFilesDirectoryName,
            isDirectory: true
        )
    }

    private func detachedSaveRootURL(for id: GameID) -> URL {
        layout.detachedSaves.appendingPathComponent(
            id.rawValue.uuidString.lowercased(),
            isDirectory: true
        )
    }

    private func contentRootURL(for id: ImportTaskID) -> URL {
        taskRootURL(for: id).appendingPathComponent(
            Self.contentDirectoryName,
            isDirectory: true
        )
    }

    private func manifestURL(for id: ImportTaskID) -> URL {
        taskRootURL(for: id).appendingPathComponent(Self.manifestFileName, isDirectory: false)
    }

    private func validateExistingWorkspaceRoot(for id: ImportTaskID) throws {
        try validateExistingManagedDirectory(layout.root)
        try validateExistingManagedDirectory(layout.staging)
        try validateExistingManagedDirectory(taskRootURL(for: id))
    }

    private func validateExistingManagedDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw StorageError.manifestMissing
        }
        try rejectSymbolicLink(at: url)
        guard isDirectory.boolValue else {
            throw StorageError.managedPathIsNotDirectory
        }
    }

    private func ensureManagedDirectory(
        _ url: URL,
        excludedFromBackup: Bool? = nil
    ) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            try rejectSymbolicLink(at: url)
            guard isDirectory.boolValue else {
                throw StorageError.managedPathIsNotDirectory
            }
        } else {
            #if os(iOS)
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            #else
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            #endif
        }

        if let excludedFromBackup {
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = excludedFromBackup
            var mutableURL = url
            try mutableURL.setResourceValues(resourceValues)
        }
    }

    private func rejectSymbolicLink(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw StorageError.symbolicLinkAtManagedPath
        }
    }

    private struct TreeSummary {
        var byteCount: Int64 = 0
        var fileCount = 0
    }

    private struct ScannedEntry {
        let url: URL
        let relativePath: String
        let isDirectory: Bool
        let byteCount: Int64
    }

    private struct DetachedSaveManifest: Codable {
        static let currentFormatVersion = 1

        let formatVersion: Int
        let game: ImportedGame
        let detachedAt: Date

        init(game: ImportedGame, detachedAt: Date) {
            self.formatVersion = Self.currentFormatVersion
            self.game = game
            self.detachedAt = detachedAt
        }
    }

    private struct SaveLibraryManifest: Codable {
        static let currentFormatVersion = 1

        let formatVersion: Int
        let id: SaveLibraryID
        var title: String
        let engine: EngineDescriptor
        let contentFingerprint: String?
        let createdAt: Date
        var modifiedAt: Date

        init(id: SaveLibraryID, game: ImportedGame, date: Date = Date()) {
            self.formatVersion = Self.currentFormatVersion
            self.id = id
            self.title = game.title
            self.engine = game.engine
            self.contentFingerprint = game.contentFingerprint
            self.createdAt = date
            self.modifiedAt = date
        }
    }

    private func storageBudget(
        sourceByteCount: Int64,
        requiredByteCount: Int64
    ) throws -> StorageBudget {
        let capacity = try capacityProvider(layout.root)
        let available = capacity.availableByteCount
        let total = capacity.totalByteCount
        let gibibyte = Int64(1_073_741_824)
        let reserve = min(10 * gibibyte, max(2 * gibibyte, total / 20))
        return StorageBudget(
            sourceByteCount: max(0, sourceByteCount),
            requiredByteCount: max(0, requiredByteCount),
            availableByteCount: available,
            reserveByteCount: reserve
        )
    }

    private nonisolated static func systemVolumeCapacity(
        at root: URL
    ) throws -> VolumeCapacity {
        #if os(Linux)
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        let available = Int64(truncating: attributes[.systemFreeSize] as? NSNumber ?? 0)
        let total = Int64(truncating: attributes[.systemSize] as? NSNumber ?? 0)
        #else
        let values = try root.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ])
        let available = max(0, values.volumeAvailableCapacityForImportantUsage ?? 0)
        let total = Int64(max(0, values.volumeTotalCapacity ?? 0))
        #endif
        return VolumeCapacity(availableByteCount: available, totalByteCount: total)
    }

    private func summarizeTree(at root: URL) throws -> TreeSummary {
        let entries = try scannedEntries(at: root)
        return entries.reduce(into: TreeSummary()) { summary, entry in
            guard !entry.isDirectory else { return }
            summary.fileCount += 1
            let addition = summary.byteCount.addingReportingOverflow(entry.byteCount)
            summary.byteCount = addition.overflow ? Int64.max : addition.partialValue
        }
    }

    private func scannedEntries(at root: URL) throws -> [ScannedEntry] {
        try rejectSymbolicLink(at: root)
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw StorageError.sourceIsNotDirectory
        }

        let rootPath = root.standardizedFileURL.path
        var entries: [ScannedEntry] = []
        var caseFoldedPaths: Set<String> = []

        while let url = enumerator.nextObject() as? URL {
            guard entries.count < Self.maximumSourceEntryCount else {
                throw StorageError.sourceLimitExceeded
            }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw StorageError.unsupportedSourceEntry(url.lastPathComponent)
            }
            guard values.isDirectory == true || values.isRegularFile == true else {
                throw StorageError.unsupportedSourceEntry(url.lastPathComponent)
            }

            let standardizedPath = url.standardizedFileURL.path
            guard standardizedPath.hasPrefix(rootPath + "/") else {
                throw StorageError.unsupportedSourceEntry(url.lastPathComponent)
            }
            let relativePath = String(standardizedPath.dropFirst(rootPath.count + 1))
            _ = try StorageRelativePath(rawValue: relativePath)
            guard relativePath.utf8.count <= Self.maximumRelativePathByteCount else {
                throw StorageError.sourcePathTooLong
            }
            let folded = relativePath.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard caseFoldedPaths.insert(folded).inserted else {
                throw StorageError.caseInsensitivePathCollision(relativePath)
            }

            entries.append(
                ScannedEntry(
                    url: url,
                    relativePath: relativePath,
                    isDirectory: values.isDirectory == true,
                    byteCount: Int64(max(0, values.fileSize ?? 0))
                )
            )
        }
        if let enumerationError {
            throw enumerationError
        }
        return entries
    }

    private func copyValidatedTree(from source: URL, to destination: URL) throws -> TreeSummary {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw StorageError.sourceIsNotDirectory
        }
        let entries = try scannedEntries(at: source)
        try ensureManagedDirectory(destination, excludedFromBackup: true)
        var summary = TreeSummary()

        do {
            for entry in entries {
                let target = destination.appendingPathComponent(entry.relativePath, isDirectory: entry.isDirectory)
                if entry.isDirectory {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
                } else {
                    try fileManager.copyItem(at: entry.url, to: target)
                    summary.fileCount += 1
                    let addition = summary.byteCount.addingReportingOverflow(entry.byteCount)
                    summary.byteCount = addition.overflow ? Int64.max : addition.partialValue
                }
            }
            return summary
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private func byteCountOfDirectory(_ url: URL) throws -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        return try summarizeTree(at: url).byteCount
    }

    private func contentFingerprint(at root: URL) throws -> String {
        var hasher = SHA256Hasher()
        hasher.update(Data("YumeContentFingerprintV1\0".utf8))
        let entries = try scannedEntries(at: root)
            .filter { !$0.isDirectory }
            .sorted { $0.relativePath < $1.relativePath }

        for entry in entries {
            hasher.update(Data(entry.relativePath.utf8))
            hasher.update(Data([0]))
            var size = UInt64(entry.byteCount).bigEndian
            withUnsafeBytes(of: &size) { hasher.update(Data($0)) }

            let handle = try FileHandle(forReadingFrom: entry.url)
            defer { try? handle.close() }
            while true {
                let data = try handle.read(upToCount: 256 * 1_024) ?? Data()
                guard !data.isEmpty else { break }
                hasher.update(data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func loadGameManifest(at gameRoot: URL) throws -> GameManifest {
        try validateExistingManagedDirectory(gameRoot)
        let manifestURL = gameRoot.appendingPathComponent(Self.manifestFileName)
        try rejectSymbolicLink(at: manifestURL)
        do {
            let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
            let manifest = try decoder().decode(GameManifest.self, from: data)
            guard manifest.formatVersion == GameManifest.currentFormatVersion else {
                throw StorageError.unsupportedGameManifestVersion(manifest.formatVersion)
            }
            guard gameRoot.lastPathComponent.caseInsensitiveCompare(
                manifest.game.id.rawValue.uuidString
            ) == .orderedSame else {
                throw StorageError.corruptGameManifest
            }
            return manifest
        } catch let error as StorageError {
            throw error
        } catch {
            throw StorageError.corruptGameManifest
        }
    }

    private func writeGameManifest(_ manifest: GameManifest, to url: URL) throws {
        let data = try encoder().encode(manifest)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url, options: options)
    }

    private func writeDetachedSaveManifest(_ manifest: DetachedSaveManifest, at root: URL) throws {
        let data = try encoder().encode(manifest)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: root.appendingPathComponent(Self.manifestFileName), options: options)
    }

    private func copyMatchingDetachedSaves(
        for game: ImportedGame,
        to destination: URL
    ) throws -> URL? {
        guard let fingerprint = game.contentFingerprint else { return nil }
        let roots = try fileManager.contentsOfDirectory(
            at: layout.detachedSaves,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )

        for root in roots.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw StorageError.symbolicLinkAtManagedPath
            }
            let manifestURL = root.appendingPathComponent(Self.manifestFileName)
            let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
            let detached = try decoder().decode(DetachedSaveManifest.self, from: data)
            guard detached.formatVersion == DetachedSaveManifest.currentFormatVersion,
                  detached.game.contentFingerprint == fingerprint,
                  detached.game.engine == game.engine
            else { continue }

            let detachedSaves = root.appendingPathComponent(Self.savesDirectoryName, isDirectory: true)
            guard fileManager.fileExists(atPath: detachedSaves.path) else { continue }
            try fileManager.removeItem(at: destination)
            _ = try copyValidatedTree(from: detachedSaves, to: destination)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = false
            var mutableDestination = destination
            try mutableDestination.setResourceValues(resourceValues)
            return root
        }
        return nil
    }

    private func ensureSaveLibrary(
        for gameRoot: URL
    ) throws -> (manifest: GameManifest, library: SaveLibraryManifest, filesURL: URL) {
        var gameManifest = try loadGameManifest(at: gameRoot)

        if let id = gameManifest.saveLibraryID {
            let saveManifest = try loadSaveLibraryManifest(id: id)
            guard saveManifest.engine.id == gameManifest.game.engine.id else {
                throw StorageError.corruptSaveLibraryManifest
            }
            let filesURL = saveLibraryFilesURL(for: id)
            try ensureManagedDirectory(filesURL, excludedFromBackup: false)
            try migrateLegacySavesIfNeeded(from: gameRoot, to: filesURL)
            return (gameManifest, saveManifest, filesURL)
        }

        let bindings = try saveLibraryBindings()
        let reusable = try loadAllSaveLibraryManifests().first { candidate in
            bindings[candidate.id] == nil
                && candidate.engine == gameManifest.game.engine
                && candidate.contentFingerprint != nil
                && candidate.contentFingerprint == gameManifest.game.contentFingerprint
        }

        let saveManifest: SaveLibraryManifest
        if let reusable {
            saveManifest = reusable
        } else {
            let id = SaveLibraryID()
            let root = saveLibraryRootURL(for: id)
            try ensureManagedDirectory(root, excludedFromBackup: false)
            try ensureManagedDirectory(saveLibraryFilesURL(for: id), excludedFromBackup: false)
            saveManifest = SaveLibraryManifest(id: id, game: gameManifest.game)
            try writeSaveLibraryManifest(saveManifest)
        }

        let filesURL = saveLibraryFilesURL(for: saveManifest.id)
        try ensureManagedDirectory(filesURL, excludedFromBackup: false)
        try migrateLegacySavesIfNeeded(from: gameRoot, to: filesURL)
        gameManifest.saveLibraryID = saveManifest.id
        try writeGameManifest(
            gameManifest,
            to: gameRoot.appendingPathComponent(Self.manifestFileName)
        )
        return (gameManifest, saveManifest, filesURL)
    }

    private func migrateLegacySavesIfNeeded(from gameRoot: URL, to filesURL: URL) throws {
        let legacy = gameRoot.appendingPathComponent(Self.savesDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: legacy.path) else { return }
        let legacyEntries = try scannedEntries(at: legacy)
        guard !legacyEntries.isEmpty else {
            try? fileManager.removeItem(at: legacy)
            return
        }

        let destinationEntries = try scannedEntries(at: filesURL)
        if destinationEntries.isEmpty {
            try fileManager.removeItem(at: filesURL)
            try fileManager.moveItem(at: legacy, to: filesURL)
            var values = URLResourceValues()
            values.isExcludedFromBackup = false
            var mutableFilesURL = filesURL
            try mutableFilesURL.setResourceValues(values)
        } else {
            // A fingerprint-matched library already owns saves. Merge any
            // additional legacy paths without overwriting its canonical files.
            for entry in legacyEntries.sorted(by: { $0.relativePath < $1.relativePath }) {
                let destination = filesURL.appendingPathComponent(entry.relativePath)
                if fileManager.fileExists(atPath: destination.path) { continue }
                if entry.isDirectory {
                    try fileManager.createDirectory(
                        at: destination,
                        withIntermediateDirectories: true
                    )
                } else {
                    try fileManager.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.copyItem(at: entry.url, to: destination)
                }
            }
            try fileManager.removeItem(at: legacy)
        }
    }

    private func loadAllSaveLibraryManifests() throws -> [SaveLibraryManifest] {
        let roots = try fileManager.contentsOfDirectory(
            at: layout.saveLibraries,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return try roots.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).map { root in
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let uuid = UUID(uuidString: root.lastPathComponent)
            else { throw StorageError.corruptSaveLibraryManifest }
            let manifest = try loadSaveLibraryManifest(id: SaveLibraryID(rawValue: uuid))
            guard manifest.id.rawValue == uuid else {
                throw StorageError.corruptSaveLibraryManifest
            }
            return manifest
        }
    }

    private func loadSaveLibraryManifest(id: SaveLibraryID) throws -> SaveLibraryManifest {
        let root = saveLibraryRootURL(for: id)
        try validateExistingManagedDirectory(root)
        let url = root.appendingPathComponent(Self.manifestFileName)
        do {
            try rejectSymbolicLink(at: url)
            let manifest = try decoder().decode(
                SaveLibraryManifest.self,
                from: Data(contentsOf: url, options: [.mappedIfSafe])
            )
            guard manifest.formatVersion == SaveLibraryManifest.currentFormatVersion,
                  manifest.id == id
            else { throw StorageError.corruptSaveLibraryManifest }
            return manifest
        } catch let error as StorageError {
            throw error
        } catch {
            throw StorageError.corruptSaveLibraryManifest
        }
    }

    private func writeSaveLibraryManifest(_ manifest: SaveLibraryManifest) throws {
        let data = try encoder().encode(manifest)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(
            to: saveLibraryRootURL(for: manifest.id)
                .appendingPathComponent(Self.manifestFileName),
            options: options
        )
    }

    private func saveLibraryBindings() throws -> [SaveLibraryID: GameID] {
        let roots = try fileManager.contentsOfDirectory(
            at: layout.games,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var result: [SaveLibraryID: GameID] = [:]
        for root in roots {
            guard let gameID = UUID(uuidString: root.lastPathComponent) else { continue }
            let manifest = try loadGameManifest(at: root)
            if let saveID = manifest.saveLibraryID {
                result[saveID] = GameID(rawValue: gameID)
            }
        }
        return result
    }

    private func makeTreeReadOnly(at root: URL) throws {
        let entries = try scannedEntries(at: root)
        for entry in entries.sorted(by: { $0.relativePath.count > $1.relativePath.count }) {
            try fileManager.setAttributes(
                [.posixPermissions: entry.isDirectory ? 0o555 : 0o444],
                ofItemAtPath: entry.url.path
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
    }

    private func makeTreeWritable(at root: URL) {
        guard fileManager.fileExists(atPath: root.path) else { return }
        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { _, _ in true }
        ) {
            for case let url as URL in enumerator {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                try? fileManager.setAttributes(
                    [.posixPermissions: isDirectory ? 0o755 : 0o644],
                    ofItemAtPath: url.path
                )
            }
        }
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
    }

    private func loadAndValidateManifest(
        at url: URL,
        expectedTaskID: ImportTaskID
    ) throws -> StagingManifest {
        try rejectSymbolicLink(at: url)

        let manifest: StagingManifest
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            manifest = try decoder().decode(StagingManifest.self, from: data)
        } catch let error as StorageError {
            throw error
        } catch {
            throw StorageError.corruptManifest
        }

        guard manifest.formatVersion == StagingManifest.currentFormatVersion else {
            throw StorageError.unsupportedManifestVersion(manifest.formatVersion)
        }
        guard manifest.taskID == expectedTaskID else {
            throw StorageError.mismatchedTaskID
        }
        return manifest
    }

    private func writeManifest(_ manifest: StagingManifest, to url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try rejectSymbolicLink(at: url)
        }

        let data = try encoder().encode(manifest)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url, options: options)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
