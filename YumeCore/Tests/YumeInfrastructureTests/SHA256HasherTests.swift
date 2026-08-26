import Foundation
import XCTest
@testable import YumeInfrastructure

final class SHA256HasherTests: XCTestCase {
    func testKnownVectorsAndIncrementalUpdates() {
        XCTAssertEqual(digest(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(digest("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        var hasher = SHA256Hasher()
        hasher.update(Data("a".utf8))
        hasher.update(Data("b".utf8))
        hasher.update(Data("c".utf8))
        XCTAssertEqual(hex(hasher.finalize()), digest("abc"))
    }

    private func digest(_ value: String) -> String {
        var hasher = SHA256Hasher()
        hasher.update(Data(value.utf8))
        return hex(hasher.finalize())
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
