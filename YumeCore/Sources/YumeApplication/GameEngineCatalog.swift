import Foundation
import YumeDomain

/// How the app hosts a given engine today. The catalog is the single source
/// of truth for this policy; storage and UI must not hardcode engine IDs.
public enum EngineHostingKind: String, Codable, Sendable {
    /// Detection and compatibility reporting only; no runtime ships yet.
    case detectionOnly
    /// Hosted by the restricted system WKWebView shell.
    case restrictedWeb
    /// Hosted by a static in-process runtime shipped with the app.
    case dedicatedRuntime
}

public struct GameEngineCatalogEntry: Sendable, Equatable, Identifiable {
    public let descriptor: EngineDescriptor
    public let hostingKind: EngineHostingKind

    public var id: EngineID { descriptor.id }

    public var isRunnable: Bool { hostingKind != .detectionOnly }

    public init(descriptor: EngineDescriptor, hostingKind: EngineHostingKind) {
        self.descriptor = descriptor
        self.hostingKind = hostingKind
    }
}

public struct GameEngineCatalog: Sendable, Equatable {
    public private(set) var entries: [GameEngineCatalogEntry]

    /// Engines whose first-version runtime is the restricted WKWebView shell.
    public static let restrictedWebEngines: Set<EngineID> = [
        EngineID(rawValue: "rpg-maker-mv"),
        EngineID(rawValue: "rpg-maker-mz"),
        EngineID(rawValue: "tyranoscript"),
        EngineID(rawValue: "flash")
    ]

    public init(
        detectors: [any GameDetector],
        webHostedEngines: Set<EngineID> = GameEngineCatalog.restrictedWebEngines
    ) {
        entries = detectors
            .map { detector -> GameEngineCatalogEntry in
                let kind: EngineHostingKind
                if !detector.runtimeAvailable {
                    kind = .detectionOnly
                } else if webHostedEngines.contains(detector.descriptor.id) {
                    kind = .restrictedWeb
                } else {
                    kind = .dedicatedRuntime
                }
                return GameEngineCatalogEntry(
                    descriptor: detector.descriptor,
                    hostingKind: kind
                )
            }
            .sorted { $0.descriptor.id.rawValue < $1.descriptor.id.rawValue }
    }

    public func entry(for id: EngineID) -> GameEngineCatalogEntry? {
        entries.first { $0.descriptor.id == id }
    }

    public func hostingKind(for id: EngineID) -> EngineHostingKind {
        entry(for: id)?.hostingKind ?? .detectionOnly
    }

    public func canHostRuntime(for id: EngineID) -> Bool {
        hostingKind(for: id) != .detectionOnly
    }

    public var runnableEngineIDs: Set<EngineID> {
        Set(entries.filter(\.isRunnable).map(\.descriptor.id))
    }
}
