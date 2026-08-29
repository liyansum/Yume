import Foundation
import Observation
import YumeApplication
import YumeDomain
import YumeInfrastructure

@MainActor
@Observable
final class AppModel {
    struct DetectionChoice: Equatable {
        let candidates: [ProbeResult]
    }

    struct DuplicateChoice: Equatable {
        let existingGame: ImportedGame
    }
    struct ArchivePasswordChoice: Equatable {
        let isRetry: Bool
    }
    struct ImportNotice: Identifiable, Equatable {
        enum Kind: Equatable {
            case success(count: Int)
            case partialSuccess(count: Int, failure: Failure)
            case failure(Failure)
        }

        enum Failure: Equatable {
            case archiveNotAvailable
            case encryptedArchive
            case unsupportedArchive
            case unsafeArchive
            case insufficientStorage
            case noSupportedGame
            case ambiguous
            case unsupported
            case unsupportedNativeComponent
            case invalidEngineArchive
            case unreadableEngineArchive
            case runtimeUnavailable
            case duplicate
            case unreadable
        }

        let id = UUID()
        let kind: Kind
    }

    private let library: any GameLibrary
    private let importer: DirectoryGameImportService
    private let contentProvider: any GameContentProvider
    private let maintenance: any GameMaintenance
    private let saveTransfer: any GameSaveTransfer
    private let saveLibraryManager: any GameSaveLibraryManaging
    private let diagnostics: any DiagnosticStore
    private let appLogStore: LocalAppLogStore
    private let playSessions: PlaySessionCoordinator
    private let rtpStore: any GameRuntimePackageStore
    let engineCatalog: GameEngineCatalog
    private var hasLoaded = false
    private var detectionContinuation: CheckedContinuation<ProbeResult?, Never>?
    private var duplicateContinuation: CheckedContinuation<DuplicateImportResolution, Never>?
    private var archivePasswordContinuation: CheckedContinuation<String?, Never>?

    private(set) var games: [ImportedGame] = []
    private(set) var isLoadingLibrary = false
    private(set) var libraryLoadFailed = false
    private(set) var isImporting = false
    private(set) var importProgress: GameImportProgress?
    private(set) var importNotice: ImportNotice?
    private(set) var recoveryIssueCount = 0
    private(set) var activeSession: GamePlaySession?
    private(set) var playbackFailed = false
    private(set) var detectionChoice: DetectionChoice?
    private(set) var duplicateChoice: DuplicateChoice?
    private(set) var archivePasswordChoice: ArchivePasswordChoice?
    private(set) var diagnosticEntryCount = 0
    private(set) var diagnosticExportURL: URL?
    private(set) var recoveredTasks: [StagingManifest] = []
    private(set) var diagnosticEntries: [DiagnosticEntry] = []
    private(set) var appLogs: [AppLogFile] = []
    private(set) var appLogAutoCleanupEnabled: Bool
    private(set) var appLogExportURL: URL?
    private(set) var isPlaybackSuspended = false
    private(set) var rtpPackages: [RTPPackage] = []
    private(set) var saveLibraries: [GameSaveLibrary] = []
    private var hasStartedAppLog = false

    private static let appLogAutoCleanupKey = "diagnostics.appLogs.autoCleanup7Days"

    init(
        library: any GameLibrary,
        importer: DirectoryGameImportService,
        contentProvider: any GameContentProvider,
        maintenance: any GameMaintenance,
        saveTransfer: any GameSaveTransfer,
        saveLibraryManager: any GameSaveLibraryManaging,
        diagnostics: any DiagnosticStore,
        appLogStore: LocalAppLogStore,
        playSessions: PlaySessionCoordinator,
        rtpStore: any GameRuntimePackageStore,
        engineCatalog: GameEngineCatalog
    ) {
        self.library = library
        self.importer = importer
        self.contentProvider = contentProvider
        self.maintenance = maintenance
        self.saveTransfer = saveTransfer
        self.saveLibraryManager = saveLibraryManager
        self.diagnostics = diagnostics
        self.appLogStore = appLogStore
        self.playSessions = playSessions
        self.rtpStore = rtpStore
        self.engineCatalog = engineCatalog
        let defaults = UserDefaults.standard
        self.appLogAutoCleanupEnabled = defaults.object(
            forKey: Self.appLogAutoCleanupKey
        ) == nil ? true : defaults.bool(forKey: Self.appLogAutoCleanupKey)
    }

