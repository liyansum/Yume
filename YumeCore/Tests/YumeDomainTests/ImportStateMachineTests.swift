import Foundation
import XCTest
@testable import YumeDomain

final class ImportStateMachineTests: XCTestCase {
    func testDirectCopyWithoutConversionFollowsAllowedPath() throws {
        var state = ImportState.active(stage: .picked)
        let stages: [ImportStage] = [
            .validatingSource,
            .budgeting,
            .copyingToStaging,
            .detectingRoots,
            .scanningCompatibility,
            .validatingCommit,
            .committed
        ]

        for stage in stages {
            state = try ImportStateMachine.transition(from: state, action: .advance(to: stage))
        }

        let gameID = GameID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        state = try ImportStateMachine.transition(from: state, action: .complete(gameIDs: [gameID]))
        XCTAssertEqual(state, .completed(gameIDs: [gameID]))
    }

    func testExtractionAmbiguityAndConversionBranchIsAllowed() throws {
        let stages: [ImportStage] = [
            .validatingSource,
            .budgeting,
            .extractingToStaging,
            .detectingRoots,
            .resolvingAmbiguity,
            .scanningCompatibility,
            .awaitingConversionConsent,
            .convertingDerivedData,
            .validatingCommit,
            .committed
        ]
        var state = ImportState.active(stage: .picked)

        for stage in stages {
            state = try ImportStateMachine.transition(from: state, action: .advance(to: stage))
        }

        XCTAssertEqual(state, .active(stage: .committed))
    }

    func testSkippingRequiredStageIsRejected() {
        XCTAssertThrowsError(
            try ImportStateMachine.transition(
                from: .active(stage: .picked),
                action: .advance(to: .copyingToStaging)
            )
        )
    }

    func testPauseResumeAndRepeatedRequestsAreIdempotent() throws {
        let active = ImportState.active(stage: .extractingToStaging)
        let paused = try ImportStateMachine.transition(from: active, action: .pause)

        XCTAssertEqual(paused, .paused(stage: .extractingToStaging))
        XCTAssertEqual(try ImportStateMachine.transition(from: paused, action: .pause), paused)
        XCTAssertEqual(try ImportStateMachine.transition(from: paused, action: .resume), active)
        XCTAssertEqual(try ImportStateMachine.transition(from: active, action: .resume), active)
        XCTAssertEqual(
            try ImportStateMachine.transition(
                from: active,
                action: .advance(to: .extractingToStaging)
            ),
            active
        )
    }

    func testTerminalStatesRejectDifferentMutations() throws {
        let cancelled = try ImportStateMachine.transition(
            from: .active(stage: .budgeting),
            action: .cancel
        )

        XCTAssertEqual(try ImportStateMachine.transition(from: cancelled, action: .cancel), cancelled)
        XCTAssertThrowsError(
            try ImportStateMachine.transition(from: cancelled, action: .resume)
        )
        XCTAssertThrowsError(
            try ImportStateMachine.transition(
                from: .active(stage: .committed),
                action: .cancel
            )
        )
        XCTAssertThrowsError(
            try ImportStateMachine.transition(
                from: .paused(stage: .committed),
                action: .fail(code: "postcommit.failure")
            )
        )
    }

    func testFailureAndCompletionPayloadsAreValidated() {
        let duplicateID = GameID(rawValue: UUID())

        XCTAssertThrowsError(try ImportStateMachine.validate(action: .fail(code: "  ")))
        XCTAssertThrowsError(try ImportStateMachine.validate(action: .complete(gameIDs: [])))
        XCTAssertThrowsError(
            try ImportStateMachine.validate(
                action: .complete(gameIDs: [duplicateID, duplicateID])
            )
        )
    }
}
