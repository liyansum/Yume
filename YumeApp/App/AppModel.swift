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
    private let diagnostics: any DiagnosticStore
    private let playSessions: PlaySessionCoordinator
    let engineCatalog: GameEngineCatalog
    private var hasLoaded = false
    private var detectionContinuation: CheckedContinuation<ProbeResult?, Never>?
    private var duplicateContinuation: CheckedContinuation<DuplicateImportResolution, Never>?

    private(set) var games: [ImportedGame] = []
    private(set) var isLoadingLibrary = false
    private(set) var libraryLoadFailed = false
    private(set) var isImporting = false
    private(set) var importProgress: GameImportProgress?
    private(set) var importNotice: ImportNotice?
    private(set) var recoveryIssueCount = 0
    private(set) var activeGame: GameContentLocation?
    private(set) var playbackFailed = false
    private(set) var detectionChoice: DetectionChoice?
    private(set) var duplicateChoice: DuplicateChoice?
    private(set) var diagnosticEntryCount = 0
    private(set) var diagnosticExportURL: URL?

    init(
        library: any GameLibrary,
        importer: DirectoryGameImportService,
        contentProvider: any GameContentProvider,
        maintenance: any GameMaintenance,
        saveTransfer: any GameSaveTransfer,
        diagnostics: any DiagnosticStore,
        playSessions: PlaySessionCoordinator,
        engineCatalog: GameEngineCatalog
    ) {
        self.library = library
        self.importer = importer
        self.contentProvider = contentProvider
        self.maintenance = maintenance
        self.saveTransfer = saveTransfer
        self.diagnostics = diagnostics
        self.playSessions = playSessions
        self.engineCatalog = engineCatalog
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
            catalog: catalog
        )
        return AppModel(
            library: storage,
            importer: importer,
            contentProvider: storage,
            maintenance: storage,
            saveTransfer: storage,
            diagnostics: diagnostics,
            playSessions: playSessions,
            engineCatalog: catalog
        )
    }

    func loadLibraryIfNeeded() async {
        guard !hasLoaded else { return }
        if let report = try? await importer.recoverInterruptedTasks() {
            recoveryIssueCount = report.issues.count
        }
        await refreshDiagnostics()
        await reloadLibrary()
    }

    func reloadLibrary() async {
        isLoadingLibrary = true
        libraryLoadFailed = false

        do {
            games = try await library.allGames()
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
                    _ = try await importer.importZIP(
                        at: url,
                        progress: progressHandler,
                        resolveDetection: detectionResolver,
                        resolveDuplicate: duplicateResolver
                    )
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
                case .unsupportedGame:
                    failure = .unsupported
                case .duplicateGame:
                    failure = .duplicate
                }
                break
            } catch let error as SafeZIPError {
                switch error {
                case .encryptedEntryUnsupported:
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

    private func resolveDuplicate(_ existingGame: ImportedGame) async -> DuplicateImportResolution {
        guard duplicateContinuation == nil else { return .cancel }
        return await withCheckedContinuation { continuation in
            duplicateChoice = DuplicateChoice(existingGame: existingGame)
            duplicateContinuation = continuation
        }
    }

    func launch(_ game: ImportedGame) async {
        playbackFailed = false
        do {
            activeGame = try await playSessions.start(gameID: game.id)
        } catch {
            playbackFailed = true
        }
    }

    func dismissPlaybackFailure() {
        playbackFailed = false
    }

    func stopPlaying(markAsPlayed: Bool = true) async {
        let stoppedGameID = await playSessions.stop()
        activeGame = nil
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
            await reloadLibrary()
            return true
        } catch {
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

    func refreshDiagnostics() async {
        let entries = try? await diagnostics.recentEntries(limit: 2_000)
        diagnosticEntryCount = entries?.count ?? 0
    }

    func prepareDiagnosticExport() async {
        diagnosticExportURL = try? await diagnostics.makeExport()
    }
}

extension AppModel.ImportNotice.Failure: Error {}