    static func live() -> AppModel {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let storage = LocalGameStorage(
            baseURL: applicationSupport.appendingPathComponent("Yume", isDirectory: true)
        )
        let diagnostics = LocalDiagnosticStore(directoryURL: storage.layout.diagnostics)
        let appLogStore = LocalAppLogStore(
            directoryURL: storage.layout.diagnostics
                .appendingPathComponent("AppLogs", isDirectory: true)
        )
        let detectors = BuiltInGameDetectors.registry
        let catalog = GameEngineCatalog(detectors: detectors.detectors)
        let importer = DirectoryGameImportService(
            storage: storage,
            detectors: detectors,
            diagnostics: diagnostics
        )
        let playSessions = PlaySessionCoordinator(
            library: storage,
            contentProvider: storage,
            catalog: catalog,
            runtimePackageStore: storage
        )
        return AppModel(
            library: storage,
            importer: importer,
            contentProvider: storage,
            maintenance: storage,
            saveTransfer: storage,
            saveLibraryManager: storage,
            diagnostics: diagnostics,
            appLogStore: appLogStore,
            playSessions: playSessions,
            rtpStore: storage,
            engineCatalog: catalog
        )
    }

    func loadLibraryIfNeeded() async {
        guard !hasLoaded else { return }
        if let report = try? await importer.recoverInterruptedTasks() {
            recoveryIssueCount = report.issues.count
            recoveredTasks = report.recovered
        }
        await refreshDiagnostics()
        await reloadLibrary()
        if appLogAutoCleanupEnabled {
            await cleanExpiredRuntimeLogs()
        }
    }

    func reloadLibrary() async {
        isLoadingLibrary = true
        libraryLoadFailed = false

        do {
            games = try await library.allGames()
            saveLibraries = (try? await saveLibraryManager.saveLibraries()) ?? []
            hasLoaded = true
        } catch {
            libraryLoadFailed = true
        }

        isLoadingLibrary = false
    }

