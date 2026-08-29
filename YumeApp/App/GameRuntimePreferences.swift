import Darwin
import Foundation
import YumeDomain

enum RenPyRuntimeBand: String, CaseIterable, Identifiable {
    case automatic
    case legacy7 = "7"
    case modern8 = "8"

    var id: String { rawValue }

    var environmentValue: String? {
        switch self {
        case .automatic: nil
        case .legacy7: "legacy"
        case .modern8: "modern"
        }
    }
}

enum GameRuntimePreferences {
    private static let defaults = UserDefaults.standard

    static func renpyBand(for gameID: GameID) -> RenPyRuntimeBand {
        let key = storageKey(for: gameID)
        guard let raw = defaults.string(forKey: key),
              let band = RenPyRuntimeBand(rawValue: raw)
        else {
            return .automatic
        }
        return band
    }

    static func setRenpyBand(_ band: RenPyRuntimeBand, for gameID: GameID) {
        let key = storageKey(for: gameID)
        if band == .automatic {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(band.rawValue, forKey: key)
        }
    }

    static func applyLaunchEnvironment(for game: ImportedGame) {
        unsetenv("YUME_RENPY_GENERATION")
        guard game.engine.id.rawValue == "renpy" else { return }
        if let value = renpyBand(for: game.id).environmentValue {
            setenv("YUME_RENPY_GENERATION", value, 1)
        }
    }

    private static func storageKey(for gameID: GameID) -> String {
        "yume.game.\(gameID.rawValue.uuidString).renpyRuntimeBand"
    }
}
