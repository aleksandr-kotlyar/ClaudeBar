import Foundation
import Observation

/// Mistral AI provider - a rich domain model.
/// Observable class with its own state (isSyncing, snapshot, error).
/// Owns its probe and manages its own data lifecycle.
@MainActor
@Observable
public final class MistralProvider: AIProvider {
    // MARK: - Identity (Protocol Requirement)

    public let id: String = "mistral"
    public let name: String = "Mistral"
    public let cliCommand: String = "" // log-only provider, no CLI

    public var dashboardURL: URL? {
        URL(string: "https://console.mistral.ai")
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
        // Default to disabled until user explicitly enables
        self.isEnabled = settingsRepository.isEnabled(forProvider: "mistral", defaultValue: false)
    }

    // MARK: - AIProvider Protocol

    public func isAvailable() async -> Bool {
        await probe.isAvailable()
    }

    /// Refreshes the usage data and updates the snapshot.
    /// Sets isSyncing during refresh and captures any errors.
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
