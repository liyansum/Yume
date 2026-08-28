import Foundation
import PLzmaSDK
import XCTest
@testable import YumeInfrastructure

final class Safe7zExtractorTests: XCTestCase {
    func testInspectsAndExtractsValidatedArchive() throws {
        let fixture = try SevenZipFixture()
        defer { fixture.remove() }
        try fixture.makeArchive([
            ("game/index.html", Data("<!doctype html>".utf8)),
            ("game/data/System.json", Data("{}".utf8))
        ])

        let extractor = Safe7zExtractor()
        let inspection = try extractor.inspect(fixture.archiveURL)
        let extracted = try extractor.extract(fixture.archiveURL, to: fixture.destinationURL)

        XCTAssertEqual(inspection.entryCount, 2)
        XCTAssertEqual(inspection.fileCount, 2)
        XCTAssertEqual(inspection.uncompressedByteCount, 17)
        XCTAssertEqual(extracted, inspection)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destinationURL.appendingPathComponent("game/index.html")),
            Data("<!doctype html>".utf8)
        )
    }

    func testEncryptedHeaderRequiresPasswordAndRejectsWrongPassword() throws {
        let fixture = try SevenZipFixture()
        defer { fixture.remove() }
        try fixture.makeArchive(
            [("secret.txt", Data("private".utf8))],
            password: "correct horse",
            encryptHeader: true
        )
        let extractor = Safe7zExtractor()

        XCTAssertThrowsError(try extractor.inspect(fixture.archiveURL)) { error in
            XCTAssertEqual(error as? Safe7zError, .passwordRequired)
        }
        XCTAssertThrowsError(
            try extractor.extract(
                fixture.archiveURL,
                to: fixture.destinationURL,
                password: "wrong"
            )
        ) { error in
            XCTAssertEqual(error as? Safe7zError, .incorrectPasswordOrCorruptArchive)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationURL.path))

        let inspection = try extractor.extract(
            fixture.archiveURL,
            to: fixture.destinationURL,
            password: "correct horse"
        )
        XCTAssertTrue(inspection.containsEncryptedEntries)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destinationURL.appendingPathComponent("secret.txt")),
            Data("private".utf8)
        )
    }

    func testEntryAndExpandedSizeLimitsFailBeforeCreatingDestination() throws {
        let fixture = try SevenZipFixture()
        defer { fixture.remove() }
        try fixture.makeArchive([
            ("one", Data("1234".utf8)),
            ("two", Data("5678".utf8))
        ])

        XCTAssertThrowsError(
            try Safe7zExtractor(
                limits: .init(maximumEntryCount: 1)
            ).extract(fixture.archiveURL, to: fixture.destinationURL)
        ) { error in
            XCTAssertEqual(error as? Safe7zError, .entryLimitExceeded)
        }
        XCTAssertThrowsError(
            try Safe7zExtractor(
                limits: .init(maximumExpandedByteCount: 4)
            ).extract(fixture.archiveURL, to: fixture.destinationURL)
        ) { error in
            XCTAssertEqual(error as? Safe7zError, .expandedSizeLimitExceeded)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationURL.path))
    }
}

extension Safe7zExtractorTests: @unchecked Sendable {}

struct SevenZipFixture {
    let root: URL
    let archiveURL: URL
    let destinationURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "yume-7z-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        archiveURL = root.appendingPathComponent("fixture.7z")
        destinationURL = root.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeArchive(
        _ entries: [(String, Data)],
        password: String? = nil,
        encryptHeader: Bool = false
    ) throws {
        let output = try OutStream(path: Path(archiveURL.path))
        let encoder = try Encoder(stream: output, fileType: .sevenZ, method: .LZMA2)
        if let password {
            try encoder.setPassword(password)
            try encoder.setShouldEncryptContent(true)
            try encoder.setShouldEncryptHeader(encryptHeader)
        }
        try encoder.setShouldCreateSolidArchive(false)
        for (path, data) in entries {
            try encoder.add(
                stream: InStream(dataCopy: data),
                archivePath: Path(path)
            )
        }
        guard try encoder.open(), try encoder.compress() else {
            throw FixtureError.encodingFailed
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private enum FixtureError: Error {
        case encodingFailed
    }
}
