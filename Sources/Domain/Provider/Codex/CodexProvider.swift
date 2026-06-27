import Foundation
import Observation

/// Shared Codex profile path helpers.
///
/// ClaudeBar keeps one Codex CODEX_HOME per app account so ChatGPT/Codex
/// credentials do not overwrite each other. The profile folder is an internal
/// implementation detail; the user-facing account identity comes from
/// `account/read` (email/plan) after login.
public enum CodexProfilePaths {
    public static let probeConfigKey = "codexHome"

    public static func defaultCodexHome(for accountId: String) -> String {
        let safe = sanitizedProfileComponent(accountId)
        return (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claudebar/codex/profiles/\(safe)")
    }

    public static func codexHome(from config: ProviderAccountConfig) -> String {
        let configured = config.probeConfig[probeConfigKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let configured, !configured.isEmpty {
            return NSString(string: configured).expandingTildeInPath
        }

        return defaultCodexHome(for: config.accountId)
    }

    public static func codexHome(for account: ProviderAccount) -> String {
        defaultCodexHome(for: account.accountId)
    }

    private static func sanitizedProfileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")

        return collapsed.isEmpty ? UUID().uuidString : collapsed
    }
}

/// A UsageProbe that can run against an explicit Codex CODEX_HOME.
public protocol CodexProfileUsageProbing: UsageProbe {
    func probe(codexHomeDirectory: String) async throws -> UsageSnapshot
    func isAvailable(codexHomeDirectory: String) async -> Bool
}

/// API-mode Codex probe that can read credentials from an explicit CODEX_HOME.
public protocol CodexProfileAPIProbing: UsageProbe {
    func probe(
        codexHomeDirectory: String,
        overrideAccessToken: String?,
        accountId: String?
    ) async throws -> UsageSnapshot

    func isAvailable(codexHomeDirectory: String) async -> Bool
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

    /// Per-account refresh state, keyed by account ID
    private var accountSyncing: [String: Bool] = [:]

    /// Per-account refresh error, keyed by account ID
    private var accountErrors: [String: Error] = [:]

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

    /// Whether the active account has a stored API access token in its probe config
    public var activeAccountHasStoredAccessToken: Bool {
        hasText(accountConfigs[activeAccount.accountId]?.probeConfig[ProbeConfigKey.accessToken])
    }

    /// Internal Codex CODEX_HOME directory for a provider account.
    /// This is intentionally not user-facing UI; it isolates Codex auth caches per account.
    public func codexHomeDirectory(for accountId: String) -> String {
        if let config = accountConfigs[accountId] {
            return CodexProfilePaths.codexHome(from: config)
        }

        return CodexProfilePaths.defaultCodexHome(for: accountId)
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
    private let codexAPIProbe: (any CodexProfileAPIProbing)?

    /// Optional credential checker for account-level CODEX_HOME availability.
    private let codexCredentialChecker: (any CodexCredentialAvailabilityChecking)?

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
        static let codexHome = CodexProfilePaths.probeConfigKey
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
        self.codexCredentialChecker = nil
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
        self.codexAPIProbe = apiProbe as? any CodexProfileAPIProbing
        self.settingsRepository = settingsRepository
        self.isEnabled = settingsRepository.isEnabled(forProvider: id)
        refreshAccountStateFromStorage()
    }

    // MARK: - AIProvider Protocol

    public func isAvailable() async -> Bool {
        let config = activeProbeConfig
        let connectionMode = config?.codexConnectionMode ?? .existingSession

        if connectionMode == .manualApiToken {
            return hasText(config?.codexAccessToken)
        }

        let codexHomePath: String?
        switch connectionMode {
        case .existingSession:
            codexHomePath = nil
        case .customCodexHome, .deviceCodeProfile:
            guard let path = config?.codexHomePath else {
                return false
            }
            codexHomePath = path
        case .manualApiToken:
            codexHomePath = nil
        }

        switch probeMode {
        case .rpc:
            if await rpcProbe.isAvailable() {
                return true
            }
            return await isAPIProbeAvailable(codexHomePath: codexHomePath)
        case .api:
            return await isAPIProbeAvailable(codexHomePath: codexHomePath)
        }
    }

    @discardableResult
    public func refresh() async throws -> UsageSnapshot {
        let activeAccountId = activeAccount.accountId
        return try await refreshAccount(activeAccountId)
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
        syncActiveAccountState()
        return true
    }

