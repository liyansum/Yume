import Foundation
import YumeDomain

public protocol GameRuntimePackageStore: Sendable {
    func listRTPPackages() async throws -> [RTPPackage]
    func importRPGMakerRTP(
        variant: RPGMakerRTPVariant,
        from directoryURL: URL
    ) async throws -> RTPPackage
    func removeRTPPackage(id: String) async throws
    func rtpMountRoots(for game: ImportedGame) async throws -> [URL]
}