    func importSources(_ urls: [URL]) async {
        guard !isImporting, !urls.isEmpty else { return }
        isImporting = true
        importProgress = .validating
        importNotice = nil
        var importedCount = 0
        var failure: ImportNotice.Failure?

        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                let progressHandler: DirectoryGameImportService.ProgressHandler = { [weak self] progress in
                    await MainActor.run {
                        self?.importProgress = progress
                    }
                }
                let detectionResolver: DirectoryGameImportService.DetectionResolver = { [weak self] candidates in
                    guard let self else { return nil }
                    return await self.resolveDetection(candidates)
                }
                let duplicateResolver: DirectoryGameImportService.DuplicateResolver = { [weak self] existingGame in
                    guard let self else { return .cancel }
                    return await self.resolveDuplicate(existingGame)
                }
                if values.isDirectory == true {
                    _ = try await importer.importDirectory(
                        at: url,
                        progress: progressHandler,
                        resolveDetection: detectionResolver,
                        resolveDuplicate: duplicateResolver
                    )
                } else if url.pathExtension.lowercased() == "zip" {
                    var password: String?
                    var isRetry = false
                    while true {
                        do {
                            _ = try await importer.importZIP(
                                at: url,
                                password: password,
                                progress: progressHandler,
                                resolveDetection: detectionResolver,
                                resolveDuplicate: duplicateResolver
                            )
                            break
                        } catch SafeZIPError.passwordRequired {
                            guard let entered = await resolveArchivePassword(isRetry: isRetry) else {
                                throw ImportNotice.Failure.encryptedArchive
                            }
                            password = entered
                            isRetry = true
                        } catch SafeZIPError.incorrectPasswordOrCorruptArchive {
                            guard let entered = await resolveArchivePassword(isRetry: true) else {
                                throw ImportNotice.Failure.encryptedArchive
                            }
                            password = entered
                            isRetry = true
                        }
                    }
                } else if url.pathExtension.lowercased() == "7z" {
                    var password: String?
                    var isRetry = false
                    while true {
                        do {
                            _ = try await importer.import7z(
                                at: url,
                                password: password,
                                progress: progressHandler,
                                resolveDetection: detectionResolver,
                                resolveDuplicate: duplicateResolver
                            )
                            break
                        } catch Safe7zError.passwordRequired {
                            guard let entered = await resolveArchivePassword(isRetry: isRetry) else {
                                throw ImportNotice.Failure.encryptedArchive
                            }
                            password = entered
                            isRetry = true
                        } catch Safe7zError.incorrectPasswordOrCorruptArchive {
                            guard let entered = await resolveArchivePassword(isRetry: true) else {
                                throw ImportNotice.Failure.encryptedArchive
                            }
                            password = entered
                            isRetry = true
                        }
                    }
                } else {
                    throw ImportNotice.Failure.archiveNotAvailable
                }
                importedCount += 1
            } catch let presentationFailure as ImportNotice.Failure {
                failure = presentationFailure
                break
            } catch let error as GameImportError {
                switch error {
                case .insufficientStorage:
                    failure = .insufficientStorage
                case .noSupportedGameFound:
                    failure = .noSupportedGame
                case .ambiguousDetection:
                    failure = .ambiguous
                case let .unsupportedGame(report):
                    let detailCodes = Set(report.issues.map(\.detailCode))
                    if detailCodes.contains("compatibility.nativeComponent") {
                        failure = .unsupportedNativeComponent
                    } else if detailCodes.contains("detection.magicMismatch") {
                        failure = .invalidEngineArchive
                    } else if detailCodes.contains("detection.magicUnreadable") {
                        failure = .unreadableEngineArchive
                    } else if detailCodes.contains("compatibility.runtimeUnavailable") {
                        failure = .runtimeUnavailable
                    } else {
                        failure = .unsupported
                    }
                case .duplicateGame:
                    failure = .duplicate
                }
                break
            } catch let error as SafeZIPError {
                switch error {
                case .encryptedEntryUnsupported, .passwordRequired,
                     .incorrectPasswordOrCorruptArchive:
                    failure = .encryptedArchive
                case .multiDiskArchiveUnsupported, .unsupportedCompressionMethod,
                     .unsupportedFilenameEncoding:
                    failure = .unsupportedArchive
                case .unsafePath, .symbolicLinkEntry, .duplicatePath,
                     .entryLimitExceeded, .pathLimitExceeded,
                     .expandedSizeLimitExceeded, .compressionRatioLimitExceeded:
                    failure = .unsafeArchive
                default:
                    failure = .unreadable
                }
                break
            } catch let error as Safe7zError {
                switch error {
                case .passwordRequired, .incorrectPasswordOrCorruptArchive:
                    failure = .encryptedArchive
                case .unsafePath, .duplicatePath, .entryLimitExceeded,
                     .pathLimitExceeded, .expandedSizeLimitExceeded,
                     .compressionRatioLimitExceeded:
                    failure = .unsafeArchive
                case .invalidArchive, .sourceIsNotFileURL, .sourceMissing,
                     .sourceIsSymbolicLink, .destinationAlreadyExists,
                     .extractionFailed:
                    failure = .unreadable
                }
                break
            } catch {
                failure = .unreadable
                break
            }
        }

        await reloadLibrary()
        await refreshDiagnostics()
        importProgress = nil
        isImporting = false
        if let failure {
            importNotice = ImportNotice(
                kind: importedCount > 0
                    ? .partialSuccess(count: importedCount, failure: failure)
                    : .failure(failure)
            )
        } else {
            importNotice = ImportNotice(kind: .success(count: importedCount))
        }
    }

    func dismissImportNotice() {
        importNotice = nil
    }

    func dismissRecoveredTasks() {
        recoveredTasks = []
    }

    func chooseDetection(_ result: ProbeResult) {
        guard detectionChoice?.candidates.contains(result) == true else { return }
        detectionChoice = nil
        let continuation = detectionContinuation
        detectionContinuation = nil
        continuation?.resume(returning: result)
    }

    func cancelDetectionChoice() {
        detectionChoice = nil
        let continuation = detectionContinuation
        detectionContinuation = nil
        continuation?.resume(returning: nil)
    }

    private func resolveDetection(_ candidates: [ProbeResult]) async -> ProbeResult? {
        guard detectionContinuation == nil else { return nil }
        return await withCheckedContinuation { continuation in
            detectionChoice = DetectionChoice(candidates: candidates)
            detectionContinuation = continuation
        }
    }

    func resolveDuplicateChoice(_ resolution: DuplicateImportResolution) {
        duplicateChoice = nil
        let continuation = duplicateContinuation
        duplicateContinuation = nil
        continuation?.resume(returning: resolution)
    }

    func submitArchivePassword(_ password: String) {
        guard !password.isEmpty else { return }
        archivePasswordChoice = nil
        let continuation = archivePasswordContinuation
        archivePasswordContinuation = nil
        continuation?.resume(returning: password)
    }

    func cancelArchivePassword() {
        archivePasswordChoice = nil
        let continuation = archivePasswordContinuation
        archivePasswordContinuation = nil
        continuation?.resume(returning: nil)
    }

    private func resolveArchivePassword(isRetry: Bool) async -> String? {
        guard archivePasswordContinuation == nil else { return nil }
        return await withCheckedContinuation { continuation in
            archivePasswordChoice = ArchivePasswordChoice(isRetry: isRetry)
            archivePasswordContinuation = continuation
        }
    }

    private func resolveDuplicate(_ existingGame: ImportedGame) async -> DuplicateImportResolution {
        guard duplicateContinuation == nil else { return .cancel }
        return await withCheckedContinuation { continuation in
            duplicateChoice = DuplicateChoice(existingGame: existingGame)
            duplicateContinuation = continuation
        }
    }

    func launch(_ game: ImportedGame) async {
        playbackFailed = false
        await recordAppLog(
            subsystem: "player",
            message: "launch.requested",
            metadata: ["gameID": game.id.rawValue.uuidString, "engine": game.engine.id.rawValue]
        )
        do {
            let session = try await playSessions.start(gameID: game.id)
            prepareRuntimeLogsForNewSession(at: session.content.logRootURL)
            activeSession = session
            await recordAppLog(
                subsystem: "player",
                message: "launch.prepared",
                metadata: [
                    "gameID": game.id.rawValue.uuidString,
                    "engine": game.engine.id.rawValue,
                    "runtime": runtimeIdentifier(for: session.launchPlan.kind),
                    "runtimeVersion": session.launchPlan.runtimeVersionLabel,
                    "contentRoot": session.content.rootURL.path,
                    "saveRoot": session.content.saveRootURL.path,
                    "logRoot": session.content.logRootURL.path,
                    "rtpMountCount": String(session.rtpMountRoots.count),
                    "rtpMounts": session.rtpMountRoots.map(\.path).joined(separator: " | ")
                ]
            )
        } catch {
            playbackFailed = true
            await recordAppLog(
                level: .error,
                subsystem: "player",
                message: "launch.failed",
                metadata: [
                    "gameID": game.id.rawValue.uuidString,
                    "error": String(describing: error)
                ]
            )
        }
    }

    func dismissPlaybackFailure() {
        playbackFailed = false
    }

    func suspendPlayback() {
        isPlaybackSuspended = true
    }

    func resumePlayback() {
        isPlaybackSuspended = false
    }

    func stopPlaying(markAsPlayed: Bool = true) async {
        let stoppedGameID = await playSessions.stop()
        activeSession = nil
        await recordAppLog(
            subsystem: "player",
            message: "session.stopped",
            metadata: ["gameID": stoppedGameID?.rawValue.uuidString ?? "none"]
        )
        guard markAsPlayed, let gameID = stoppedGameID else { return }
        try? await library.markPlayed(id: gameID, at: Date())
        await reloadLibrary()
    }

    func storageBreakdown(for game: ImportedGame) async -> GameStorageBreakdown? {
        try? await maintenance.storageBreakdown(for: game.id)
    }

    func remove(_ game: ImportedGame, policy: GameRemovalPolicy) async -> Bool {
        do {
            try await maintenance.removeGame(id: game.id, policy: policy)
            await recordAppLog(
                subsystem: "library",
                message: "game.removed",
                metadata: [
                    "gameID": game.id.rawValue.uuidString,
                    "savePolicy": policy.rawValue
                ]
            )
            await reloadLibrary()
            return true
        } catch {
            await recordAppLog(
                level: .error,
                subsystem: "library",
                message: "game.remove-failed",
                metadata: [
                    "gameID": game.id.rawValue.uuidString,
                    "error": String(describing: error)
                ]
            )
            return false
        }
    }

    func rename(_ game: ImportedGame, to title: String) async -> Bool {
        do {
            try await maintenance.renameGame(id: game.id, title: title)
            await recordAppLog(
                subsystem: "library",
                message: "game.renamed",
                metadata: ["gameID": game.id.rawValue.uuidString]
            )
            await reloadLibrary()
            return true
        } catch {
            await recordAppLog(
                level: .error,
                subsystem: "library",
                message: "game.rename-failed",
                metadata: [
                    "gameID": game.id.rawValue.uuidString,
                    "error": String(describing: error)
                ]
            )
            return false
        }
    }

    func refreshSaveLibraries() async {
        saveLibraries = (try? await saveLibraryManager.saveLibraries()) ?? []
    }

    func saveLibrary(for game: ImportedGame) async -> GameSaveLibrary? {
        let library = try? await saveLibraryManager.saveLibrary(for: game.id)
        await refreshSaveLibraries()
        return library
    }

    func bindSaveLibrary(_ library: GameSaveLibrary, to game: ImportedGame) async -> Bool {
        do {
            try await saveLibraryManager.bindSaveLibrary(library.id, to: game.id)
            await refreshSaveLibraries()
            await recordAppLog(
                subsystem: "saves",
                message: "library.bound",
                metadata: [
                    "gameID": game.id.rawValue.uuidString,
                    "saveLibraryID": library.id.rawValue.uuidString
                ]
            )
            return true
        } catch {
            await recordAppLog(
                level: .error,
                subsystem: "saves",
                message: "library.bind-failed",
                metadata: [
                    "gameID": game.id.rawValue.uuidString,
                    "saveLibraryID": library.id.rawValue.uuidString,
                    "error": String(describing: error)
                ]
            )
            return false
        }
    }

    func deleteSaveLibrary(_ library: GameSaveLibrary) async -> Bool {
        do {
            try await saveLibraryManager.deleteSaveLibrary(id: library.id)
            await refreshSaveLibraries()
            await recordAppLog(
                subsystem: "saves",
                message: "library.deleted",
                metadata: ["saveLibraryID": library.id.rawValue.uuidString]
            )
            return true
        } catch {
            await recordAppLog(
                level: .error,
                subsystem: "saves",
                message: "library.delete-failed",
                metadata: [
                    "saveLibraryID": library.id.rawValue.uuidString,
                    "error": String(describing: error)
                ]
            )
            return false
        }
    }

    func exportSaves(for game: ImportedGame) async -> URL? {
        try? await saveTransfer.exportSaves(for: game.id)
    }

    func importSaves(from url: URL, for game: ImportedGame) async -> Bool {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            try await saveTransfer.importSaves(from: url, for: game.id)
            return true
        } catch {
            return false
        }
    }

    func refreshRTPPackages() async {
        rtpPackages = (try? await rtpStore.listRTPPackages()) ?? []
    }

    func importRPGMakerRTP(
        variant: RPGMakerRTPVariant,
        from url: URL
    ) async -> RTPStoreError? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            _ = try await rtpStore.importRPGMakerRTP(variant: variant, from: url)
            await refreshRTPPackages()
            return nil
        } catch let error as RTPStoreError {
            return error
        } catch {
            return .copyFailed
        }
    }

    func removeRTPPackage(_ package: RTPPackage) async -> Bool {
        do {
            try await rtpStore.removeRTPPackage(id: package.id)
            await refreshRTPPackages()
            return true
        } catch {
            return false
        }
    }

    func refreshDiagnostics() async {
        let entries = try? await diagnostics.recentEntries(limit: 2_000)
        diagnosticEntries = entries ?? []
        diagnosticEntryCount = entries?.count ?? 0
    }

    func prepareDiagnosticExport() async {
        diagnosticExportURL = try? await diagnostics.makeExport()
    }

    func startAppLoggingIfNeeded() async {
        guard !hasStartedAppLog else { return }
        hasStartedAppLog = true
        if appLogAutoCleanupEnabled {
            _ = try? await appLogStore.removeLogs(
                olderThan: Date(timeIntervalSinceNow: -7 * 24 * 60 * 60)
            )
        }
        do {
            _ = try await appLogStore.startSession(metadata: appLogSessionMetadata)
            try await appLogStore.append(
                subsystem: "app",
                message: "logging.ready",
                metadata: ["autoCleanup7Days": appLogAutoCleanupEnabled ? "true" : "false"]
            )
        } catch {
            hasStartedAppLog = false
        }
        await refreshAppLogs()
    }

    func recordPlayerLog(
        _ message: String,
        isError: Bool = false,
        metadata: [String: String] = [:]
    ) async {
        await recordAppLog(
            level: isError ? .error : .information,
            subsystem: "runtime",
            message: message,
            metadata: metadata
        )
    }

    func recordAppEvent(
        _ message: String,
        metadata: [String: String] = [:]
    ) async {
        await recordAppLog(
            subsystem: "app",
            message: message,
            metadata: metadata
        )
    }

    func refreshAppLogs() async {
        appLogs = (try? await appLogStore.logs()) ?? []
    }

    func setAppLogAutoCleanupEnabled(_ enabled: Bool) async {
        appLogAutoCleanupEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.appLogAutoCleanupKey)
        if enabled {
            _ = try? await appLogStore.removeLogs(
                olderThan: Date(timeIntervalSinceNow: -7 * 24 * 60 * 60)
            )
            await cleanExpiredRuntimeLogs()
        }
        await recordAppLog(
            subsystem: "app-log",
            message: "auto-cleanup.changed",
            metadata: ["enabled": enabled ? "true" : "false"]
        )
        await refreshAppLogs()
    }

    func removeAllAppLogs() async -> Bool {
        var removedRuntimeLogs = true
        for game in games {
            guard let content = try? await contentProvider.contentLocation(for: game.id),
                  let files = try? FileManager.default.contentsOfDirectory(
                    at: content.logRootURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                  )
            else { continue }
            for file in files {
                let ext = file.pathExtension.lowercased()
                guard ["log", "txt", "json", "jsonl"].contains(ext),
                      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { continue }
                do {
                    try FileManager.default.removeItem(at: file)
                } catch {
                    removedRuntimeLogs = false
                }
            }
        }
        do {
            try await appLogStore.removeAllLogs()
            _ = try await appLogStore.startSession(metadata: appLogSessionMetadata)
            try await appLogStore.append(
                subsystem: "app-log",
                message: "logs.manually-cleared"
            )
            appLogExportURL = nil
            await refreshAppLogs()
            return removedRuntimeLogs
        } catch {
            await refreshAppLogs()
            return false
        }
    }

    func prepareAppLogExport() async {
        var runtimeLogs: [URL] = []
        for game in games {
            guard let content = try? await contentProvider.contentLocation(for: game.id),
                  let files = try? FileManager.default.contentsOfDirectory(
                    at: content.logRootURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                  )
            else { continue }
            runtimeLogs.append(contentsOf: files.filter { url in
                let ext = url.pathExtension.lowercased()
                return ["log", "txt", "json", "jsonl"].contains(ext)
                    && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            })
        }
        appLogExportURL = try? await appLogStore.makeExport(
            additionalLogFiles: runtimeLogs
        )
    }

    private func recordAppLog(
        level: AppLogLevel = .information,
        subsystem: String,
        message: String,
        metadata: [String: String] = [:]
    ) async {
        if !hasStartedAppLog { await startAppLoggingIfNeeded() }
        try? await appLogStore.append(
            level: level,
            subsystem: subsystem,
            message: message,
            metadata: metadata
        )
    }

    private func prepareRuntimeLogsForNewSession(at root: URL) {
        let files = FileManager.default
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let entries = try? files.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let stamp = Self.runtimeLogTimestamp.string(from: Date())
        for entry in entries {
            let ext = entry.pathExtension.lowercased()
            guard ["log", "txt", "json", "jsonl"].contains(ext),
                  (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            if entry.lastPathComponent.hasPrefix("session-") { continue }
            let destination = root.appendingPathComponent(
                "session-\(stamp)-\(UUID().uuidString.prefix(8))-\(entry.lastPathComponent)"
            )
            try? files.moveItem(at: entry, to: destination)
        }
        if appLogAutoCleanupEnabled {
            cleanExpiredRuntimeLogs(in: root)
        }
    }

    private func cleanExpiredRuntimeLogs() async {
        for game in games {
            guard let content = try? await contentProvider.contentLocation(for: game.id) else { continue }
            cleanExpiredRuntimeLogs(in: content.logRootURL)
        }
    }

    private func cleanExpiredRuntimeLogs(in root: URL) {
        let cutoff = Date(timeIntervalSinceNow: -7 * 24 * 60 * 60)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("session-") {
            guard let values = try? file.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey]
            ), values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static let runtimeLogTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private var appLogSessionMetadata: [String: String] {
        [
            "appVersion": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            "build": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
            "locale": Locale.current.identifier,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physicalMemory": String(ProcessInfo.processInfo.physicalMemory),
            "processorCount": String(ProcessInfo.processInfo.processorCount),
            "process": ProcessInfo.processInfo.processName
        ]
    }

    private func runtimeIdentifier(for kind: LaunchKind) -> String {
        switch kind {
        case .web: "restricted-web"
        case let .embeddedWebRuntime(identifier): identifier
        case let .hostedRuntime(identifier): identifier
        case let .notPlanned(reason): "not-planned:\(reason)"
        }
    }
}

extension AppModel.ImportNotice.Failure: Error {}
