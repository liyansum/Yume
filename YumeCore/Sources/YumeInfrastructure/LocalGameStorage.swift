import Foundation
import YumeApplication
import YumeDomain

public actor LocalGameStorage: ImportStagingStorage {
    public struct Layout: Sendable, Equatable {
        public let root: URL
        public let games: URL
        public let staging: URL
        public let cache: URL
        public let diagnostics: URL

        fileprivate init(root: URL) {
            self.root = root
            self.games = root.appendingPathComponent("Games", isDirectory: true)
            self.staging = root.appendingPathComponent("Staging", isDirectory: true)
            self.cache = root.appendingPathComponent("Cache", isDirectory: true)
            self.diagnostics = root.appendingPathComponent("Diagnostics", isDirectory: true)
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
    }

    public nonisolated let layout: Layout

    private static let manifestFileName = "manifest.json"
    private static let contentDirectoryName = "content"

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
        try fileManager.removeItem(at: taskRoot)
    }

    private func taskRootURL(for id: ImportTaskID) -> URL {
        layout.staging.appendingPathComponent(
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
