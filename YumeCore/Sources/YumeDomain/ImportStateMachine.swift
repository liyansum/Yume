import Foundation

public enum ImportAction: Equatable, Sendable {
    case advance(to: ImportStage)
    case pause
    case resume
    case cancel
    case fail(code: String)
    case complete(gameIDs: [GameID])
}

public enum ImportTransitionError: Error, Equatable, Sendable {
    case invalidTransition(from: ImportState, action: ImportAction)
    case emptyFailureCode
    case emptyCompletion
    case duplicateGameIDs
}

public enum ImportStateMachine {
    public static func transition(
        from state: ImportState,
        action: ImportAction
    ) throws -> ImportState {
        try validate(action: action)

        switch (state, action) {
        case let (.active(current), .advance(next)) where current == next:
            return state
        case let (.active(current), .advance(next)) where allowedSuccessors(of: current).contains(next):
            return .active(stage: next)
        case let (.active(stage), .pause):
            return .paused(stage: stage)
        case (.paused(_), .pause), (.active(_), .resume):
            return state
        case let (.paused(stage), .resume):
            return .active(stage: stage)
        case let (.active(stage), .cancel) where stage != .committed:
            return .cancelled
        case let (.paused(stage), .cancel) where stage != .committed:
            return .cancelled
        case (.cancelled, .cancel):
            return state
        case let (.active(stage), .fail(code)) where stage != .committed:
            return .failed(code: code)
        case let (.paused(stage), .fail(code)) where stage != .committed:
            return .failed(code: code)
        case let (.failed(existingCode), .fail(code)) where existingCode == code:
            return state
        case let (.active(.committed), .complete(gameIDs)):
            return .completed(gameIDs: gameIDs)
        case let (.completed(existingGameIDs), .complete(gameIDs)) where existingGameIDs == gameIDs:
            return state
        default:
            throw ImportTransitionError.invalidTransition(from: state, action: action)
        }
    }

    public static func validate(action: ImportAction) throws {
        switch action {
        case let .fail(code):
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImportTransitionError.emptyFailureCode
            }
        case let .complete(gameIDs):
            guard !gameIDs.isEmpty else {
                throw ImportTransitionError.emptyCompletion
            }
            guard Set(gameIDs).count == gameIDs.count else {
                throw ImportTransitionError.duplicateGameIDs
            }
        default:
            break
        }
    }

    private static func allowedSuccessors(of stage: ImportStage) -> [ImportStage] {
        switch stage {
        case .picked:
            [.validatingSource]
        case .validatingSource:
            [.budgeting]
        case .budgeting:
            [.copyingToStaging, .extractingToStaging]
        case .copyingToStaging, .extractingToStaging:
            [.detectingRoots]
        case .detectingRoots:
            [.resolvingAmbiguity, .scanningCompatibility]
        case .resolvingAmbiguity:
            [.scanningCompatibility]
        case .scanningCompatibility:
            [.awaitingConversionConsent, .convertingDerivedData, .validatingCommit]
        case .awaitingConversionConsent:
            [.convertingDerivedData]
        case .convertingDerivedData:
            [.validatingCommit]
        case .validatingCommit:
            [.committed]
        case .committed:
            []
        }
    }
}
