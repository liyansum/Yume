import XCTest
import YumeDomain
@testable import YumeApplication

final class GameDetectionTests: XCTestCase {
    func testRegistrySelectsHighestConfidenceResult() throws {
        let root = try StorageRelativePath(rawValue: "original")
        let snapshot = DetectionSnapshot(
            rootRelativePath: root,
            regularFiles: ["marker-a", "marker-b"],
            directories: []
        )
        let registry = DetectorRegistry(detectors: [
            FixtureDetector(id: "lower", confidence: 60, marker: "marker-a"),
            FixtureDetector(id: "higher", confidence: 90, marker: "marker-b")
        ])

        guard case let .selected(result) = registry.decide(snapshot) else {
            return XCTFail("Expected a selected detector")
        }
        XCTAssertEqual(result.engine.id.rawValue, "higher")
    }

    func testRegistryReportsCloseScoresAsAmbiguousInStableOrder() throws {
        let root = try StorageRelativePath(rawValue: "original")
        let snapshot = DetectionSnapshot(
            rootRelativePath: root,
            regularFiles: ["a", "b"],
            directories: []
        )
        let registry = DetectorRegistry(
            detectors: [
                FixtureDetector(id: "zeta", confidence: 80, marker: "a"),
                FixtureDetector(id: "alpha", confidence: 80, marker: "b")
            ],
            ambiguityTolerance: 0
        )

        guard case let .ambiguous(results) = registry.decide(snapshot) else {
            return XCTFail("Expected ambiguity")
        }
        XCTAssertEqual(results.map(\.engine.id.rawValue), ["alpha", "zeta"])
    }

    func testSnapshotMatchingIsCaseInsensitiveAndNormalizesSeparators() throws {
        let snapshot = DetectionSnapshot(
            rootRelativePath: try StorageRelativePath(rawValue: "original"),
            regularFiles: ["WWW\\JS\\RMMZ_CORE.JS"],
            directories: ["WWW\\DATA"]
        )

        XCTAssertTrue(snapshot.containsFile("www/js/rmmz_core.js"))
        XCTAssertTrue(snapshot.containsDirectory("www/data"))
        XCTAssertTrue(snapshot.containsFile(withExtension: "JS"))
    }
}

private struct FixtureDetector: GameDetector {
    let descriptor: EngineDescriptor
    let confidence: Int
    let marker: String

    init(id: String, confidence: Int, marker: String) {
        self.descriptor = EngineDescriptor(
            id: EngineID(rawValue: id),
            displayName: id,
            compatibilityVersion: "test"
        )
        self.confidence = confidence
        self.marker = marker
    }

    func probe(_ snapshot: DetectionSnapshot) -> ProbeResult? {
        guard snapshot.containsFile(marker) else { return nil }
        let path = try! StorageRelativePath(rawValue: marker)
        return ProbeResult(
            engine: descriptor,
            rootRelativePath: snapshot.rootRelativePath,
            confidence: confidence,
            evidence: [
                DetectionEvidence(
                    relativePath: path,
                    kind: .requiredFile,
                    detailCode: "test.marker",
                    score: confidence
                )
            ],
            compatibility: CompatibilityReport(status: .runnable)
        )
    }
}
