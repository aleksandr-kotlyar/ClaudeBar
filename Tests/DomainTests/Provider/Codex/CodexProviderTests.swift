import Testing
import Foundation
import Mockable
@testable import Domain

@Suite("CodexProvider Tests")
@MainActor
struct CodexProviderTests {

    private func makeSettingsRepository() -> MockProviderSettingsRepository {
        let mock = MockProviderSettingsRepository()
        given(mock).isEnabled(forProvider: .any, defaultValue: .any).willReturn(true)
        given(mock).isEnabled(forProvider: .any).willReturn(true)
        given(mock).setEnabled(.any, forProvider: .any).willReturn()
        return mock
    }

    // MARK: - Identity

    @Test
    func `codex provider has correct id`() {
        let settings = makeSettingsRepository()
        let codex = CodexProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(codex.id == "codex")
    }

    @Test
    func `codex provider has correct name`() {
        let settings = makeSettingsRepository()
        let codex = CodexProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(codex.name == "Codex")
    }

    @Test
    func `codex provider has correct cliCommand`() {
        let settings = makeSettingsRepository()
        let codex = CodexProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(codex.cliCommand == "codex")
    }

    @Test
    func `codex provider has dashboard URL pointing to openai`() {
        let settings = makeSettingsRepository()
        let codex = CodexProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(codex.dashboardURL != nil)
        #expect(codex.dashboardURL?.host?.contains("openai") == true)
    }

    @Test
    func `codex provider is enabled by default`() {
        let settings = makeSettingsRepository()
        let codex = CodexProvider(probe: MockUsageProbe(), settingsRepository: settings)
        #expect(codex.isEnabled == true)
    }

    // MARK: - Multi-Account

    @Test
    func `codex provider can switch between configured accounts`() {
        let settings = FakeCodexSettings()
        settings.setAccounts(
            [
                ProviderAccountConfig(accountId: "work", label: "Work"),
                ProviderAccountConfig(accountId: "personal", label: "Personal")
            ],
            forProvider: "codex"
        )
        settings.setActiveAccountId("work", forProvider: "codex")

        let codex = CodexProvider(
            probe: MockUsageProbe(),
            settingsRepository: settings
        )

        #expect(codex.activeAccount.accountId == "work")
        #expect(codex.switchAccount(to: "personal"))
        #expect(codex.activeAccount.accountId == "personal")
        #expect(settings.activeAccountId(forProvider: "codex") == "personal")
    }

    @Test
    func `codex provider deletes active account and auto-switches to remaining one`() {
        let settings = FakeCodexSettings()
        settings.setAccounts(
            [
                ProviderAccountConfig(accountId: "work", label: "Work"),
                ProviderAccountConfig(accountId: "personal", label: "Personal")
            ],
            forProvider: "codex"
        )
        settings.setActiveAccountId("work", forProvider: "codex")

        let codex = CodexProvider(
            probe: MockUsageProbe(),
            settingsRepository: settings
        )

        #expect(codex.removeAccount("work"))
        #expect(codex.accounts.count == 1)
        #expect(codex.activeAccount.accountId == "personal")
        #expect(settings.activeAccountId(forProvider: "codex") == "personal")
    }

    @Test
    func `codex provider does not delete last remaining account`() {
        let settings = FakeCodexSettings()
        settings.setAccounts(
            [ProviderAccountConfig(accountId: "work", label: "Work")],
            forProvider: "codex"
        )
        settings.setActiveAccountId("work", forProvider: "codex")

        let codex = CodexProvider(
            probe: MockUsageProbe(),
            settingsRepository: settings
        )

        #expect(codex.accounts.count == 1)
        #expect(codex.removeAccount("work") == false)
        #expect(codex.accounts.count == 1)
        #expect(codex.activeAccount.accountId == "work")
    }

