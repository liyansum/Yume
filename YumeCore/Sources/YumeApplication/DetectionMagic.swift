import Foundation
import YumeDomain

/// Content-magic rules applied after signature detection so a renamed or
/// corrupted evidence file fails closed instead of shipping as "runnable".
public enum DetectionMagic {
    public struct Rule: Sendable, Equatable {
        public let pathSuffix: String
        public let allowedPrefixes: [String]

        public init(pathSuffix: String, allowedPrefixes: [String]) {
            self.pathSuffix = pathSuffix
            self.allowedPrefixes = allowedPrefixes
        }
    }

    public static let rules: [Rule] = [
        Rule(pathSuffix: ".xp3", allowedPrefixes: ["XP3\r\n \n\u{001A}"]),
        Rule(pathSuffix: ".swf", allowedPrefixes: ["FWS", "CWS", "ZWS"]),
        Rule(pathSuffix: ".rgssad", allowedPrefixes: ["RGSSAD\0"]),
        Rule(pathSuffix: ".rgss2a", allowedPrefixes: ["RGSSAD\0"]),
        Rule(pathSuffix: ".rgss3a", allowedPrefixes: ["RGSSAD\0"]),
        Rule(pathSuffix: ".rpa", allowedPrefixes: ["RPA-"])
    ]

    /// Returns blocking issues for every characteristic file whose head does
    /// not match the declared format. Files without a rule are skipped.
    public static func verify(
        _ probe: ProbeResult,
        readHead: @Sendable (StorageRelativePath, Int) async throws -> Data?
    ) async -> [CompatibilityIssue] {
        let rulesBySuffix = Dictionary(uniqueKeysWithValues: rules.map { ($0.pathSuffix, $0) })
        var issues: [CompatibilityIssue] = []

        for evidence in probe.evidence
        where evidence.kind == .requiredFile || evidence.kind == .characteristicFile {
            let path = evidence.relativePath.rawValue.lowercased()
            guard let rule = rulesBySuffix.first(where: { path.hasSuffix($0.key) })?.value else { continue }

            guard let head = try? await readHead(evidence.relativePath, 16),
                  !head.isEmpty
            else {
                issues.append(
                    CompatibilityIssue(
                        id: "magic-unreadable:\(evidence.relativePath.rawValue)",
                        severity: .blocking,
                        detailCode: "detection.magicUnreadable",
                        relativePath: evidence.relativePath
                    )
                )
                continue
            }

            let headText = String(decoding: [UInt8](head.prefix(16)), as: UTF8.self)
            let matched = rule.allowedPrefixes.contains { prefix in
                headText.hasPrefix(prefix)
            }
            if !matched {
                issues.append(
                    CompatibilityIssue(
                        id: "magic-mismatch:\(evidence.relativePath.rawValue)",
                        severity: .blocking,
                        detailCode: "detection.magicMismatch",
                        relativePath: evidence.relativePath
                    )
                )
            }
        }
        return issues
    }

    /// Rebuilds the compatibility report with magic-verification issues merged.
    public static func hardened(_ probe: ProbeResult, issues: [CompatibilityIssue]) -> ProbeResult {
        guard !issues.isEmpty else { return probe }
        var combined = probe.compatibility.issues
        combined.append(contentsOf: issues)
        return ProbeResult(
            engine: probe.engine,
            rootRelativePath: probe.rootRelativePath,
            confidence: probe.confidence,
            evidence: probe.evidence,
            compatibility: CompatibilityReport(status: .unsupported, issues: combined)
        )
    }
}
