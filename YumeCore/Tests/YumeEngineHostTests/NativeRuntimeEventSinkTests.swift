import XCTest
@testable import YumeEngineHost

final class NativeRuntimeEventSinkTests: XCTestCase {
    func testWaitForStopReturnsImmediatelyAfterStoppedEvent() async {
        let eventPair = AsyncStream<EngineEvent>.makeStream()
        let logPair = AsyncStream<NativeRuntimeLogRecord>.makeStream()
        let sink = NativeRuntimeEventSink(
            continuation: eventPair.continuation,
            logContinuation: logPair.continuation
        )

        sink.yield(.stopped)

        let stopped = await sink.waitUntilStopped(timeout: 0.01)
        XCTAssertTrue(stopped)
        sink.finish()
    }

    func testWaitForStopTimesOutWhenProviderNeverAcknowledges() async {
        let eventPair = AsyncStream<EngineEvent>.makeStream()
        let logPair = AsyncStream<NativeRuntimeLogRecord>.makeStream()
        let sink = NativeRuntimeEventSink(
            continuation: eventPair.continuation,
            logContinuation: logPair.continuation
        )

        let stopped = await sink.waitUntilStopped(timeout: 0.01)
        XCTAssertFalse(stopped)
        sink.finish()
    }
}

extension NativeRuntimeEventSinkTests: @unchecked Sendable {}
