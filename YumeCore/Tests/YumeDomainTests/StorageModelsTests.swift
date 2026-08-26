import Foundation
import XCTest
@testable import YumeDomain

final class StorageModelsTests: XCTestCase {
    func testRelativePathAcceptsNestedPortablePath() throws {
        let path = try StorageRelativePath(rawValue: "audio/bgm/theme.ogg")

        XCTAssertEqual(path.rawValue, "audio/bgm/theme.ogg")
    }

    func testRelativePathRejectsTraversalAndAbsoluteForms() {
        let rejected = [
            "",
            "/private/data",
            "C:/game/data",
            "../outside",
            "assets/../outside",
            "assets//image.png",
            "./script.txt",
            "assets\\image.png",
            "name\0tail"
        ]

        for value in rejected {
            XCTAssertThrowsError(try StorageRelativePath(rawValue: value), value)
        }
    }

    func testManifestDeduplicatesOwnedPaths() throws {
        let path = try StorageRelativePath(rawValue: "data/game.json")
        let createdAt = Date(timeIntervalSince1970: 100)
        var manifest = StagingManifest(taskID: ImportTaskID(), createdAt: createdAt)

        manifest.registerOwnedPath(path, at: Date(timeIntervalSince1970: 200))
        manifest.registerOwnedPath(path, at: Date(timeIntervalSince1970: 300))

        XCTAssertEqual(manifest.ownedPaths, [path])
        XCTAssertEqual(manifest.updatedAt, Date(timeIntervalSince1970: 200))
    }

    func testInvalidPathCannotBeDecoded() {
        let data = Data("\"../outside\"".utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(StorageRelativePath.self, from: data))
    }

    func testInvalidTerminalStateCannotBeDecodedFromManifest() throws {
        let invalidManifest = StagingManifest(
            taskID: ImportTaskID(),
            state: .failed(code: "  "),
            createdAt: .distantPast
        )
        let data = try JSONEncoder().encode(invalidManifest)

        XCTAssertThrowsError(try JSONDecoder().decode(StagingManifest.self, from: data))
    }
}
