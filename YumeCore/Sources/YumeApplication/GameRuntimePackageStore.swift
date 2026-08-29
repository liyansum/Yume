import Foundation
import YumeDomain

public protocol GameRuntimePackageStore: Sendable {
    func listRTPPackages() async throws -> [RTPPackage]
    /// Imports one ZIP and infers XP, VX or VX Ace from its filename and
    /// wrapper layout. The source archive is never modified.
    func importRPGMakerRTP(
        from archiveURL: URL,
        variantHint: RPGMakerRTPVariant?
    ) async throws -> [RTPPackage]
    func importRPGMakerRTP(
        variant: RPGMakerRTPVariant,
        from directoryURL: URL
    ) async throws -> RTPPackage
    func removeRTPPackage(id: String) async throws
    func rtpMountRoots(for game: ImportedGame) async throws -> [URL]
}