    @Test
    func `codex provider refreshAccount fails for unknown account`() async throws {
        let settings = FakeCodexSettings()
        settings.setAccounts(
            [ProviderAccountConfig(accountId: "work", label: "Work")],
            forProvider: "codex"
        )

        let mockProbe = MockUsageProbe()
        let codex = CodexProvider(
            probe: mockProbe,
            settingsRepository: settings
        )

        await #expect(throws: ProbeError.executionFailed("Account not found")) {
            _ = try await codex.refreshAccount("missing")
        }
    }

    @Test
    func `codex provider updates snapshot when refreshing account`() async throws {
        let settings = FakeCodexSettings()
        settings.setAccounts(
            [ProviderAccountConfig(accountId: "work", label: "Work")],
            forProvider: "codex"
        )
        settings.setActiveAccountId("work", forProvider: "codex")

        let snapshot = UsageSnapshot(
            providerId: "codex",
            quotas: [UsageQuota(percentRemaining: 72, quotaType: .session, providerId: "codex")],
            capturedAt: Date()
        )

        let probe = MockUsageProbe()
        given(probe).isAvailable().willReturn(true)
        given(probe).probe().willReturn(snapshot)

        let codex = CodexProvider(
            probe: probe,
            settingsRepository: settings
        )

        let refreshed = try await codex.refreshAccount("work")

        #expect(refreshed.quotas.count == 1)
        #expect(refreshed.quotas[0].percentRemaining == 72)
        #expect(codex.accountSnapshots["work"]?.quotas.first?.percentRemaining == 72)
        #expect(codex.snapshot?.quotas.first?.percentRemaining == 72)
    }
}

private final class FakeCodexSettings: MultiAccountSettingsRepository, @unchecked Sendable {
    private var enabledByProvider: [String: Bool] = [:]
    private var customCardURLs: [String: String] = [:]
    private var accountsByProvider: [String: [ProviderAccountConfig]] = [:]
    private var activeAccountIdByProvider: [String: String?] = [:]

    init() {}

    func isEnabled(forProvider id: String) -> Bool {
        isEnabled(forProvider: id, defaultValue: true)
    }

    func isEnabled(forProvider id: String, defaultValue: Bool) -> Bool {
        enabledByProvider[id] ?? defaultValue
    }

    func setEnabled(_ enabled: Bool, forProvider id: String) {
        enabledByProvider[id] = enabled
    }

    func customCardURL(forProvider id: String) -> String? {
        customCardURLs[id]
    }

    func setCustomCardURL(_ url: String?, forProvider id: String) {
        if let url {
            customCardURLs[id] = url
        } else {
            customCardURLs.removeValue(forKey: id)
        }
    }

    func accounts(forProvider id: String) -> [ProviderAccountConfig] {
        accountsByProvider[id] ?? []
    }

    func setAccounts(_ configs: [ProviderAccountConfig], forProvider id: String) {
        accountsByProvider[id] = configs
    }

    func addAccount(_ config: ProviderAccountConfig, forProvider id: String) {
        var current = accounts(forProvider: id)
        guard !current.contains(where: { $0.accountId == config.accountId }) else { return }
        current.append(config)
        setAccounts(current, forProvider: id)
    }

    func removeAccount(accountId: String, forProvider id: String) {
        let remaining = accounts(forProvider: id).filter { $0.accountId != accountId }
        setAccounts(remaining, forProvider: id)

        if activeAccountId(forProvider: id) == accountId, let first = remaining.first {
            setActiveAccountId(first.accountId, forProvider: id)
        }
    }

    func updateAccount(_ config: ProviderAccountConfig, forProvider id: String) {
        var current = accounts(forProvider: id)
        if let idx = current.firstIndex(where: { $0.accountId == config.accountId }) {
            current[idx] = config
        } else {
            current.append(config)
        }
        setAccounts(current, forProvider: id)
    }

    func activeAccountId(forProvider id: String) -> String? {
        activeAccountIdByProvider[id] ?? nil
    }

    func setActiveAccountId(_ accountId: String?, forProvider id: String) {
        activeAccountIdByProvider[id] = accountId
    }
}
