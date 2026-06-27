import Foundation
import Observation

private protocol CodexAPIProbing: Sendable {
    func probe(overrideAccessToken: String?, accountId: String?) async throws -> UsageSnapshot
}

/// Codex AI provider - a rich domain model.
/// Observable class with its own state (isSyncing, snapshot, error).
/// Supports dual probe modes: RPC (default) and API.
@MainActor
@Observable
public final class CodexProvider: AIProvider, MultiAccountProvider {
    // MARK: - Identity

    public let id: String = "codex"
    public let name: String = "Codex"
    public let cliCommand: String = "codex"

    public var dashboardURL: URL? {
        URL(string: "https://platform.openai.com/usage")
    }

    public var statusPageURL: URL? {
        URL(string: "https://status.openai.com")
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

    /// The current usage snapshot (active account)
    public private(set) var snapshot: UsageSnapshot?

    /// The last error that occurred during refresh
    public private(set) var lastError: Error?

    // MARK: - Multi-account state

    /// All configured accounts
    public private(set) var accounts: [ProviderAccount] = []

    /// The current active account for backward-compatible UI (single snapshot)
    public var activeAccount: ProviderAccount {
        if let activeId = activeAccountId(),
           let active = accounts.first(where: { $0.accountId == activeId }) {
            return active
        }
        return accounts.first ?? ProviderAccount(accountId: ProviderAccount.defaultAccountId, providerId: id, label: "Codex")
    }

    /// Snapshots for all accounts, keyed by account id
    public private(set) var accountSnapshots: [String: UsageSnapshot] = [:]

    // MARK: - Probe Mode

    public var probeMode: CodexProbeMode {
        get {
            if let codexSettings = settingsRepository as? CodexSettingsRepository {
                return codexSettings.codexProbeMode()
            }
            return .rpc
        }
        set {
            if let codexSettings = settingsRepository as? CodexSettingsRepository {
                codexSettings.setCodexProbeMode(newValue)
            }
        }
    }

    // MARK: - Internal

    /// The RPC probe for fetching usage data via `codex app-server`
    private let rpcProbe: any UsageProbe

    /// The API probe for fetching usage data via HTTP API (optional)
    private let apiProbe: (any UsageProbe)?

    /// Typed API probe for account-level token/id overrides
    private let codexAPIProbe: (any CodexAPIProbing)?

    /// Repository for provider configuration
    private let settingsRepository: any ProviderSettingsRepository

    private var multiAccountRepository: (any MultiAccountSettingsRepository)? {
        settingsRepository as? any MultiAccountSettingsRepository
    }

    /// Raw per-account configs, used to build API request parameters
    private var accountConfigs: [String: ProviderAccountConfig] = [:]

    /// Returns the active probe based on current mode
    private var activeProbe: any UsageProbe {
        switch probeMode {
        case .rpc:
            return rpcProbe
        case .api:
            // Fall back to RPC if API probe not available
            return apiProbe ?? rpcProbe
        }
    }

    // MARK: - Internal constants

    private enum ProbeConfigKey {
        static let accessToken = "accessToken"
        static let accountId = "accountId"
    }

    // MARK: - Initialization

    /// Creates a Codex provider with RPC probe only (legacy initializer)
    /// - Parameters:
    ///   - probe: The RPC probe to use for fetching usage data
    ///   - settingsRepository: The repository for persisting settings
    public init(
        probe: any UsageProbe,
        settingsRepository: any ProviderSettingsRepository
    ) {
        self.rpcProbe = probe
        self.apiProbe = nil
        self.codexAPIProbe = nil
        self.settingsRepository = settingsRepository
        self.isEnabled = settingsRepository.isEnabled(forProvider: id)
        refreshAccountStateFromStorage()
    }

    /// Creates a Codex provider with both RPC and API probes
    /// - Parameters:
    ///   - rpcProbe: The RPC probe for fetching usage via `codex app-server`
    ///   - apiProbe: The API probe for fetching usage via HTTP API
    ///   - settingsRepository: The repository for persisting settings (must be CodexSettingsRepository for mode switching)
    public init(
        rpcProbe: any UsageProbe,
        apiProbe: any UsageProbe,
        settingsRepository: any CodexSettingsRepository
    ) {
        self.rpcProbe = rpcProbe
        self.apiProbe = apiProbe
        self.codexAPIProbe = apiProbe as? any CodexAPIProbing
        self.settingsRepository = settingsRepository
        self.isEnabled = settingsRepository.isEnabled(forProvider: id)
        refreshAccountStateFromStorage()
    }

    // MARK: - AIProvider Protocol

    public func isAvailable() async -> Bool {
        switch probeMode {
        case .rpc:
            if await rpcProbe.isAvailable() {
                return true
            }
            return await apiProbe?.isAvailable() ?? false
        case .api:
            if let token = activeProbeConfig?.probeConfig[ProbeConfigKey.accessToken], hasText(token) {
                return true
            }
            return await apiProbe?.isAvailable() ?? false
        }
    }

    @discardableResult
    public func refresh() async throws -> UsageSnapshot {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let activeAccountId = activeAccount.accountId
            let newSnapshot = try await refreshAccount(activeAccountId)
            snapshot = newSnapshot
            lastError = nil
            return newSnapshot
        } catch {
            lastError = error
            throw error
        }
    }

    /// Refreshes the usage data for the active account using `refreshAccount`.
    /// `kind` is intentionally unused for now but accepted for protocol symmetry.
    @discardableResult
    public func refresh(_ kind: RefreshKind) async throws -> UsageSnapshot {
        try await refresh()
    }

    // MARK: - MultiAccountProvider Requirements

