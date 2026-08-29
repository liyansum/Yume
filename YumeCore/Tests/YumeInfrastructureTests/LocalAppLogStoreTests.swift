import Foundation
import XCTest
@testable import YumeInfrastructure

final class LocalAppLogStoreTests: XCTestCase {
    func testStartsDurableSessionAndExportsAdditionalRuntimeLog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Yume-AppLogTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAppLogStore(directoryURL: root.appendingPathComponent("AppLogs"))

        let current = try await store.startSession(metadata: ["version": "test"])
        try await store.append(
            level: .error,
            subsystem: "runtime",
            message: "native.failed",
            metadata: ["code": "SIGABRT"]
        )
        let runtimeLog = root.appendingPathComponent("krkr2.log")
        try Data("native crash tail\n".utf8).write(to: runtimeLog)

        let logs = try await store.logs()
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.id, current.id)
        XCTAssertEqual(logs.first?.isCurrent, true)
        let text = try String(contentsOf: current.url, encoding: .utf8)
        XCTAssertTrue(text.contains("session.started"))
        XCTAssertTrue(text.contains("native.failed"))
        XCTAssertTrue(text.contains("code=\"SIGABRT\""))

        let export = try await store.makeExport(additionalLogFiles: [runtimeLog])
        let exportText = try String(contentsOf: export, encoding: .utf8)
        XCTAssertTrue(exportText.contains("native.failed"))
        XCTAssertTrue(exportText.contains("native crash tail"))
    }

    func testSevenDayCleanupKeepsCurrentAndManualDeleteStartsEmpty() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Yume-AppLogCleanupTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = root.appendingPathComponent("AppLogs")
        let store = LocalAppLogStore(directoryURL: logRoot)
        _ = try await store.startSession()

        let old = logRoot.appendingPathComponent("app-old.log")
        try Data("old\n".utf8).write(to: old)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSinceNow: -10 * 24 * 60 * 60),
             .modificationDate: Date(timeIntervalSinceNow: -10 * 24 * 60 * 60)],
            ofItemAtPath: old.path
        )

        let removed = try await store.removeLogs(
            olderThan: Date(timeIntervalSinceNow: -7 * 24 * 60 * 60)
        )
        XCTAssertEqual(removed, 1)
        let remainingAfterCleanup = try await store.logs()
        XCTAssertEqual(remainingAfterCleanup.count, 1)

        try await store.removeAllLogs()
        let remainingAfterDelete = try await store.logs()
        XCTAssertTrue(remainingAfterDelete.isEmpty)
    }
}
