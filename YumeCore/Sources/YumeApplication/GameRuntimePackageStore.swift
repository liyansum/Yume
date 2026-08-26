import Foundation
import YumeDomain

public protocol GameRuntimePackageStore: Sendable {
    func listRTPPackages() async throws -> [RTPPackage]
    func importRTPPackage(
        named name: String,
        engine: EngineID,
        from directoryURL: URL
    ) async throws -> RTPPackage
    func removeRTPPackage(id: String) async throws
    func rtpMountRoots(for game: ImportedGame) async throws -> [URL]
}
