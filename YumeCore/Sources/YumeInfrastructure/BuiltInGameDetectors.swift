import Foundation
import YumeApplication
import YumeDomain

public enum BuiltInGameDetectors {
    public static var registry: DetectorRegistry {
        DetectorRegistry(detectors: [
            SignatureGameDetector.renPy,
            SignatureGameDetector.rgss,
            SignatureGameDetector.rpgMakerMZ,
            SignatureGameDetector.rpgMakerMV,
            SignatureGameDetector.onscripter,
            SignatureGameDetector.artemis,
            SignatureGameDetector.kirikiri,
            SignatureGameDetector.flash,
            SignatureGameDetector.tyranoScript
        ])
    }
}

public struct SignatureGameDetector: GameDetector, Sendable {
    public struct Rule: Sendable {
        public enum Match: Sendable {
            case file(String)
            case directory(String)
            case fileExtension(String)
        }

        public let match: Match
        public let kind: DetectionEvidenceKind
        public let detailCode: String
        public let score: Int

        public init(
            _ match: Match,
            kind: DetectionEvidenceKind,
            detailCode: String,
            score: Int
        ) {
            self.match = match
            self.kind = kind
            self.detailCode = detailCode
            self.score = score
        }
    }

    public let descriptor: EngineDescriptor
    public let requiredAll: [Rule]
    public let requiredAny: [Rule]
    public let supporting: [Rule]
    public let blockingExtensions: Set<String>
    public let warningExtensions: Set<String>
    public let runtimeAvailable: Bool

    public init(
        descriptor: EngineDescriptor,
        requiredAll: [Rule] = [],
        requiredAny: [Rule],
        supporting: [Rule],
        blockingExtensions: Set<String> = [],
        warningExtensions: Set<String> = [],
        runtimeAvailable: Bool = false
    ) {
        self.descriptor = descriptor
        self.requiredAll = requiredAll
        self.requiredAny = requiredAny
        self.supporting = supporting
        self.blockingExtensions = blockingExtensions
        self.warningExtensions = warningExtensions
        self.runtimeAvailable = runtimeAvailable
    }

    public func probe(_ snapshot: DetectionSnapshot) -> ProbeResult? {
        let allEvidence: [DetectionEvidence] = requiredAll.compactMap {
            makeEvidence(for: $0, in: snapshot)
        }
        guard allEvidence.count == requiredAll.count else { return nil }
        let requiredEvidence: [DetectionEvidence] = requiredAny.compactMap {
            makeEvidence(for: $0, in: snapshot)
        }
        guard !requiredEvidence.isEmpty else { return nil }

        let supportingEvidence: [DetectionEvidence] = supporting.compactMap {
            makeEvidence(for: $0, in: snapshot)
        }
        var collectedEvidence = allEvidence + requiredEvidence + supportingEvidence
        var issues: [CompatibilityIssue] = []

        if !runtimeAvailable {
            issues.append(
                CompatibilityIssue(
                    id: "runtime-unavailable:\(descriptor.id.rawValue)",
                    severity: .blocking,
                    detailCode: "compatibility.runtimeUnavailable"
                )
            )
        }

        for extensionName in blockingExtensions.sorted() {
            for path in snapshot.files(withExtension: extensionName) {
                guard let relativePath = try? StorageRelativePath(rawValue: path) else { continue }
                collectedEvidence.append(
                    DetectionEvidence(
                        relativePath: relativePath,
                        kind: .unsupportedNativeComponent,
                        detailCode: "native-component.\(extensionName)",
                        score: 0
                    )
                )
                issues.append(
                    CompatibilityIssue(
                        id: "native-component:\(path)",
                        severity: .blocking,
                        detailCode: "compatibility.nativeComponent",
                        relativePath: relativePath
                    )
                )
            }
        }

        for extensionName in warningExtensions.sorted() {
            for path in snapshot.files(withExtension: extensionName) {
                guard let relativePath = try? StorageRelativePath(rawValue: path) else { continue }
                collectedEvidence.append(
                    DetectionEvidence(
                        relativePath: relativePath,
                        kind: .unsupportedNativeComponent,
                        detailCode: "native-component.\(extensionName)",
                        score: 0
                    )
                )
                issues.append(
                    CompatibilityIssue(
                        id: "native-component:\(path)",
                        severity: .warning,
                        detailCode: "compatibility.nativeComponent",
                        relativePath: relativePath
                    )
                )
            }
        }

        let score = min(100, collectedEvidence.reduce(0) { $0 + max(0, $1.score) })
        let status: CompatibilityStatus
        if issues.contains(where: { $0.severity == .blocking }) {
            status = .unsupported
        } else if !issues.isEmpty {
            status = .partiallyCompatible
        } else {
            status = .runnable
        }
        return ProbeResult(
            engine: descriptor,
            rootRelativePath: snapshot.rootRelativePath,
            confidence: score,
            evidence: collectedEvidence.sorted { $0.relativePath.rawValue < $1.relativePath.rawValue },
            compatibility: CompatibilityReport(status: status, issues: issues)
        )
    }

