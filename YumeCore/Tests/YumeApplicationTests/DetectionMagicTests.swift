import Foundation
import XCTest
import YumeDomain
@testable import YumeApplication

final class DetectionMagicTests: XCTestCase {
    func testMatchingHeadsProduceNoIssues() async {
        let probe = makeProbe(files: [
            "original/data.xp3",
            "original/movie.swf",
            "original/Game.rgssad",
            "original/archive.rpa"
        ])

        let issues = await DetectionMagic.verify(probe) { path, _ in
            Data(headText(for: path.rawValue).utf8)
        }
        XCTAssertTrue(issues.isEmpty)
    }

    func testMismatchedAndUnreadableFilesAreBlocked() async {
        let probe = makeProbe(files: [
            "original/fake.xp3",
            "original/missing.swf"
        ])

        let issues = await DetectionMagic.verify(probe) { path, _ in
            let text = headText(for: path.rawValue)
            return text.isEmpty ? nil : Data(text.utf8)
        }

        XCTAssertEqual(issues.count, 2)
        XCTAssertEqual(Set(issues.map(\.detailCode)), ["detection.magicMismatch", "detection.magicUnreadable"])
        XCTAssertTrue(issues.allSatisfy { $0.severity == .blocking })
    }

    func testHardenedProbeDowngradesStatusAndKeepsEvidence() {
        let base = makeProbe(files: ["original/data.xp3"])
        let issue = CompatibilityIssue(
            id: "magic-mismatch:original/data.xp3",
            severity: .blocking,
            detailCode: "detection.magicMismatch"
        )
        let hardened = DetectionMagic.hardened(base, issues: [issue])

        XCTAssertEqual(hardened.compatibility.status, .unsupported)
        XCTAssertEqual(hardened.compatibility.issues, [issue])
        XCTAssertEqual(hardened.evidence.count, base.evidence.count)
        XCTAssertEqual(hardened.confidence, base.confidence)
    }

    func testUnruledExtensionsAreIgnored() async {
        let probe = makeProbe(files: ["original/js/rmmz_core.js"])
        let issues = await DetectionMagic.verify(probe) { _, _ in Data("whatever".utf8) }
        XCTAssertTrue(issues.isEmpty)
    }

    private func headText(for path: String) -> String {
        switch path {
        case "original/data.xp3": "XP3\r\n \n\u{001A}"
        case "original/movie.swf": "CWS\u{0005}"
        case "original/Game.rgssad": "RGSSAD\0\u{01}"
        case "original/archive.rpa": "RPA-3.2 1a2b"
        case "original/fake.xp3": "MZ not an archive"
        case "original/missing.swf": ""
        default: "ok"
        }
    }

    private func makeProbe(files: [String]) -> ProbeResult {
        ProbeResult(
            engine: EngineDescriptor(
                id: EngineID(rawValue: "kirikiri"),
                displayName: "Kirikiri",
                compatibilityVersion: "test"
            ),
            rootRelativePath: try! StorageRelativePath(rawValue: "original"),
            confidence: 80,
            evidence: files.map { relativePath in
                DetectionEvidence(
                    relativePath: (try! StorageRelativePath(rawValue: relativePath)),
                    kind: .requiredFile,
                    detailCode: "test.marker",
                    score: 75
                )
            },
            compatibility: CompatibilityReport(status: .runnable)
        )
    }
}

extension DetectionMagicTests: @unchecked Sendable {}
