import Foundation
import Domain
#if canImport(Mockable)
import Mockable
#endif
// MARK: - Codex Service Protocol
#if canImport(Mockable)

#endif
/// Protocol for Codex service - from user's mental model: "Is it available?" and "Get my stats"
@Mockable
public protocol CodexRPCClient: Sendable {
    /// Is the Codex CLI available on this system?
    func isAvailable() -> Bool
    /// Fetch rate limits from Codex service
    func fetchRateLimits() async throws -> CodexRateLimitsResponse
    /// Cleanup resources
    func shutdown()
}
#if canImport(Mockable)

#endif
/// Response from Codex rate limits API.
public struct CodexRateLimitsResponse: Sendable, Equatable {
    public let primary: CodexRateLimitWindow?
    public let secondary: CodexRateLimitWindow?
    public let planType: String?
#if canImport(Mockable)

#endif
    public init(primary: CodexRateLimitWindow?, secondary: CodexRateLimitWindow?, planType: String? = nil) {
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
    }
}
#if canImport(Mockable)

#endif
/// A rate limit window from Codex API.
public struct CodexRateLimitWindow: Sendable, Equatable {
    public let usedPercent: Double
    public let resetDescription: String?
#if canImport(Mockable)

#endif
    public init(usedPercent: Double, resetDescription: String?) {
        self.usedPercent = usedPercent
        self.resetDescription = resetDescription
    }
}
#if canImport(Mockable)

