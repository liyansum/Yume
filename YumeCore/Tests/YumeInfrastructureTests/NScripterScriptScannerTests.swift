import Foundation
import XCTest
@testable import YumeInfrastructure

final class NScripterScriptScannerTests: XCTestCase {
    func testUTF8SampleCountsLinesCommentsLabelsAndCommands() throws {
        let fixture = try ScriptFixture()
        defer { fixture.remove() }
        let text = """
        ; top comment
        *start

        bg white,1
          bg black,1
          ; indented comment
        wait 500
        123
        click "menu"
        end
        """
        try Data(text.utf8).write(to: fixture.scriptURL)
        let scanner = NScripterScriptScanner()

        let report = try scanner.scan(fileAt: fixture.scriptURL)

        XCTAssertEqual(report.lineCount, 10)
        XCTAssertEqual(report.commandCounts["bg"], 2)
        XCTAssertEqual(report.commandCounts["wait"], 1)
        XCTAssertEqual(report.commandCounts["click"], 1)
        XCTAssertEqual(report.commandCounts["end"], 1)
        XCTAssertEqual(report.commandCounts.count, 4)
        XCTAssertFalse(report.containsNonASCII)
        XCTAssertEqual(report.sampleCommands, ["bg", "wait", "click", "end"])
    }

    func testNonASCIILinesCountWithoutCommandTokens() throws {
        let fixture = try ScriptFixture()
        defer { fixture.remove() }
        try Data("bg red\n表示する\n*セーブ\n".utf8).write(to: fixture.scriptURL)

        let report = try NScripterScriptScanner().scan(fileAt: fixture.scriptURL)

        XCTAssertEqual(report.lineCount, 3)
        XCTAssertEqual(report.commandCounts, ["bg": 1])
        XCTAssertTrue(report.containsNonASCII)
        XCTAssertEqual(report.sampleCommands, ["bg"])
    }

    func testNonUTF8BytesReportUndecodableText() throws {
        let fixture = try ScriptFixture()
        defer { fixture.remove() }
        var data = Data("bg white\n".utf8)
        data.append(contentsOf: [0x81, 0x40])
        try data.write(to: fixture.scriptURL)

        XCTAssertThrowsError(
            try NScripterScriptScanner().scan(fileAt: fixture.scriptURL)
        ) { error in
            XCTAssertEqual(error as? ScriptScanError, .undecodableText)
        }
    }

    func testNULByteReportsBinaryContent() throws {
        let fixture = try ScriptFixture()
        defer { fixture.remove() }
        try Data("a\u{0}b".utf8).write(to: fixture.scriptURL)

        XCTAssertThrowsError(
            try NScripterScriptScanner().scan(fileAt: fixture.scriptURL)
        ) { error in
            XCTAssertEqual(error as? ScriptScanError, .binaryContent)
        }
    }

    func testOversizeFileFailsClosed() throws {
        let fixture = try ScriptFixture()
        defer { fixture.remove() }
        try Data("abcdefghij".utf8).write(to: fixture.scriptURL)
        let scanner = NScripterScriptScanner(
            limits: NScripterScanLimits(maximumFileByteCount: 4, maximumCommandSampleCount: 16)
        )

        XCTAssertThrowsError(
            try scanner.scan(fileAt: fixture.scriptURL)
        ) { error in
            XCTAssertEqual(error as? ScriptScanError, .readFailed)
        }
    }

    func testSampleCommandsRespectLimitWhileCountsStayComplete() throws {
        let fixture = try ScriptFixture()
        defer { fixture.remove() }
        try Data("aa 1\nbb 1\ncc 1\naa 1\n".utf8).write(to: fixture.scriptURL)
        let scanner = NScripterScriptScanner(
            limits: NScripterScanLimits(maximumFileByteCount: 1024, maximumCommandSampleCount: 2)
        )

        let report = try scanner.scan(fileAt: fixture.scriptURL)

        XCTAssertEqual(report.lineCount, 4)
        XCTAssertEqual(report.commandCounts, ["aa": 2, "bb": 1, "cc": 1])
        XCTAssertEqual(report.sampleCommands, ["aa", "bb"])
    }

    func testMissingSourceReportsSourceMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("yume-missing-\(UUID().uuidString).txt")

        XCTAssertThrowsError(
            try NScripterScriptScanner().scan(fileAt: missing)
        ) { error in
            XCTAssertEqual(error as? ScriptScanError, .sourceMissing)
        }
    }
}

private struct ScriptFixture {
    let root: URL
    let scriptURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "yume-script-scan-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        scriptURL = root.appendingPathComponent("script.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
