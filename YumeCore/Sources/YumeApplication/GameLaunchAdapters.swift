import Foundation
import YumeDomain

public enum LaunchKind: Equatable, Sendable {
    /// Runs in the restricted WKWebView shell.
    case web
    /// Runs a bundled, engine-specific WebAssembly/JavaScript runtime in the
    /// same offline WKWebView policy as web-native games.
    case embeddedWebRuntime(runtimeIdentifier: String)
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
                runtimeVersionLabel: "mkxp-z RGSS1/XP · RGSS2/VX · RGSS3/VX Ace"
            ),
            SimpleLaunchAdapter(
                engineID: "onscripter",
                kind: .hostedRuntime(runtimeIdentifier: "aetherkiri-onscripter"),
                runtimeVersionLabel: "AetherKiri / OnscripterYuri"
            ),
            SimpleLaunchAdapter(
                engineID: "kirikiri",
                kind: .hostedRuntime(runtimeIdentifier: "aetherkiri-kirikiri"),
                runtimeVersionLabel: "AetherKiri 0.5"
            ),
            SimpleLaunchAdapter(
                engineID: "flash",
                kind: .embeddedWebRuntime(runtimeIdentifier: "ruffle-web"),
                runtimeVersionLabel: "Ruffle Web"
            ),
            SimpleLaunchAdapter(
                engineID: "renpy",
                kind: .hostedRuntime(runtimeIdentifier: "renios"),
                runtimeVersionLabel: "Ren'Py iOS"
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