#endif
/// Infrastructure adapter that probes the Codex CLI to fetch usage quotas.
public struct CodexUsageProbe: CodexProfileUsageProbing {
    private let client: CodexRPCClient
#if canImport(Mockable)

#endif
    public init(client: CodexRPCClient? = nil) {
        self.client = client ?? DefaultCodexRPCClient()
    }
#if canImport(Mockable)

#endif
    public func isAvailable() async -> Bool {
        client.isAvailable()
    }
#if canImport(Mockable)

#endif
    public func probe() async throws -> UsageSnapshot {
        AppLog.probes.info("Starting Codex probe...")
        defer { client.shutdown() }
#if canImport(Mockable)

#endif
        let limits = try await client.fetchRateLimits()
        let snapshot = try Self.mapRateLimitsToSnapshot(limits)
#if canImport(Mockable)

#endif
        logSuccess(snapshot)
        return snapshot
    }
#if canImport(Mockable)

#endif
    public func isAvailable(codexHomeDirectory: String) async -> Bool {
        DefaultCodexRPCClient(codexHomeDirectory: codexHomeDirectory).isAvailable()
    }
#if canImport(Mockable)

#endif
    public func probe(codexHomeDirectory: String) async throws -> UsageSnapshot {
        let expanded = NSString(string: codexHomeDirectory).expandingTildeInPath
        try CodexProfileStorage.ensureProfile(at: expanded)

        AppLog.probes.info("Starting Codex probe with isolated CODEX_HOME")
        let scopedClient = DefaultCodexRPCClient(codexHomeDirectory: expanded)
        defer { scopedClient.shutdown() }

        let limits = try await scopedClient.fetchRateLimits()
        let snapshot = try Self.mapRateLimitsToSnapshot(limits)
        logSuccess(snapshot)
        return snapshot
    }
#if canImport(Mockable)

#endif
    private func logSuccess(_ snapshot: UsageSnapshot) {
        AppLog.probes.info("Codex probe success: \(snapshot.quotas.count) quotas found")
        for quota in snapshot.quotas {
            AppLog.probes.info("  - \(quota.quotaType.displayName): \(Int(quota.percentRemaining))% remaining")
        }
    }
#if canImport(Mockable)

#endif
    /// Maps RPC rate limits response to a UsageSnapshot (internal for testing).
    internal static func mapRateLimitsToSnapshot(_ limits: CodexRateLimitsResponse) throws -> UsageSnapshot {
        var quotas: [UsageQuota] = []
#if canImport(Mockable)

#endif
        if let primary = limits.primary {
            quotas.append(UsageQuota(
                percentRemaining: max(0, 100 - primary.usedPercent),
                quotaType: .session,
                providerId: "codex",
                resetText: primary.resetDescription
            ))
        }
#if canImport(Mockable)

#endif
        if let secondary = limits.secondary {
            quotas.append(UsageQuota(
                percentRemaining: max(0, 100 - secondary.usedPercent),
                quotaType: .weekly,
                providerId: "codex",
                resetText: secondary.resetDescription
            ))
        }
#if canImport(Mockable)

#endif
        guard !quotas.isEmpty else {
            AppLog.probes.error("Codex probe failed: no rate limits in RPC response")
            throw ProbeError.parseFailed("No rate limits found")
        }
#if canImport(Mockable)

#endif
        return UsageSnapshot(
            providerId: "codex",
            quotas: quotas,
            capturedAt: Date()
        )
    }
#if canImport(Mockable)

#endif
    // MARK: - Parsing (for TTY fallback)
#if canImport(Mockable)

#endif
    public static func parse(_ text: String) throws -> UsageSnapshot {
        let clean = stripANSICodes(text)
#if canImport(Mockable)

#endif
        if let error = extractUsageError(clean) {
            throw error
        }
#if canImport(Mockable)

#endif
        let fiveHourPct = extractPercent(labelSubstring: "5h limit", text: clean)
        let weeklyPct = extractPercent(labelSubstring: "Weekly limit", text: clean)
#if canImport(Mockable)

#endif
        var quotas: [UsageQuota] = []
#if canImport(Mockable)

#endif
        if let fiveHourPct {
            quotas.append(UsageQuota(
                percentRemaining: Double(fiveHourPct),
                quotaType: .session,
                providerId: "codex"
            ))
        }
#if canImport(Mockable)

#endif
        if let weeklyPct {
            quotas.append(UsageQuota(
                percentRemaining: Double(weeklyPct),
                quotaType: .weekly,
                providerId: "codex"
            ))
        }
#if canImport(Mockable)

#endif
        if quotas.isEmpty {
            AppLog.probes.error("Codex parse failed: could not find usage limits in TTY output")
            AppLog.probes.debug("Raw output (original, \(text.count) chars): \(text.debugDescription)")
            AppLog.probes.debug("Raw output (cleaned, \(clean.count) chars): \(clean)")
            throw ProbeError.parseFailed("Could not find usage limits in Codex output")
        }
#if canImport(Mockable)

#endif
        return UsageSnapshot(
            providerId: "codex",
            quotas: quotas,
            capturedAt: Date()
        )
    }
#if canImport(Mockable)

#endif
    // MARK: - Text Parsing Helpers
#if canImport(Mockable)

#endif
    internal static func stripANSICodes(_ text: String) -> String {
        let pattern = #"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])"#
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
#if canImport(Mockable)

#endif
    private static func extractPercent(labelSubstring: String, text: String) -> Int? {
        let lines = text.components(separatedBy: .newlines)
        let label = labelSubstring.lowercased()
#if canImport(Mockable)

#endif
        for (idx, line) in lines.enumerated() where line.lowercased().contains(label) {
            let window = lines.dropFirst(idx).prefix(12)
            for candidate in window {
                if let pct = percentFromLine(candidate) {
                    return pct
                }
            }
        }
        return nil
    }
#if canImport(Mockable)

#endif
    private static func percentFromLine(_ line: String) -> Int? {
        let pattern = #"([0-9]{1,3})%\s+left"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 2,
              let valRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return Int(line[valRange])
    }
#if canImport(Mockable)

#endif
    internal static func extractUsageError(_ text: String) -> ProbeError? {
        let lower = text.lowercased()
#if canImport(Mockable)

#endif
        if lower.contains("data not available yet") {
            AppLog.probes.error("Codex probe failed: data not available yet")
            return .parseFailed("Data not available yet")
        }
#if canImport(Mockable)

#endif
        if lower.contains("update available") && lower.contains("codex") {
            AppLog.probes.error("Codex probe failed: CLI update required")
            return .updateRequired
        }
#if canImport(Mockable)

#endif
        if lower.contains("not logged in") || lower.contains("please log in") {
            AppLog.probes.error("Codex probe failed: not logged in")
            return .authenticationRequired
        }
#if canImport(Mockable)

#endif
        return nil
    }
}

#if canImport(Mockable)



#endif