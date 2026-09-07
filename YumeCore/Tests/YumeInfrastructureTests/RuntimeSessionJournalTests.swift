import Foundation
import XCTest
@testable import YumeInfrastructure

final class RuntimeSessionJournalTests: XCTestCase {
    func testInterruptedSessionKeepsStageAndRecoversOnlyOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let journal = try RuntimeSessionJournal(directoryURL: root, sessionID: id, metadata: ["engine": "onscripter"])
        try journal.record("native.create-requested")
        try journal.record("native.start-requested")
        // No async consumer or orderly shutdown: emulate a process killed
        // just after entering an engine. The last stage already exists on disk.
        let recovered = try RuntimeSessionJournal.recoverInterrupted(in: root)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.sessionID, id)
        XCTAssertEqual(recovered.first?.lastEvent, "native.start-requested")
        XCTAssertNil(recovered.first?.firstFrameAt)
        XCTAssertTrue(try RuntimeSessionJournal.recoverInterrupted(in: root).isEmpty)
    }

    func testReleasedFailureAndBoundedMilestonesRemainExportable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try RuntimeSessionJournal(directoryURL: root, sessionID: UUID(), metadata: [:])
        try journal.record("native.first-frame")
        for _ in 0..<100 { try journal.record("native.paused") }
        try journal.record("native.failed", isError: true, metadata: ["code": "fixture"])
        try journal.record("native.released")
        try journal.record("native.started") // Late callbacks cannot reopen a released session.
        let report = try JSONDecoder().decode(RuntimeSessionJournal.Report.self, from: Data(contentsOf: journal.url))
        XCTAssertEqual(report.lastEvent, "native.released")
        XCTAssertEqual(report.lastError, "native.failed")
        XCTAssertNotNil(report.firstFrameAt)
        XCTAssertNotNil(report.endedAt)
        XCTAssertEqual(report.milestones.count, 80)
        XCTAssertTrue(try RuntimeSessionJournal.recoverInterrupted(in: root).isEmpty)
    }
}
