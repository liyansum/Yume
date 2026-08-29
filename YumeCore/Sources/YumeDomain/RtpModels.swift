import Foundation

/// The three mutually incompatible generations of the classic RPG Maker RTP.
/// Keeping this separate from the broader `rgss` engine ID lets storage mount
/// only the assets that match the game's Scripts data format.
public enum RPGMakerRTPVariant: String, Codable, CaseIterable, Hashable, Sendable {
    case xp
    case vx
    case vxAce = "vx-ace"

    public var packageID: String { "rgss-\(rawValue)" }
}

/// A user-imported Runtime Package (e.g. RPG Maker RTP). Yume never ships or
/// downloads these; the user imports assets they legally hold, and Yume maps
/// them into games locally.
public struct RTPPackage: Codable, Hashable, Sendable, Identifiable {
    public static let namePattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"

    public let id: String
    public let engineID: EngineID
    /// `nil` is retained for manifests written by builds that predate typed
    /// RPG Maker RTP imports. Legacy packages remain usable as a fallback.
    public let variant: RPGMakerRTPVariant?
    public let importedAt: Date
    public let fileCount: Int
    public let byteCount: Int64

    public init(
        id: String,
        engineID: EngineID,
        variant: RPGMakerRTPVariant? = nil,
        importedAt: Date,
        fileCount: Int,
        byteCount: Int64
    ) {
        self.id = id
        self.engineID = engineID
        self.variant = variant
        self.importedAt = importedAt
        self.fileCount = fileCount
        self.byteCount = byteCount
    }

    public static func isValidName(_ name: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: Self.namePattern) else { return false }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }
}

public enum RTPStoreError: Error, Equatable, Sendable {
    case invalidName
    case duplicateName
    case duplicateVariant(RPGMakerRTPVariant)
    case sourceIsNotDirectory
    case sourceIsEmpty
    case invalidRPGMakerLayout
    case ambiguousRPGMakerLayout
    case sourceUnreadable
    case sourceIsNotZIPArchive
    case invalidZIPArchive
    case unidentifiedRPGMakerVariant
    case copyFailed
    case packageNotFound
    case corruptIndex
}

public struct RTPIndex: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public private(set) var packages: [RTPPackage]

    public init(packages: [RTPPackage] = []) {
        self.formatVersion = Self.currentFormatVersion
        self.packages = packages
    }

    public mutating func upsert(_ package: RTPPackage) {
        packages.removeAll { $0.id == package.id }
        packages.append(package)
        packages.sort { $0.id < $1.id }
    }

    public mutating func remove(id: String) {
        packages.removeAll { $0.id == id }
    }
}
