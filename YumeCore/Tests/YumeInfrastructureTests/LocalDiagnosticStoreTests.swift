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
}

extension LocalDiagnosticStoreTests: @unchecked Sendable {}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
