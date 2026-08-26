import Foundation
import YumeDomain

public struct SaveTransferFile: Codable, Hashable, Sendable {
    public let relativePath: StorageRelativePath
    public let data: Data

    public init(relativePath: StorageRelativePath, data: Data) {
        self.relativePath = relativePath
        self.data = data
    }
}

public struct SaveTransferPackage: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let gameID: GameID
    public let engineID: EngineID
    public let compatibilityVersion: String
    public let exportedAt: Date
    public let files: [SaveTransferFile]

    public init(
        gameID: GameID,
        engineID: EngineID,
        compatibilityVersion: String,
        exportedAt: Date,
        files: [SaveTransferFile]
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.gameID = gameID
        self.engineID = engineID
        self.compatibilityVersion = compatibilityVersion
        self.exportedAt = exportedAt
        self.files = files
    }
}

public enum SaveTransferError: Error, Equatable, Sendable {
    case gameNotFound
    case packageTooLarge
    case tooManyFiles
    case corruptPackage
    case unsupportedFormatVersion(Int)
    case gameMismatch
    case engineMismatch
    case duplicatePath(StorageRelativePath)
}

public protocol GameSaveTransfer: Sendable {
    func exportSaves(for id: GameID) async throws -> URL
    func importSaves(from packageURL: URL, for id: GameID) async throws
}
