import Foundation
import XCTest
import YumeApplication
@testable import YumeInfrastructure

@MainActor
final class LocalDiagnosticStoreTests: XCTestCase {
    func testRecordRecentAndExportRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "yume-diagnostics-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalDiagnosticStore(directoryURL: directory)
        let first = DiagnosticEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            level: .information,
            subsystem: "test",
            code: "first"
        )
        let second = DiagnosticEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_001),
            level: .error,
            subsystem: "test",
            code: "second",
            metadata: ["safe": "value"]
        )

        try await store.record(first)
        try await store.record(second)
        let recent = try await store.recentEntries(limit: 10)
        let exportURL = try await store.makeExport()
        let exported = try JSONDecoder.iso8601.decode(
            [DiagnosticEntry].self,
            from: Data(contentsOf: exportURL)
        )

        XCTAssertEqual(recent, [second, first])
        XCTAssertEqual(exported, [second, first])
    }
    func testTruncatedCrashLineDoesNotHideOlderRotatedEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalDiagnosticStore(directoryURL: root)
        try await store.record(DiagnosticEntry(level: .information, subsystem: "fixture", code: "older"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("yume.jsonl"),
            to: root.appendingPathComponent("yume.1.jsonl"))
        try await store.record(DiagnosticEntry(level: .error, subsystem: "fixture", code: "before-abort"))
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("yume.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{partial".utf8))
        try handle.close()
        let entries = try await store.recentEntries(limit: 10)
        XCTAssertEqual(entries.map(\.code), ["before-abort", "older"])
        try await store.record(DiagnosticEntry(level: .information, subsystem: "fixture", code: "after-recovery"))
        let appended = try await store.recentEntries(limit: 10)
        XCTAssertEqual(appended.map(\.code), ["after-recovery", "before-abort", "older"])
        _ = try await store.makeExport()
    }

}

extension LocalDiagnosticStoreTests: @unchecked Sendable {}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
