import Foundation
import Domain

/// Probes local OpenCode database for Go usage quotas.
///
/// Tracks 3 Go usage windows (against $12/$30/$60 limits):
/// - 5-hour ($12) — mapped to `.session` quota type
/// - Weekly ($30) — mapped to `.weekly` quota type
/// - Monthly ($60) — mapped to `.timeLimit("Monthly")` quota type
///
/// Queries the OpenCode SQLite DB via `opencode db` with JSON output.
public struct OpenCodeUsageProbe: UsageProbe {

    // OpenCode Go usage limits
    static let fiveHourLimit: Double = 12.0
    static let weeklyLimit: Double = 30.0
    static let monthlyLimit: Double = 60.0

    private let cliExecutor: any CLIExecutor
    private let timeout: TimeInterval

    public init(
        cliExecutor: (any CLIExecutor)? = nil,
        timeout: TimeInterval = 15.0
    ) {
        self.cliExecutor = cliExecutor ?? DefaultCLIExecutor()
        self.timeout = timeout
    }

    // MARK: - UsageProbe

    public func isAvailable() async -> Bool {
        guard cliExecutor.locate("opencode") != nil else {
            AppLog.probes.debug("OpenCode: CLI not found in PATH")
            return false
        }
        do {
            let result = try cliExecutor.execute(
                binary: "opencode",
                args: ["db", "path"],
                input: nil,
                timeout: timeout,
                workingDirectory: nil,
                autoResponses: [:]
            )
            let dbPath = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let exists = FileManager.default.fileExists(atPath: dbPath)
            if !exists {
                AppLog.probes.debug("OpenCode: DB not found at \(dbPath)")
            }
            return exists
        } catch {
            AppLog.probes.debug("OpenCode: DB check failed - \(error.localizedDescription)")
            return false
        }
    }

    public func probe() async throws -> UsageSnapshot {
        AppLog.probes.info("Starting OpenCode probe...")

        guard cliExecutor.locate("opencode") != nil else {
            AppLog.probes.error("OpenCode probe failed: opencode binary not found")
            throw ProbeError.cliNotFound("opencode")
        }

        let windowData = try await runCombinedWindowQuery()
        let windows = try Self.parseWindowCosts(windowData)

        let fiveHourRemaining = Self.percentRemaining(used: windows.fiveHourCost, limit: Self.fiveHourLimit)
        let weeklyRemaining = Self.percentRemaining(used: windows.weeklyCost, limit: Self.weeklyLimit)
        let monthlyRemaining = Self.percentRemaining(used: windows.monthlyCost, limit: Self.monthlyLimit)

        let now = Date()
        let quotas: [UsageQuota] = [
            UsageQuota(
                percentRemaining: fiveHourRemaining,
                quotaType: .session,
                providerId: "opencode-go",
                resetsAt: Self.fiveHourResetDate(from: windows.fiveHourOldestMs, fallback: now)
            ),
            UsageQuota(
                percentRemaining: weeklyRemaining,
                quotaType: .weekly,
                providerId: "opencode-go",
                resetsAt: Self.endOfWeek(from: now)
            ),
            UsageQuota(
                percentRemaining: monthlyRemaining,
                quotaType: .timeLimit("Monthly"),
                providerId: "opencode-go",
                resetsAt: Self.endOfMonth(from: now)
            ),
        ]

        AppLog.probes.info("OpenCode probe success: 5hr \(Int(fiveHourRemaining))%, weekly \(Int(weeklyRemaining))%, monthly \(Int(monthlyRemaining))%")

        return UsageSnapshot(
            providerId: "opencode-go",
            quotas: quotas,
            capturedAt: Date()
        )
    }

    // MARK: - DB Query