    @discardableResult
    public func switchAccount(to accountId: String) -> Bool {
        guard accountExists(accountId) else {
            return false
        }

        multiAccountRepository?.setActiveAccountId(accountId, forProvider: id)
        snapshot = accountSnapshots[accountId]
        return true
    }

    @discardableResult
    public func refreshAccount(_ accountId: String) async throws -> UsageSnapshot {
        guard let account = accounts.first(where: { $0.accountId == accountId }) else {
            let error = ProbeError.executionFailed("Account not found")
            lastError = error
            throw error
        }

        let newSnapshot = try await fetchSnapshot(for: account)
        accountSnapshots[accountId] = newSnapshot

        if accountId == activeAccount.accountId {
            snapshot = newSnapshot
        }

        return newSnapshot
    }

    public func refreshAllAccounts() async {
        await withTaskGroup(of: UsageSnapshot?.self) { group in
            for account in accounts {
                group.addTask {
                    return try? await self.refreshAccount(account.accountId)
                }
            }
        }
    }

    public func addAccount(_ config: ProviderAccountConfig) -> Bool {
        guard let repo = multiAccountRepository else {
            return false
        }

        let normalized = normalize(config)
        guard !accountExists(normalized.accountId) else {
            return false
        }

        let countBefore = accounts.count
        repo.addAccount(normalized, forProvider: id)
        refreshAccountStateFromStorage()

        if countBefore == 0 {
            repo.setActiveAccountId(normalized.accountId, forProvider: id)
            refreshAccountStateFromStorage()
        }

        return true
    }

    @discardableResult
    public func removeAccount(_ accountId: String) -> Bool {
        guard let repo = multiAccountRepository else {
            return false
        }

        guard accounts.count > 1 else {
            return false
        }

        guard accountExists(accountId) else {
            return false
        }

        repo.removeAccount(accountId: accountId, forProvider: id)
        accountSnapshots.removeValue(forKey: accountId)
        refreshAccountStateFromStorage()
        snapshot = accountSnapshots[activeAccount.accountId]
        return true
    }

    public func updateAccount(_ config: ProviderAccountConfig) {
        guard let repo = multiAccountRepository else {
            return
        }

        let normalized = normalize(config)
        repo.updateAccount(normalized, forProvider: id)
        refreshAccountStateFromStorage()
    }

    /// Whether API mode is available (API probe was provided)
    public var supportsApiMode: Bool {
        apiProbe != nil
    }

    // MARK: - Private Helpers

    private func hasText(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var activeProbeConfig: ProviderAccountConfig? {
        accountConfigs[activeAccount.accountId]
    }

    private func activeAccountId() -> String? {
        multiAccountRepository?.activeAccountId(forProvider: id)
    }

    private func accountExists(_ accountId: String) -> Bool {
        accounts.contains(where: { $0.accountId == accountId })
    }

    private func normalize(_ config: ProviderAccountConfig) -> ProviderAccountConfig {
        let accountId = config.accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeId = accountId.isEmpty ? UUID().uuidString : accountId

        let label = config.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeLabel = label.isEmpty ? "Codex" : label

        let trimmedProbeConfig = config.probeConfig.compactMapValues { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return ProviderAccountConfig(
            accountId: safeId,
            label: safeLabel,
            email: config.email?.trimmingCharacters(in: .whitespacesAndNewlines),
            organization: config.organization?.trimmingCharacters(in: .whitespacesAndNewlines),
            probeConfig: trimmedProbeConfig
        )
    }

    private func refreshAccountStateFromStorage() {
        guard let repo = multiAccountRepository else {
            let fallback = ProviderAccount(
                accountId: ProviderAccount.defaultAccountId,
                providerId: id,
                label: "Codex"
            )
            accounts = [fallback]
            accountConfigs = [
                ProviderAccount.defaultAccountId: ProviderAccountConfig(
                    accountId: ProviderAccount.defaultAccountId,
                    label: "Codex"
                )
            ]
            if snapshot == nil {
                snapshot = accountSnapshots[activeAccount.accountId]
            }
            return
        }

        let loadedConfigs = repo.accounts(forProvider: id)

        if loadedConfigs.isEmpty {
            let defaultConfig = ProviderAccountConfig(
                accountId: ProviderAccount.defaultAccountId,
                label: "Codex"
            )
            repo.setAccounts([defaultConfig], forProvider: id)
            repo.setActiveAccountId(defaultConfig.accountId, forProvider: id)
            accountConfigs = [defaultConfig.accountId: defaultConfig]
            accounts = [defaultConfig.toProviderAccount(providerId: id)]
            return
        }

        accountConfigs = Dictionary(uniqueKeysWithValues: loadedConfigs.map { ($0.accountId, $0) })
        accounts = loadedConfigs.map { $0.toProviderAccount(providerId: id) }

        guard let activeId = repo.activeAccountId(forProvider: id), accountExists(activeId) else {
            if let first = accounts.first {
                repo.setActiveAccountId(first.accountId, forProvider: id)
            }
            return
        }

        snapshot = accountSnapshots[activeId]
    }

    private func fetchSnapshot(for account: ProviderAccount) async throws -> UsageSnapshot {
        switch probeMode {
        case .rpc:
            return try await rpcProbe.probe()
        case .api:
            guard let apiProbe else {
                throw ProbeError.executionFailed("API probe is not configured")
            }

            let config = accountConfigs[account.accountId] ?? ProviderAccountConfig(
                accountId: account.accountId,
                label: account.label,
                email: account.email,
                organization: account.organization
            )

            let accessToken = config.probeConfig[ProbeConfigKey.accessToken]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let accountId = config.probeConfig[ProbeConfigKey.accountId]?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let typed = codexAPIProbe {
                return try await typed.probe(overrideAccessToken: accessToken, accountId: accountId)
            }

            return try await apiProbe.probe()
        }
    }
}