    private func makeEvidence(for rule: Rule, in snapshot: DetectionSnapshot) -> DetectionEvidence? {
        let matchedPath: String?
        switch rule.match {
        case let .file(path):
            matchedPath = snapshot.matchingFile(path)
        case let .directory(path):
            matchedPath = snapshot.matchingDirectory(path)
        case let .fileExtension(extensionName):
            matchedPath = snapshot.files(withExtension: extensionName).first
        }

        guard let matchedPath, let relativePath = try? StorageRelativePath(rawValue: matchedPath) else {
            return nil
        }
        return DetectionEvidence(
            relativePath: relativePath,
            kind: rule.kind,
            detailCode: rule.detailCode,
            score: rule.score
        )
    }
}

public extension SignatureGameDetector {
    static let renPy = SignatureGameDetector(
        descriptor: EngineDescriptor(
            id: EngineID(rawValue: "renpy"),
            displayName: "Ren'Py",
            compatibilityVersion: "7.x–8.x"
        ),
        requiredAny: [
            Rule(.file("game/script.rpy"), kind: .requiredFile, detailCode: "renpy.script", score: 65),
            Rule(.file("game/script.rpyc"), kind: .requiredFile, detailCode: "renpy.compiledScript", score: 60),
            Rule(.fileExtension("rpa"), kind: .requiredFile, detailCode: "renpy.archive", score: 55),
            Rule(.fileExtension("rpy"), kind: .requiredFile, detailCode: "renpy.scriptFile", score: 50),
            Rule(.fileExtension("rpyc"), kind: .requiredFile, detailCode: "renpy.compiledFile", score: 45)
        ],
        supporting: [
            Rule(.file("renpy/common/00start.rpy"), kind: .characteristicFile, detailCode: "renpy.runtime", score: 30),
            Rule(.directory("game"), kind: .characteristicDirectory, detailCode: "renpy.gameDirectory", score: 10)
        ],
        runtimeAvailable: true
    )

    static let rgss = SignatureGameDetector(
        descriptor: EngineDescriptor(
            id: EngineID(rawValue: "rgss"),
            displayName: "RPG Maker XP / VX / VX Ace",
            compatibilityVersion: "RGSS1–3"
        ),
        requiredAny: [
            Rule(.file("data/scripts.rxdata"), kind: .requiredFile, detailCode: "rgss1.scripts", score: 80),
            Rule(.file("data/scripts.rvdata"), kind: .requiredFile, detailCode: "rgss2.scripts", score: 80),
            Rule(.file("data/scripts.rvdata2"), kind: .requiredFile, detailCode: "rgss3.scripts", score: 80),
            Rule(.fileExtension("rgssad"), kind: .requiredFile, detailCode: "rgss1.archive", score: 80),
            Rule(.fileExtension("rgss2a"), kind: .requiredFile, detailCode: "rgss2.archive", score: 80),
            Rule(.fileExtension("rgss3a"), kind: .requiredFile, detailCode: "rgss3.archive", score: 80)
        ],
        supporting: [
            Rule(.fileExtension("ini"), kind: .metadata, detailCode: "rgss.ini", score: 15),
            Rule(.directory("graphics"), kind: .characteristicDirectory, detailCode: "rgss.graphics", score: 5)
        ],
        runtimeAvailable: true
    )

