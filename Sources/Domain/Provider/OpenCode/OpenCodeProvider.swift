import Foundation
import Observation

/// OpenCode Go provider — monitors 5-hour, weekly, and monthly cost usage from local OpenCode SQLite DB.
/// Observable class with its own state (isSyncing, snapshot, error).
@Observable
public final class OpenCodeProvider: AIProvider, @unchecked Sendable {
    // MARK: - Identity (Protocol Requirement)

    public let id: String = "opencode-go"
    public let name: String = "OpenCode Go"
    public let cliCommand: String = "opencode"

    public var dashboardURL: URL? {
        URL(string: "https://opencode.ai/auth")
    }

    public var statusPageURL: URL? {
        nil
    }

    /// Whether the provider is enabled (persisted via settingsRepository)
    public var isEnabled: Bool {
        didSet {
            settingsRepository.setEnabled(isEnabled, forProvider: id)
        }
    }

    // MARK: - State (Observable)

    /// Whether the provider is currently syncing data
    public private(set) var isSyncing: Bool = false

    /// The current usage snapshot (nil if never refreshed or unavailable)
    public private(set) var snapshot: UsageSnapshot?

    /// The last error that occurred during refresh
    public private(set) var lastError: Error?

    // MARK: - Internal

    /// The probe used to fetch usage data
    private let probe: any UsageProbe
    private let settingsRepository: any ProviderSettingsRepository

    // MARK: - Initialization

    public init(probe: any UsageProbe, settingsRepository: any ProviderSettingsRepository) {
        self.probe = probe
        self.settingsRepository = settingsRepository
        self.isEnabled = settingsRepository.isEnabled(forProvider: "opencode-go")
    }

    // MARK: - AIProvider Protocol

    public func isAvailable() async -> Bool {
        await probe.isAvailable()
    }

    /// Refreshes the usage data and updates the snapshot.
    @discardableResult
    public func refresh() async throws -> UsageSnapshot {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let newSnapshot = try await probe.probe()
            snapshot = newSnapshot
            lastError = nil
            return newSnapshot
        } catch {
            lastError = error
            throw error
        }
    }
}
