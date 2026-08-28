import XCTest
import YumeDomain
@testable import YumeEngineHost

final class EngineSessionLifecycleTests: XCTestCase {
    func testHappyPathRunsPausesResumesAndStops() async throws {
        let lifecycle = EngineSessionLifecycle()
        let gameID = GameID()
        let engineID = EngineID(rawValue: "fixture")

        try await lifecycle.beginPreparing(gameID: gameID, engineID: engineID)
        try await lifecycle.markReady()
        try await lifecycle.markRunning()
        try await lifecycle.markPaused()
        try await lifecycle.markRunning()
        try await lifecycle.beginStopping()
        try await lifecycle.finishStopping()

        let state = await lifecycle.state
        XCTAssertEqual(state, .idle)
    }

    func testInvalidTransitionDoesNotMutateState() async throws {
        let lifecycle = EngineSessionLifecycle()

        do {
            try await lifecycle.markRunning()
            XCTFail("Expected invalid transition")
        } catch let error as EngineSessionTransitionError {
            XCTAssertEqual(error, .invalidTransition(from: .idle, operation: "markRunning"))
        }

        let state = await lifecycle.state
        XCTAssertEqual(state, .idle)
    }

    func testFailurePreservesSessionIdentityUntilExplicitReset() async throws {
        let lifecycle = EngineSessionLifecycle()
        let gameID = GameID()
        let engineID = EngineID(rawValue: "fixture")

        try await lifecycle.beginPreparing(gameID: gameID, engineID: engineID)
        await lifecycle.fail(code: "runtime.crashed")

        let failed = await lifecycle.state
        XCTAssertEqual(
            failed,
            .failed(gameID: gameID, engineID: engineID, code: "runtime.crashed")
        )
        try await lifecycle.resetAfterFailure()
        let reset = await lifecycle.state
        XCTAssertEqual(reset, .idle)
    }
}

extension EngineSessionLifecycleTests: @unchecked Sendable {}
