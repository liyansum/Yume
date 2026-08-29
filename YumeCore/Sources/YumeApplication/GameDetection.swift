import Foundation
import YumeDomain

public struct DetectionSnapshot: Sendable, Equatable {
    public let rootRelativePath: StorageRelativePath
    public let regularFiles: Set<String>
    public let directories: Set<String>
    private let regularFilesByNormalizedPath: [String: String]
    private let directoriesByNormalizedPath: [String: String]

    public init(
        rootRelativePath: StorageRelativePath,
        regularFiles: Set<String>,
        directories: Set<String>
    ) {
        self.rootRelativePath = rootRelativePath
        self.regularFiles = regularFiles
        self.directories = directories
        self.regularFilesByNormalizedPath = Self.indexByNormalizedPath(regularFiles)
        self.directoriesByNormalizedPath = Self.indexByNormalizedPath(directories)
    }

    public func containsFile(_ relativePath: String) -> Bool {
        matchingFile(relativePath) != nil
    }

    public func containsDirectory(_ relativePath: String) -> Bool {
        matchingDirectory(relativePath) != nil
    }

    public func matchingFile(_ relativePath: String) -> String? {
        regularFilesByNormalizedPath[Self.normalized(relativePath)]
    }

    public func matchingDirectory(_ relativePath: String) -> String? {
        directoriesByNormalizedPath[Self.normalized(relativePath)]
    }

    public func containsFile(withExtension extensionName: String) -> Bool {
        let suffix = ".\(extensionName.lowercased())"
        return regularFilesByNormalizedPath.keys.contains { $0.hasSuffix(suffix) }
    }

    public func files(withExtension extensionName: String) -> [String] {
        let suffix = ".\(extensionName.lowercased())"
        return regularFilesByNormalizedPath
            .filter { $0.key.hasSuffix(suffix) }
            .map(\.value)
            .sorted()
    }

    private static func indexByNormalizedPath(_ paths: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        for path in paths.sorted() {
            let originalPath = normalizedSeparators(path)
            result[normalized(originalPath), default: originalPath] = originalPath
        }
        return result
    }

    private static func normalized(_ path: String) -> String {
        normalizedSeparators(path).lowercased()
    }

    private static func normalizedSeparators(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

public protocol GameDetector: Sendable {
    var descriptor: EngineDescriptor { get }
    /// Whether an in-app runtime can actually host this engine today.
    /// Detectors stay usable for identification even before a runtime ships.
    var runtimeAvailable: Bool { get }
    func probe(_ snapshot: DetectionSnapshot) -> ProbeResult?
}

public struct DetectorRegistry: Sendable {
    public let detectors: [any GameDetector]
    public let ambiguityTolerance: Int

    public init(detectors: [any GameDetector], ambiguityTolerance: Int = 5) {
        self.detectors = detectors
        self.ambiguityTolerance = max(0, ambiguityTolerance)
    }

    public func decide(_ snapshot: DetectionSnapshot) -> DetectionDecision {
        let matches = detectors.compactMap { $0.probe(snapshot) }.sorted(by: Self.preferred)
        guard let best = matches.first else { return .noMatch }

        let contenders = matches.filter { best.confidence - $0.confidence <= ambiguityTolerance }
        if contenders.count > 1 {
            return .ambiguous(contenders)
        }
        return .selected(best)
    }

    private static func preferred(_ lhs: ProbeResult, _ rhs: ProbeResult) -> Bool {
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        if lhs.engine.id.rawValue != rhs.engine.id.rawValue {
            return lhs.engine.id.rawValue < rhs.engine.id.rawValue
        }
        return lhs.rootRelativePath.rawValue < rhs.rootRelativePath.rawValue
    }
}