    static let rpgMakerMV = webRPGMaker(
        id: "rpg-maker-mv",
        name: "RPG Maker MV",
        markers: ["www/js/rpg_core.js", "js/rpg_core.js"],
        version: "MV"
    )

    static let rpgMakerMZ = webRPGMaker(
        id: "rpg-maker-mz",
        name: "RPG Maker MZ",
        markers: ["www/js/rmmz_core.js", "js/rmmz_core.js"],
        version: "MZ"
    )

    static let onscripter = SignatureGameDetector(
        descriptor: EngineDescriptor(
            id: EngineID(rawValue: "onscripter"),
            displayName: "ONScripter / NScripter",
            compatibilityVersion: "validated script band"
        ),
        requiredAny: [
            Rule(.file("0.txt"), kind: .requiredFile, detailCode: "ons.script.text", score: 75),
            Rule(.file("00.txt"), kind: .requiredFile, detailCode: "ons.script.text00", score: 75),
            Rule(.file("nscr_sec.dat"), kind: .requiredFile, detailCode: "ons.script.sec", score: 75),
            Rule(.file("nscript.___"), kind: .requiredFile, detailCode: "ons.script.keyed", score: 75),
            Rule(.file("nscript.dat"), kind: .requiredFile, detailCode: "ons.script.dat", score: 75),
            Rule(.file("onscript.nt2"), kind: .requiredFile, detailCode: "ons.script.nt2", score: 75),
            Rule(.file("onscript.nt3"), kind: .requiredFile, detailCode: "ons.script.nt3", score: 75)
        ],
        supporting: [
            Rule(.fileExtension("nsa"), kind: .characteristicFile, detailCode: "ons.archive.nsa", score: 20),
            Rule(.fileExtension("sar"), kind: .characteristicFile, detailCode: "ons.archive.sar", score: 20)
        ],
        runtimeAvailable: true
    )

    /// Artemis projects use a generic `system.ini`, so it is deliberately an
    /// all-of marker combined with an engine-specific PFS/script file. This
    /// avoids classifying unrelated Windows games from `system.ini` alone.
    static let artemis = SignatureGameDetector(
        descriptor: EngineDescriptor(
            id: EngineID(rawValue: "artemis"),
            displayName: "Artemis",
            compatibilityVersion: "ASB / IET / PFS"
        ),
        requiredAll: [
            Rule(.file("system.ini"), kind: .requiredFile, detailCode: "artemis.systemIni", score: 35)
        ],
        requiredAny: [
            Rule(.file("root.pfs"), kind: .requiredFile, detailCode: "artemis.rootPfs", score: 55),
            Rule(.fileExtension("pfs"), kind: .requiredFile, detailCode: "artemis.pfs", score: 45),
            Rule(.fileExtension("asb"), kind: .requiredFile, detailCode: "artemis.asb", score: 40),
            Rule(.fileExtension("iet"), kind: .requiredFile, detailCode: "artemis.iet", score: 40)
        ],
        supporting: [
            Rule(.file("tag.ini"), kind: .metadata, detailCode: "artemis.tagIni", score: 10),
            Rule(.file("macro.iet"), kind: .characteristicFile, detailCode: "artemis.macro", score: 10),
            Rule(.fileExtension("ast"), kind: .characteristicFile, detailCode: "artemis.ast", score: 5)
        ],
        runtimeAvailable: true
    )

