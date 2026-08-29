import XCTest
import YumeApplication
import YumeDomain
@testable import YumeInfrastructure

final class BuiltInGameDetectorsTests: XCTestCase {
    func testDetectsRPGMakerMZBrowserExport() throws {
        let snapshot = DetectionSnapshot(
            rootRelativePath: try StorageRelativePath(rawValue: "original"),
            regularFiles: [
                "index.html",
                "js/rmmz_core.js",
                "data/System.json"
            ],
            directories: ["js", "data"]
        )

        guard case let .selected(result) = BuiltInGameDetectors.registry.decide(snapshot) else {
            return XCTFail("Expected RPG Maker MZ detection")
        }
        XCTAssertEqual(result.engine.id.rawValue, "rpg-maker-mz")
        XCTAssertEqual(result.confidence, 100)
        XCTAssertEqual(result.compatibility.status, .runnable)
    }

    func testDetectsPackagedRPGMakerVXAceRelease() throws {
        let snapshot = DetectionSnapshot(
            rootRelativePath: try StorageRelativePath(rawValue: "original"),
            regularFiles: ["Game.ini", "Game.exe", "Game.rgss3a"],
            directories: []
        )

        guard case let .selected(result) = BuiltInGameDetectors.registry.decide(snapshot) else {
            return XCTFail("Expected packaged RPG Maker VX Ace detection")
        }
        XCTAssertEqual(result.engine.id.rawValue, "rgss")
        XCTAssertEqual(result.compatibility.status, .runnable)
        XCTAssertTrue(result.evidence.contains { $0.detailCode == "rgss3.archive" })
    }

    func testNativeNodePluginBlocksWebGame() throws {
        let snapshot = DetectionSnapshot(
            rootRelativePath: try StorageRelativePath(rawValue: "original"),
            regularFiles: [
                "www/index.html",
                "www/js/rpg_core.js",
                "www/native/plugin.node"
            ],
            directories: ["www", "www/js", "www/native"]
        )

        guard case let .selected(result) = BuiltInGameDetectors.registry.decide(snapshot) else {
            return XCTFail("Expected RPG Maker MV detection")
        }
        XCTAssertEqual(result.engine.id.rawValue, "rpg-maker-mv")
        XCTAssertEqual(result.compatibility.status, .unsupported)
        XCTAssertEqual(result.compatibility.issues.first?.detailCode, "compatibility.nativeComponent")
    }

    func testDetectsAllDeclaredEngineFamiliesFromCanonicalMarkers() throws {
        let fixtures: [(String, Set<String>)] = [
            ("renpy", ["game/script.rpy"]),
            ("rgss", ["data/scripts.rvdata2"]),
            ("rpg-maker-mv", ["www/js/rpg_core.js"]),
            ("rpg-maker-mz", ["www/js/rmmz_core.js"]),
            ("onscripter", ["nscript.dat"]),
            ("kirikiri", ["data.xp3"]),
            ("flash", ["movie.swf"]),
            ("tyranoscript", ["tyrano/tyrano.ks"])
        ]

        for (expectedID, files) in fixtures {
            let snapshot = DetectionSnapshot(
                rootRelativePath: try StorageRelativePath(rawValue: "original"),
                regularFiles: files,
                directories: []
            )
            guard case let .selected(result) = BuiltInGameDetectors.registry.decide(snapshot) else {
                XCTFail("Expected detection for \(expectedID)")
                continue
            }
            XCTAssertEqual(result.engine.id.rawValue, expectedID)
        }
    }

    func testEveryDeclaredEngineFamilyIsRunnableInTheBundledBuild() {
        let catalog = GameEngineCatalog(detectors: BuiltInGameDetectors.registry.detectors)
        let expected = Set([
            "renpy", "rgss", "rpg-maker-mv", "rpg-maker-mz", "onscripter",
            "kirikiri", "flash", "tyranoscript"
        ].map { EngineID(rawValue: $0) })

        XCTAssertEqual(catalog.runnableEngineIDs, expected)
    }
}
