import Foundation

public struct StorageRelativePath: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case empty
        case absolute
        case ambiguousSeparator
        case invalidComponent
        case nullByte
    }

    public let rawValue: String

    public init(rawValue: String) throws {
        guard !rawValue.isEmpty else {
            throw ValidationError.empty
        }
        guard !rawValue.utf8.contains(0) else {
            throw ValidationError.nullByte
        }
        guard !rawValue.hasPrefix("/") && !Self.hasWindowsDrivePrefix(rawValue) else {
            throw ValidationError.absolute
        }
        guard !rawValue.contains("\\") else {
            throw ValidationError.ambiguousSeparator
        }

        let components = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ValidationError.invalidComponent
        }

        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        do {
            try self.init(rawValue: rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid storage-relative path"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func hasWindowsDrivePrefix(_ value: String) -> Bool {
        guard value.count >= 2 else { return false }
        let characters = Array(value.prefix(2))
        return characters[0].isASCII && characters[0].isLetter && characters[1] == ":"
    }
}

public struct StagingManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let taskID: ImportTaskID
    public private(set) var state: ImportState
    public let createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var ownedPaths: [StorageRelativePath]

    public init(
        taskID: ImportTaskID,
        state: ImportState = .active(stage: .picked),
        createdAt: Date,
        updatedAt: Date? = nil,
        ownedPaths: [StorageRelativePath] = []
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.taskID = taskID
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.ownedPaths = Self.uniqued(ownedPaths)
    }

    public mutating func registerOwnedPath(_ path: StorageRelativePath, at date: Date) {
        guard !ownedPaths.contains(path) else { return }
        ownedPaths.append(path)
        updatedAt = date
    }

    public mutating func transition(to state: ImportState, at date: Date) {
        self.state = state
        updatedAt = date
    }

    private static func uniqued(_ paths: [StorageRelativePath]) -> [StorageRelativePath] {
        var seen: Set<StorageRelativePath> = []
        return paths.filter { seen.insert($0).inserted }
    }
}