    static let kirikiri = SignatureGameDetector(
        descriptor: EngineDescriptor(
            id: EngineID(rawValue: "kirikiri"),
            displayName: "Kirikiri / XP3",
            compatibilityVersion: "Kirikiri 2 / Z"
        ),
        requiredAny: [
            Rule(.file("data.xp3"), kind: .requiredFile, detailCode: "kirikiri.archive", score: 75),
            Rule(.file("startup.tjs"), kind: .requiredFile, detailCode: "kirikiri.startup", score: 75),
            Rule(.file("system/startup.tjs"), kind: .requiredFile, detailCode: "kirikiri.systemStartup", score: 70),
            Rule(.file("Config.tjs"), kind: .requiredFile, detailCode: "kirikiri.config", score: 60),
            Rule(.fileExtension("xp3"), kind: .requiredFile, detailCode: "kirikiri.xp3", score: 55)
        ],
        supporting: [
            Rule(.fileExtension("ks"), kind: .characteristicFile, detailCode: "kirikiri.kagScript", score: 20),
            Rule(.fileExtension("tjs"), kind: .characteristicFile, detailCode: "kirikiri.tjs", score: 10)
        ],
        // TPM files are optional native plug-ins. The sandbox cannot execute
        // them, but many games also ship script/built-in fallbacks, so allow
        // import and report partial compatibility instead of rejecting it.
        warningExtensions: ["tpm"],
        runtimeAvailable: true
    )

    static let flash = SignatureGameDetector(
        descriptor: EngineDescriptor(
            id: EngineID(rawValue: "flash"),
            displayName: "Flash",
            compatibilityVersion: "AVM1 / AVM2"
        ),
        requiredAny: [
            Rule(.fileExtension("swf"), kind: .requiredFile, detailCode: "flash.swf", score: 90)
        ],
        supporting: [],
        runtimeAvailable: true
    )

    static let tyranoScript = SignatureGameDetector(
        descriptor: EngineDescriptor(
            id: EngineID(rawValue: "tyranoscript"),
            displayName: "TyranoScript",
            compatibilityVersion: "v4–v5 browser export"
        ),
        requiredAny: [
            Rule(.file("tyrano/tyrano.ks"), kind: .requiredFile, detailCode: "tyrano.runtime", score: 70),
            Rule(.file("tyrano/tyrano.js"), kind: .requiredFile, detailCode: "tyrano.runtime.js", score: 70),
            Rule(.file("data/scenario/first.ks"), kind: .requiredFile, detailCode: "tyrano.scenario", score: 60),
            Rule(.file("data/system/Config.tjs"), kind: .requiredFile, detailCode: "tyrano.config", score: 55)
        ],
        supporting: [
            Rule(.file("index.html"), kind: .characteristicFile, detailCode: "web.index", score: 20),
            Rule(.directory("data/scenario"), kind: .characteristicDirectory, detailCode: "tyrano.scenarioDirectory", score: 10)
        ],
        blockingExtensions: ["node"],
        runtimeAvailable: true
    )

    private static func webRPGMaker(
        id: String,
        name: String,
        markers: [String],
        version: String
    ) -> SignatureGameDetector {
        SignatureGameDetector(
            descriptor: EngineDescriptor(
                id: EngineID(rawValue: id),
                displayName: name,
                compatibilityVersion: version
            ),
            requiredAny: markers.map {
                Rule(.file($0), kind: .requiredFile, detailCode: "rpgmaker.runtime", score: 75)
            },
            supporting: [
                Rule(.file("www/index.html"), kind: .characteristicFile, detailCode: "web.index", score: 15),
                Rule(.file("index.html"), kind: .characteristicFile, detailCode: "web.index", score: 15),
                Rule(.file("www/data/system.json"), kind: .metadata, detailCode: "rpgmaker.system", score: 10),
                Rule(.file("data/system.json"), kind: .metadata, detailCode: "rpgmaker.system", score: 10)
            ],
            blockingExtensions: ["node"],
            runtimeAvailable: true
        )
    }
}
