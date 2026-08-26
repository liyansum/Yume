import Foundation
import YumeDomain

public enum LaunchKind: Equatable, Sendable {
    /// Runs in the restricted WKWebView shell.
    case web
    /// Requires a statically linked upstream runtime (ADR-0053).
    case hostedRuntime(runtimeIdentifier: String)
    /// No runtime path exists for this engine yet.
    case notPlanned(reasonCode: String)
}

public struct LaunchPlan: Sendable, Equatable {
    public let engineID: EngineID
    public let kind: LaunchKind
    public let requiresUserRTP: Bool
    public let runtimeVersionLabel: String

    public init(
        engineID: EngineID,
        kind: LaunchKind,
        requiresUserRTP: Bool = false,
        runtimeVersionLabel: String
    ) {
        self.engineID = engineID
        self.kind = kind
        self.requiresUserRTP = requiresUserRTP
        self.runtimeVersionLabel = runtimeVersionLabel
    }
}

public protocol GameLaunchAdapter: Sendable {
    var engineID: EngineID { get }
    func plan(for game: ImportedGame) -> LaunchPlan
}

public enum GameLaunchAdapters {
    public static func all() -> [any GameLaunchAdapter] {
        [
            SimpleLaunchAdapter(
                engineID: "rpg-maker-mv",
                kind: .web,
                runtimeVersionLabel: "WKWebView"
            ),
            SimpleLaunchAdapter(
                engineID: "rpg-maker-mz",
                kind: .web,
                runtimeVersionLabel: "WKWebView"
            ),
            SimpleLaunchAdapter(
                engineID: "tyranoscript",
                kind: .web,
                runtimeVersionLabel: "WKWebView"
            ),
            SimpleLaunchAdapter(
                engineID: "rgss",
                kind: .hostedRuntime(runtimeIdentifier: "mkxp-z"),
                requiresUserRTP: true,
                runtimeVersionLabel: "mkxp-z"
            ),
            SimpleLaunchAdapter(
                engineID: "onscripter",
                kind: .hostedRuntime(runtimeIdentifier: "onscripter"),
                runtimeVersionLabel: "ONScripter"
            ),
            SimpleLaunchAdapter(
                engineID: "kirikiri",
                kind: .hostedRuntime(runtimeIdentifier: "krkrsdl2"),
                runtimeVersionLabel: "krkrsdl2"
            ),
            SimpleLaunchAdapter(
                engineID: "flash",
                kind: .hostedRuntime(runtimeIdentifier: "ruffle"),
                runtimeVersionLabel: "Ruffle"
            ),
            SimpleLaunchAdapter(
                engineID: "renpy",
                kind: .notPlanned(reasonCode: "runtime.renpy.evaluation"),
                runtimeVersionLabel: "Ren'Py"
            )
        ]
    }

    public static func plan(for game: ImportedGame) -> LaunchPlan {
        let registry = Dictionary(uniqueKeysWithValues: all().map { ($0.engineID, $0) })
        guard let adapter = registry[game.engine.id] else {
            return LaunchPlan(
                engineID: game.engine.id,
                kind: .notPlanned(reasonCode: "engine.unknown"),
                runtimeVersionLabel: game.engine.displayName
            )
        }
        return adapter.plan(for: game)
    }
}

public struct SimpleLaunchAdapter: GameLaunchAdapter {
    public let engineID: EngineID
    private let kind: LaunchKind
    private let requiresUserRTP: Bool
    private let runtimeVersionLabel: String

    public init(
        engineID: String,
        kind: LaunchKind,
        requiresUserRTP: Bool = false,
        runtimeVersionLabel: String
    ) {
        self.engineID = EngineID(rawValue: engineID)
        self.kind = kind
        self.requiresUserRTP = requiresUserRTP
        self.runtimeVersionLabel = runtimeVersionLabel
    }

    public func plan(for game: ImportedGame) -> LaunchPlan {
        LaunchPlan(
            engineID: engineID,
            kind: kind,
            requiresUserRTP: requiresUserRTP,
            runtimeVersionLabel: runtimeVersionLabel
        )
    }
}