    /// Runs a single query returning cost for 5-hour, weekly, and monthly windows.
    private func runCombinedWindowQuery() async throws -> Data {
        let now = Date()
        let fiveHourMs = Self.millisSinceEpoch(now.addingTimeInterval(-5 * 3600))
        let weekStartMs = Self.millisSinceEpoch(Self.startOfWeek(from: now))
        let monthStartMs = Self.millisSinceEpoch(Self.startOfMonth(from: now))
        // Use earliest cutoff so 5-hour and weekly windows still work when
        // they cross a month boundary (e.g., now is May 1 at 2am, weekStart is April 28).
        let earliestCutoffMs = min(fiveHourMs, weekStartMs, monthStartMs)

        // Count only messages routed through OpenCode Go; API-key traffic does not use Go quota.
        let sql = """
        SELECT
          COALESCE(SUM(CASE WHEN time_created >= \(fiveHourMs) THEN CAST(json_extract(data, '$.cost') AS REAL) ELSE 0 END), 0) as five_hour_cost,
          COALESCE(SUM(CASE WHEN time_created >= \(weekStartMs) THEN CAST(json_extract(data, '$.cost') AS REAL) ELSE 0 END), 0) as weekly_cost,
          COALESCE(SUM(CASE WHEN time_created >= \(monthStartMs) THEN CAST(json_extract(data, '$.cost') AS REAL) ELSE 0 END), 0) as monthly_cost,
          MIN(CASE WHEN time_created >= \(fiveHourMs) THEN time_created ELSE NULL END) as five_hour_oldest_ms
        FROM message
        WHERE json_extract(data, '$.role') = 'assistant'
          AND json_extract(data, '$.providerID') = 'opencode-go'
          AND time_created >= \(earliestCutoffMs)
        """
        return try await runDBQuery(sql)
    }

    private func runDBQuery(_ sql: String) async throws -> Data {
        let result = try cliExecutor.execute(
            binary: "opencode",
            args: ["db", sql, "--format", "json"],
            input: nil,
            timeout: timeout,
            workingDirectory: nil,
            autoResponses: [:]
        )

        guard result.exitCode == 0 else {
            AppLog.probes.error("OpenCode: DB query failed with exit code \(result.exitCode)")
            throw ProbeError.executionFailed("opencode db exited with code \(result.exitCode)")
        }

        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = output.data(using: .utf8) else {
            throw ProbeError.parseFailed("Failed to encode query output")
        }

        return data
    }

    // MARK: - Static Helpers (testable)

    /// Parses window costs from the combined window query result.
    static func parseWindowCosts(_ data: Data) throws -> WindowCosts {
        let rows = try JSONDecoder().decode([WindowRow].self, from: data)
        guard let row = rows.first else {
            throw ProbeError.parseFailed("No window cost data")
        }
        return WindowCosts(
            fiveHourCost: row.five_hour_cost,
            weeklyCost: row.weekly_cost,
            monthlyCost: row.monthly_cost,
            fiveHourOldestMs: row.five_hour_oldest_ms
        )
    }

    /// Returns percentage remaining, clamped to [0, 100].
    /// Over-limit usage clamps to 0%, which maps to `.depleted`.
    static func percentRemaining(used: Double, limit: Double) -> Double {
        guard limit > 0 else { return 100 }
        return max(0, min(100, (limit - used) / limit * 100))
    }

    // MARK: - Time helpers

    static func millisSinceEpoch(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    static func fiveHourResetDate(from oldestMs: Int64?, fallback now: Date) -> Date {
        guard let oldestMs else {
            return now.addingTimeInterval(5 * 3600)
        }
        return Date(timeIntervalSince1970: TimeInterval(oldestMs) / 1000)
            .addingTimeInterval(5 * 3600)
    }

    static func startOfWeek(from date: Date) -> Date {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: date)
        return cal.startOfDay(for: cal.date(byAdding: .day, value: -(weekday - 1), to: date) ?? date)
    }

    static func endOfWeek(from date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 7, to: startOfWeek(from: date)) ?? date
    }

    static func startOfMonth(from date: Date) -> Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
    }

    static func endOfMonth(from date: Date) -> Date {
        let cal = Calendar.current
        guard let start = cal.date(from: cal.dateComponents([.year, .month], from: date)) else {
            return date
        }
        return cal.date(byAdding: DateComponents(month: 1, second: -1), to: start) ?? date
    }
}

// MARK: - DB Row Models

private struct WindowRow: Decodable {
    let five_hour_cost: Double
    let weekly_cost: Double
    let monthly_cost: Double
    let five_hour_oldest_ms: Int64?
}

/// Parsed window costs for Go quota tracking.
public struct WindowCosts: Sendable {
    public let fiveHourCost: Double
    public let weeklyCost: Double
    public let monthlyCost: Double
    public let fiveHourOldestMs: Int64?
}
