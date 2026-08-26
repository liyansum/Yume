import Foundation
import YumeApplication
import YumeDomain

public actor LocalGameStorage: GameImportStorage, GameLibrary, GameContentProvider, GameMaintenance, GameSaveTransfer {
    public struct Layout: Sendable, Equatable {
        public let root: URL
        public let games: URL
        public let staging: URL
        public let cache: URL
        public let diagnostics: URL
        public let detachedSaves: URL

        fileprivate init(root: URL) {
            self.root = root
            self.games = root.appendingPathComponent("Games", isDirectory: true)
            self.staging = root.appendingPathComponent("Staging", isDirectory: true)
            self.cache = root.appendingPathComponent("Cache", isDirectory: true)
            self.diagnostics = root.appendingPathComponent("Diagnostics", isDirectory: true)
            self.detachedSaves = root.appendingPathComponent("DetachedSaves", isDirectory: true)
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
    }

    public nonisolated let layout: Layout

    private static let manifestFileName = "manifest.json"
    private static let contentDirectoryName = "content"
    private static let originalDirectoryName = "original"
    private static let derivedDirectoryName = "derived"
    private static let savesDirectoryName = "saves"
    private static let logsDirectoryName = "logs"
    private static let maximumSourceEntryCount = 250_000
    private static let maximumRelativePathByteCount = 1_024
    private static let maximumSaveTransferFileCount = 10_000
    private static let maximumSaveTransferByteCount = 100 * 1_024 * 1_024

    private let fileManager: FileManager

    public init(baseURL: URL) {
        self.layout = Layout(root: baseURL.standardizedFileURL)
        self.fileManager = .default
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

    public func validateZIPSource(at sourceURL: URL) async throws -> StorageBudget {
        try await prepareStorage()
        let inspection = try SafeZIPExtractor().inspect(sourceURL)
        guard !inspection.containsEncryptedEntries else {
            throw SafeZIPError.encryptedEntryUnsupported
        }
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let archiveByteCount = Int64(truncating: attributes[.size] as? NSNumber ?? 0)
        return try storageBudget(
            sourceByteCount: archiveByteCount,
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

        let inspection = try SafeZIPExtractor().extract(sourceURL, to: destination)
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
            let maximumDepth = min(4, components.count)
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
        if isReplacement {
            guard fileManager.fileExists(atPath: destination.path) else {
                throw StorageError.corruptGameManifest
            }
            let existingManifest = try loadGameManifest(at: destination)
            guard existingManifest.game.engine.id == manifest.game.engine.id else {
                throw StorageError.corruptGameManifest
            }
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
        try writeGameManifest(manifest, to: content.appendingPathComponent(Self.manifestFileName))
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
        let manifest = try loadGameManifest(at: root)
        makeTreeWritable(at: root)
        if policy == .preserveSaves {
            let saves = root.appendingPathComponent(Self.savesDirectoryName, isDirectory: true)
            if fileManager.fileExists(atPath: saves.path), !(try scannedEntries(at: saves)).isEmpty {
                let detachedRoot = detachedSaveRootURL(for: id)
                guard !fileManager.fileExists(atPath: detachedRoot.path) else {
                    throw StorageError.detachedSavesAlreadyExist
                }
                try ensureManagedDirectory(detachedRoot, excludedFromBackup: false)
                try fileManager.moveItem(
                    at: saves,
                    to: detachedRoot.appendingPathComponent(Self.savesDirectoryName, isDirectory: true)
                )
                let detachedManifest = DetachedSaveManifest(
                    game: manifest.game,
                    detachedAt: Date()
                )
                try writeDetachedSaveManifest(detachedManifest, at: detachedRoot)
            }
        }
        try fileManager.removeItem(at: root)
    }

    public func storageBreakdown(for id: GameID) async throws -> GameStorageBreakdown {
        try await prepareStorage()
        let root = gameRootURL(for: id)
        _ = try loadGameManifest(at: root)
        return GameStorageBreakdown(
            gameID: id,
            originalByteCount: try byteCountOfDirectory(
                root.appendingPathComponent(Self.originalDirectoryName, isDirectory: true)
            ),
            derivedByteCount: try byteCountOfDirectory(
                root.appendingPathComponent(Self.derivedDirectoryName, isDirectory: true)
            ),
            saveByteCount: try byteCountOfDirectory(
                root.appendingPathComponent(Self.savesDirectoryName, isDirectory: true)
            ),
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

    public func contentLocation(for id: GameID) async throws -> GameContentLocation {
        try await prepareStorage()
        let gameRoot = gameRootURL(for: id)
        guard fileManager.fileExists(atPath: gameRoot.path) else {
            throw GameContentError.gameNotFound
        }
        let manifest = try loadGameManifest(at: gameRoot)
        let supportedWebEngines: Set<String> = ["rpg-maker-mv", "rpg-maker-mz", "tyranoscript"]
        guard supportedWebEngines.contains(manifest.game.engine.id.rawValue) else {
            throw GameContentError.runtimeUnavailable(manifest.game.engine.id)
        }

        var contentRoot = gameRoot.appendingPathComponent(
            manifest.contentRoot.rawValue,
            isDirectory: true
        ).standardizedFileURL
        let nestedWebRoot = contentRoot.appendingPathComponent("www", isDirectory: true)
        if fileManager.fileExists(atPath: nestedWebRoot.appendingPathComponent("index.html").path) {
            contentRoot = nestedWebRoot
        }
        let entryPoint = try StorageRelativePath(rawValue: "index.html")
        guard fileManager.fileExists(atPath: contentRoot.appendingPathComponent(entryPoint.rawValue).path) else {
            throw GameContentError.entryPointMissing
        }
        return GameContentLocation(
            game: manifest.game,
            rootURL: contentRoot,
            saveRootURL: gameRoot.appendingPathComponent(Self.savesDirectoryName, isDirectory: true),
            entryPoint: entryPoint
        )
    }

    public func exportSaves(for id: GameID) async throws -> URL {
        try await prepareStorage()
        let gameRoot = gameRootURL(for: id)
        guard fileManager.fileExists(atPath: gameRoot.path) else {
            throw SaveTransferError.gameNotFound
        }
        let manifest = try loadGameManifest(at: gameRoot)
        let saveRoot = gameRoot.appendingPathComponent(Self.savesDirectoryName, isDirectory: true)
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
        let gameManifest = try loadGameManifest(at: gameRoot)
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

            let saves = gameRoot.appendingPathComponent(Self.savesDirectoryName, isDirectory: true)
            try fileManager.moveItem(at: saves, to: backup)
            do {
                try fileManager.moveItem(at: replacement, to: saves)
                try fileManager.removeItem(at: backup)
                try? fileManager.removeItem(at: transactionRoot)
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

    private func taskRootURL(for id: ImportTaskID) -> URL {
        layout.staging.appendingPathComponent(
            id.rawValue.uuidString.lowercased(),
            isDirectory: true
        )
    }

    private func gameRootURL(for id: GameID) -> URL {
        layout.games.appendingPathComponent(id.rawValue.uuidString.lowercased(), isDirectory: true)
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

    private func storageBudget(
        sourceByteCount: Int64,
        requiredByteCount: Int64
    ) throws -> StorageBudget {
        #if os(Linux)
        let attributes = try fileManager.attributesOfFileSystem(forPath: layout.root.path)
        let available = Int64(truncating: attributes[.systemFreeSize] as? NSNumber ?? 0)
        let total = Int64(truncating: attributes[.systemSize] as? NSNumber ?? 0)
        #else
        let values = try layout.root.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ])
        let available = max(0, values.volumeAvailableCapacityForImportantUsage ?? 0)
        let total = Int64(max(0, values.volumeTotalCapacity ?? 0))
        #endif
        let gibibyte = Int64(1_073_741_824)
        let reserve = min(10 * gibibyte, max(2 * gibibyte, total / 20))
        return StorageBudget(
            sourceByteCount: max(0, sourceByteCount),
            requiredByteCount: max(0, requiredByteCount),
            availableByteCount: available,
            reserveByteCount: reserve
        )
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
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }
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
