import XCTest
import CYumeRuntimeProviderStubs
import YumeDomain
@testable import YumeEngineHost

final class NativeRuntimeSessionTests: XCTestCase, @unchecked Sendable {
    // Kept in one ordered scenario: the last failure deliberately poisons the
    // real process gate, which must not be reset just to make tests pass.
    func testProviderLifecycleFromBackgroundCallerAndUnacknowledgedStop() async throws {
        yume_test_provider_enable(1)
        let root = FileManager.default.temporaryDirectory
        let game = PreparedGame(gameID: GameID(), engineID: EngineID(rawValue: "rgss"),
            contentRootURL: root, saveRootURL: root, derivedRootURL: root, logRootURL: root)
        let context = EngineContext(sessionID: UUID())
        do {
            _ = try await NativeRuntimeSession(runtimeIdentifier: "missing", game: game, context: context)
            XCTFail("An unavailable runtime must fail without retaining the process gate")
        } catch {
            XCTAssertEqual(error as? NativeRuntimeHostError, .unavailable("missing"))
        }
        yume_test_provider_fail_create()
        do {
            _ = try await NativeRuntimeSession(runtimeIdentifier: "mkxp-z", game: game, context: context)
            XCTFail("A partially created provider must be destroyed")
        } catch {
            XCTAssertEqual(error as? NativeRuntimeHostError, .creationFailed(runtimeIdentifier: "mkxp-z", code: -99))
        }
        XCTAssertEqual(yume_test_provider_destroy_count(), 1)
        yume_test_provider_enable(1)
        let first = try await NativeRuntimeSession(runtimeIdentifier: "mkxp-z", game: game, context: context)
        do {
            _ = try await NativeRuntimeSession(runtimeIdentifier: "mkxp-z", game: game, context: context)
            XCTFail("Overlapping sessions must be rejected")
        } catch {
            XCTAssertEqual(error as? NativeRuntimeHostError, .sessionAlreadyActive)
        }
        try await Task.detached { try await first.start() }.value
        await Task.detached { await first.stop() }.value
        await first.stop()
        XCTAssertEqual(yume_test_provider_destroy_count(), 1, "stop/destroy must be idempotent")
        XCTAssertEqual(yume_test_provider_off_main_count(), 0, "UIKit ABI operations must hop to main")
        var events: [EngineEvent] = []
        for await event in first.events { events.append(event) }
        XCTAssertEqual(events, [.started, .firstFrame, .stopped])
        var logs = 0
        for await _ in first.logs { logs += 1 }
        XCTAssertEqual(logs, 512, "A noisy provider must not allocate an unbounded bootstrap log stream")

        yume_test_provider_enable(0)
        let second = try await NativeRuntimeSession(runtimeIdentifier: "mkxp-z", game: game,
            context: context, stopTimeout: 0.01)
        try await second.start()
        await second.stop()
        var timeoutSeen = false
        for await event in second.events {
            if event == .warning(code: "runtime.stop-timeout") { timeoutSeen = true }
        }
        XCTAssertTrue(timeoutSeen)
        do {
            _ = try await NativeRuntimeSession(runtimeIdentifier: "mkxp-z", game: game, context: context)
            XCTFail("A timed-out native worker must prevent another engine entering the process")
        } catch {
            XCTAssertEqual(error as? NativeRuntimeHostError, .processRequiresRestart)
        }
    }
}