    @discardableResult
    public func refreshAccount(_ accountId: String) async throws -> UsageSnapshot {
        guard let account = accounts.first(where: { $0.accountId == accountId }) else {
            let error = ProbeError.executionFailed("Account not found")
            setAccountError(error, for: accountId)
            throw error
        }

        setAccountSyncing(true, for: accountId)
        defer { setAccountSyncing(false, for: accountId) }

        do {
            let newSnapshot = try await fetchSnapshot(for: account)
            accountSnapshots[accountId] = newSnapshot
            setAccountError(nil, for: accountId)

            if accountId == activeAccount.accountId {
                snapshot = newSnapshot
            }

            return newSnapshot
        } catch {
            setAccountError(error, for: accountId)
            throw error
        }
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
        accountErrors.removeValue(forKey: accountId)
        accountSyncing.removeValue(forKey: accountId)
        accountSnapshots.removeValue(forKey: accountId)
        refreshAccountStateFromStorage()
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

    public func cacheLoginMetadata(for accountId: String, email: String?, plan: String?) {
        guard let repo = multiAccountRepository else {
            return
        }

        guard let config = accountConfigs[accountId] else {
            return
        }

        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPlan = plan?.trimmingCharacters(in: .whitespacesAndNewlines)

        let updated = ProviderAccountConfig(
            accountId: config.accountId,
            label: config.label,
            email: trimmedEmail?.isEmpty == false ? trimmedEmail : config.email,
            organization: trimmedPlan?.isEmpty == false ? trimmedPlan : config.organization,
            probeConfig: config.probeConfig
        )

        repo.updateAccount(updated, forProvider: id)
        refreshAccountStateFromStorage()
    }

    /// Whether API mode is available (API probe was provided)
    public var supportsApiMode: Bool {
        apiProbe != nil
    }

    /// Returns the persisted account config for Codex-specific UI.
    public func accountConfig(for accountId: String) -> ProviderAccountConfig? {
        accountConfigs[accountId]
    }

    public func connectionMode(for accountId: String) -> CodexConnectionMode {
        accountConfigs[accountId]?.codexConnectionMode ?? .existingSession
    }

    public func codexHomePath(for accountId: String) -> String? {
        accountConfigs[accountId]?.codexHomePath
    }

    // MARK: - Private Helpers

    private func hasText(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func setAccountSyncing(_ syncing: Bool, for accountId: String) {
        if syncing {
            accountSyncing[accountId] = true
        } else {
            accountSyncing.removeValue(forKey: accountId)
        }

        if accountId == activeAccount.accountId {
            isSyncing = syncing
        }
    }

    private func setAccountError(_ error: Error?, for accountId: String) {
        if let error {
            accountErrors[accountId] = error
        } else {
            accountErrors.removeValue(forKey: accountId)
        }

        if accountId == activeAccount.accountId {
            lastError = error
        }
    }

    private func syncActiveAccountState() {
        let accountId = activeAccount.accountId
        snapshot = accountSnapshots[accountId]
        isSyncing = accountSyncing[accountId] ?? false
        lastError = accountErrors[accountId]
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

        var trimmedProbeConfig = config.probeConfig.compactMapValues { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if trimmedProbeConfig[ProbeConfigKey.codexHome] == nil {
            trimmedProbeConfig[ProbeConfigKey.codexHome] = CodexProfilePaths.defaultCodexHome(for: safeId)
        } else if let codexHome = trimmedProbeConfig[ProbeConfigKey.codexHome] {
            trimmedProbeConfig[ProbeConfigKey.codexHome] = NSString(string: codexHome).expandingTildeInPath
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
                    label: "Codex",
                    probeConfig: [ProbeConfigKey.codexHome: CodexProfilePaths.defaultCodexHome(for: ProviderAccount.defaultAccountId)]
                )
            ]
            syncActiveAccountState()
            return
        }

        let storedConfigs = repo.accounts(forProvider: id)
        let loadedConfigs = storedConfigs.map(normalize)
        if loadedConfigs != storedConfigs {
            repo.setAccounts(loadedConfigs, forProvider: id)
        }

        if loadedConfigs.isEmpty {
            let defaultConfig = ProviderAccountConfig(
                accountId: ProviderAccount.defaultAccountId,
                label: "Codex",
                probeConfig: [ProbeConfigKey.codexHome: CodexProfilePaths.defaultCodexHome(for: ProviderAccount.defaultAccountId)]
            )
            repo.setAccounts([defaultConfig], forProvider: id)
            repo.setActiveAccountId(defaultConfig.accountId, forProvider: id)
            accountConfigs = [defaultConfig.accountId: defaultConfig]
            accounts = [defaultConfig.toProviderAccount(providerId: id)]
            syncActiveAccountState()
            return
        }

        accountConfigs = Dictionary(uniqueKeysWithValues: loadedConfigs.map { ($0.accountId, $0) })
        accounts = loadedConfigs.map { $0.toProviderAccount(providerId: id) }

        guard let activeId = repo.activeAccountId(forProvider: id), accountExists(activeId) else {
            if let first = accounts.first {
                repo.setActiveAccountId(first.accountId, forProvider: id)
            }
            syncActiveAccountState()
            return
        }

        syncActiveAccountState()
    }

    private func fetchSnapshot(for account: ProviderAccount) async throws -> UsageSnapshot {
        switch probeMode {
        case .rpc:
            if let profileProbe = rpcProbe as? any CodexProfileUsageProbing {
                let config = accountConfigs[account.accountId] ?? ProviderAccountConfig(
                    accountId: account.accountId,
                    label: account.label,
                    email: account.email,
                    organization: account.organization,
                    probeConfig: [ProbeConfigKey.codexHome: CodexProfilePaths.defaultCodexHome(for: account.accountId)]
                )
                return try await profileProbe.probe(codexHomeDirectory: CodexProfilePaths.codexHome(from: config))
            }
            return try await rpcProbe.probe()
        case .api:
            guard let apiProbe else {
                throw ProbeError.executionFailed("API probe is not configured")
            }

            let config = accountConfigs[account.accountId] ?? ProviderAccountConfig(
                accountId: account.accountId,
                label: account.label,
                email: account.email,
                organization: account.organization,
                probeConfig: [ProbeConfigKey.codexHome: CodexProfilePaths.defaultCodexHome(for: account.accountId)]
            )

            let accessToken = config.probeConfig[ProbeConfigKey.accessToken]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let accountId = config.probeConfig[ProbeConfigKey.accountId]?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let typed = codexAPIProbe {
                return try await typed.probe(
                    codexHomeDirectory: CodexProfilePaths.codexHome(from: config),
                    overrideAccessToken: accessToken,
                    accountId: accountId
                )
            }

            return try await apiProbe.probe()
        }
    }
}
