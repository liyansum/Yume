import Foundation
import XCTest
import YumeApplication
import YumeDomain
@testable import YumeInfrastructure

@MainActor
final class RuntimeProbeImportTests: XCTestCase, @unchecked Sendable {
    func testGeneratedDeviceProbesImportAndResolveTheirEntries() async throws {
        guard let path = ProcessInfo.processInfo.environment["YUME_TEST_PROBES_ROOT"] else {
            throw XCTSkip("Run Scripts/verify_pretest.sh to generate the device probe projects")
        }
        let probes = URL(fileURLWithPath: path, isDirectory: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = LocalGameStorage(baseURL: temporary) { _ in
            LocalGameStorage.VolumeCapacity(availableByteCount: 100 * 1_073_741_824,
                                            totalByteCount: 100 * 1_073_741_824)
        }
        let service = DirectoryGameImportService(storage: storage, detectors: BuiltInGameDetectors.registry)
        let expected = ["rgss1": "rgss", "rgss2": "rgss", "rgss3": "rgss",
                        "renpy7": "renpy", "renpy8": "renpy", "onscripter": "onscripter",
                        "kirikiri": "kirikiri", "artemis": "artemis", "flash-avm1": "flash",
                        "web-host": "tyranoscript"]
        for (project, engine) in expected.sorted(by: { $0.key < $1.key }) {
            let imported = try await service.importZIP(at: probes.appendingPathComponent(project + ".zip"))
            XCTAssertEqual(imported.engine.id.rawValue, engine, project)
            XCTAssertEqual(imported.compatibilityStatus, .runnable, project)
            let location = try await storage.contentLocation(for: imported.id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: location.rootURL.path), project)
            if project == "flash-avm1" {
                let entry = try XCTUnwrap(location.runtimeEntryPoint)
                let swf = try SWFFileParser().inspect(at: location.rootURL.appendingPathComponent(entry.rawValue))
                XCTAssertEqual(swf.frameCount, 2)
                XCTAssertEqual(swf.frameRateRaw, 256)
            }
            if project == "web-host" { XCTAssertEqual(location.webEntryPoint?.rawValue, "index.html") }
        }
        let games = try await storage.allGames()
        XCTAssertEqual(games.count, expected.count)
    }
}
