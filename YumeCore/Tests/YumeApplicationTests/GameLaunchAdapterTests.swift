import Foundation
import XCTest
import YumeDomain
@testable import YumeApplication

final class GameLaunchAdapterTests: XCTestCase {
    func testWebEnginesPlanIntoRestrictedShell() {
        for engineID in ["rpg-maker-mv", "rpg-maker-mz", "tyranoscript"] {
            let plan = GameLaunchAdapters.plan(for: makeGame(engineID: engineID))
            XCTAssertEqual(plan.kind, .web)
            XCTAssertFalse(plan.requiresUserRTP)
        }
    }

    func testHostedRuntimesDeclareUpstreamAndRTPTNeeds() {
        let rgss = GameLaunchAdapters.plan(for: makeGame(engineID: "rgss"))
        XCTAssertEqual(rgss.kind, .hostedRuntime(runtimeIdentifier: "mkxp-z"))
        XCTAssertTrue(rgss.requiresUserRTP)

        for engineID in ["onscripter", "kirikiri", "flash"] {
            let plan = GameLaunchAdapters.plan(for: makeGame(engineID: engineID))
            guard case .hostedRuntime = plan.kind else {
                return XCTFail("Expected hosted runtime for \(engineID)")
            }
            XCTAssertFalse(plan.requiresUserRTP)
        }
    }

    func testUnknownEnginesFailClosed() {
        let plan = GameLaunchAdapters.plan(for: makeGame(engineID: "mystery"))
        XCTAssertEqual(plan.kind, .notPlanned(reasonCode: "engine.unknown"))
    }

    private func makeGame(engineID: String) -> ImportedGame {
        ImportedGame(
            title: engineID,
            engine: EngineDescriptor(
                id: EngineID(rawValue: engineID),
                displayName: engineID,
                compatibilityVersion: "test"
            ),
            compatibilityStatus: .runnable,
            importedAt: Date(timeIntervalSince1970: 0),
            installedByteCount: 1
        )
    }
}

extension GameLaunchAdapterTests: @unchecked Sendable {}
