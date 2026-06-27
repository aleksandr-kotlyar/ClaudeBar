import SwiftUI
import AppKit
import Domain
import Infrastructure

/// Settings section for multi-account management.
///
/// For Codex, each app account maps to an internal isolated CODEX_HOME. The
/// filesystem path is intentionally not shown here; users see the profile label
/// and the OpenAI email/plan returned by Codex after login.
struct AccountManagementCard: View {
    let provider: any MultiAccountProvider
    let monitor: QuotaMonitor

    @Environment(\.appTheme) private var theme
    @State private var isShowingAddSheet = false
    @State private var pendingDeleteAccountId: String?
    @State private var accountLabelInput = ""
    @State private var accountTokenInput = ""
    @State private var accountIdInput = ""
    @State private var codexLoginStates: [String: CodexLoginState] = [:]
    @State private var codexLoginTasks: [String: Task<Void, Never>] = [:]
    @State private var addAccountError: String?

    private var codexProvider: CodexProvider? {
        provider as? CodexProvider
    }

    private var isCodexProvider: Bool {
        provider.id == "codex"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ACCOUNTS")
                .font(.system(size: 9, weight: .semibold, design: theme.fontDesign))
                .foregroundStyle(theme.textSecondary)
                .tracking(0.5)

            if provider.accounts.isEmpty {
                Text("No accounts configured.")
                    .font(.system(size: 10, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.textTertiary)
            } else {
                ForEach(provider.accounts, id: \.id) { account in
                    accountRow(account)
                }
            }

            if provider.accounts.count == 1 {
                Text("At least one account is required.")
                    .font(.system(size: 8, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.textTertiary)
            }

            if isShowingAddSheet {
                addAccountForm
            } else {
                Divider()
                    .background(theme.glassBorder)
                    .padding(.vertical, 4)

                addAccountButton
            }

            if let addAccountError {
                Text(addAccountError)
                    .font(.system(size: 8, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.statusWarning)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .onDisappear {
            codexLoginTasks.values.forEach { $0.cancel() }
            codexLoginTasks.removeAll()
        }
    }

    // MARK: - Account Row

    private func accountRow(_ account: ProviderAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                avatar(for: account)

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .font(.system(size: 12, weight: .medium, design: theme.fontDesign))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    accountSubtitle(account)
                }

                Spacer()

                if let snapshot = provider.accountSnapshots[account.accountId] {
                    Circle()
                        .fill(theme.statusColor(for: snapshot.overallStatus))
                        .frame(width: 8, height: 8)
                }

                activeOrUseButton(for: account)

                if isCodexProvider {
                    Button("Login") {
                        startCodexDeviceCodeLogin(for: account)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isCodexLoginInProgress(for: account.accountId))
                }

                Button("Refresh") {
                    refreshAccount(account.accountId)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button {
                    attemptDeleteAccount(account)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(provider.accounts.count > 1 ? theme.textTertiary : theme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(provider.accounts.count <= 1)
            }

            if let state = codexLoginStates[account.accountId] {
                codexLoginStateView(state, accountId: account.accountId)
                    .padding(.leading, 34)
            }

            if pendingDeleteAccountId == account.accountId {
                inlineDeleteConfirmation(for: account)
                    .padding(.leading, 34)
            }
        }
        .padding(.vertical, 4)
    }

    private func avatar(for account: ProviderAccount) -> some View {
        ZStack {
            Circle()
                .fill(account.accountId == provider.activeAccount.accountId ? theme.accentPrimary : theme.glassBackground)
                .frame(width: 24, height: 24)

            Text(account.initialLetter)
                .font(.system(size: 10, weight: .bold, design: theme.fontDesign))
                .foregroundStyle(account.accountId == provider.activeAccount.accountId ? .white : theme.textSecondary)
        }
    }

    @ViewBuilder
    private func accountSubtitle(_ account: ProviderAccount) -> some View {
        let pieces = [account.email, account.organization]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }

        if pieces.isEmpty {
            Text(isCodexProvider ? "Codex profile" : "Profile")
                .font(.system(size: 9, weight: .medium, design: theme.fontDesign))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
        } else {
            Text(pieces.joined(separator: " · "))
                .font(.system(size: 9, weight: .medium, design: theme.fontDesign))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func activeOrUseButton(for account: ProviderAccount) -> some View {
        if account.accountId == provider.activeAccount.accountId {
            Text("Active")
                .font(.system(size: 8, weight: .medium, design: theme.fontDesign))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(theme.accentPrimary.opacity(0.15)))
        } else {
            Button {
                let switched = provider.switchAccount(to: account.accountId)
                guard switched else { return }
                Task { await monitor.refresh(providerId: provider.id) }
            } label: {
                Text("Use")
                    .font(.system(size: 8, weight: .medium, design: theme.fontDesign))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().stroke(theme.accentPrimary.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private func inlineDeleteConfirmation(for account: ProviderAccount) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Delete this profile?")
                    .font(.system(size: 8, weight: .semibold, design: theme.fontDesign))
                    .foregroundStyle(theme.textPrimary)
                Text("Credentials folder is left on disk.")
                    .font(.system(size: 8, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer()

            Button("Cancel") {
                pendingDeleteAccountId = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            Button("Delete", role: .destructive) {
                deleteAccount(account.accountId)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
        }
    }

    // MARK: - Device-code login UI

    @ViewBuilder
    private func codexLoginStateView(_ state: CodexLoginState, accountId: String) -> some View {
        if state.isLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Starting device-code login…")
                    .font(.system(size: 9, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.textSecondary)
            }
        } else if let userCode = state.userCode,
                  let verificationURL = state.verificationURL {
            VStack(alignment: .leading, spacing: 6) {
                Text("Open the auth page and enter this code:")
                    .font(.system(size: 9, weight: .semibold, design: theme.fontDesign))
                    .foregroundStyle(theme.textSecondary)

                Text(userCode)
                    .font(.system(size: 13, weight: .bold, design: theme.fontDesign).monospacedDigit())
                    .foregroundStyle(theme.textPrimary)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    Button("Copy code") { copyToClipboard(userCode) }
                    Button("Copy URL") { copyToClipboard(verificationURL) }

                    if let url = URL(string: verificationURL) {
                        Button("Open private auth window") { CodexAuthPageOpener.openIsolatedWindow(url: url) }
                    }

                    Button("Cancel", role: .destructive) { cancelCodexLogin(for: accountId) }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        } else if let errorMessage = state.errorMessage {
            VStack(alignment: .leading, spacing: 6) {
                Text(errorMessage)
                    .font(.system(size: 9, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.statusWarning)
                    .textSelection(.enabled)

                if let details = state.errorDetails {
                    Button("Copy details") { copyToClipboard(details) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }
        }
    }

    // MARK: - Add Account

    private var addAccountButton: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 12, weight: .semibold))

            Text("Add account")
                .font(.system(size: 11, weight: .medium, design: theme.fontDesign))
        }
        .foregroundStyle(theme.accentPrimary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.accentPrimary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4]))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            isShowingAddSheet = true
            pendingDeleteAccountId = nil
            accountLabelInput = ""
            accountTokenInput = ""
            accountIdInput = ""
            addAccountError = nil
        }
    }

    private var addAccountForm: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(isCodexProvider ? "Add Codex profile" : "Add account")
                    .font(.system(size: 14, weight: .semibold, design: theme.fontDesign))
                    .foregroundStyle(theme.textPrimary)

                Text("Profile name")
                    .font(.system(size: 10, weight: .semibold, design: theme.fontDesign))
                    .foregroundStyle(theme.textSecondary)

                TextField("", text: $accountLabelInput, prompt: Text(nextProfileLabel()).foregroundStyle(theme.textTertiary))
                    .textFieldStyle(.roundedBorder)

                if isCodexProvider {
                    Text("This creates an isolated local Codex profile. Sign in from the new row after saving.")
                        .font(.system(size: 9, weight: .medium, design: theme.fontDesign))
                        .foregroundStyle(theme.textTertiary)
                } else {
                    Text("API token")
                        .font(.system(size: 10, weight: .semibold, design: theme.fontDesign))
                        .foregroundStyle(theme.textSecondary)

                    SecureField("", text: $accountTokenInput, prompt: Text("access token").foregroundStyle(theme.textTertiary))
                        .textFieldStyle(.roundedBorder)

                    Text("Account ID")
                        .font(.system(size: 10, weight: .semibold, design: theme.fontDesign))
                        .foregroundStyle(theme.textSecondary)

                    TextField("", text: $accountIdInput, prompt: Text("Optional").foregroundStyle(theme.textTertiary))
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 8) {
                Button("Cancel") { closeAddAccountSheet() }
                    .buttonStyle(.bordered)

                Button("Save") { saveAccount() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isCodexProvider && trimmedToken.isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.cardGradient)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.glassBorder, lineWidth: 1))
        )
        .transition(.opacity)
    }

    private func closeAddAccountSheet() {
        isShowingAddSheet = false
        pendingDeleteAccountId = nil
        addAccountError = nil
        accountLabelInput = ""
        accountTokenInput = ""
        accountIdInput = ""
    }

    // MARK: - Actions

    private func startCodexDeviceCodeLogin(for account: ProviderAccount) {
        guard let codexProvider else { return }

        let accountId = account.accountId
        guard !isCodexLoginInProgress(for: accountId) else { return }

        let codexHome = codexProvider.codexHomeDirectory(for: accountId)
        codexLoginTasks[accountId]?.cancel()
        codexLoginStates[accountId] = .init(isLoading: true)
        addAccountError = nil

        let task = Task {
            do {
                let session = try await CodexDeviceCodeLoginService.start(codexHomeDirectory: codexHome)

                await MainActor.run {
                    codexLoginStates[accountId] = .init(
                        isLoading: false,
                        userCode: session.userCode,
                        verificationURL: session.verificationURL
                    )
                }

                try await withTaskCancellationHandler(
                    operation: {
                        try await session.waitForCompletion()
                        let accountRead = try await session.readAccount()

                        await MainActor.run {
                            codexProvider.cacheLoginMetadata(
                                for: accountId,
                                email: accountRead.email,
                                plan: accountRead.plan
                            )
                            codexLoginStates.removeValue(forKey: accountId)
                        }

                        do {
                            _ = try await codexProvider.refreshAccount(accountId)
                        } catch {
                            // The account is logged in even if the immediate usage refresh fails.
                        }

                        await monitor.refresh(providerId: provider.id)
                    },
                    onCancel: { session.cancel() }
                )
            } catch {
                if let error = error as? CodexDeviceCodeLoginError, error == .cancelled {
                    await MainActor.run { codexLoginStates.removeValue(forKey: accountId) }
                } else {
                    let details = codexLoginErrorDetails(for: error)
                    await MainActor.run {
                        codexLoginStates[accountId] = .init(
                            errorMessage: details.message,
                            errorDetails: details.details
                        )
                    }
                }
            }

            await MainActor.run {
                codexLoginTasks.removeValue(forKey: accountId)
            }
        }

        codexLoginTasks[accountId] = task
    }

    private func cancelCodexLogin(for accountId: String) {
        codexLoginTasks[accountId]?.cancel()
        codexLoginTasks[accountId] = nil
        codexLoginStates.removeValue(forKey: accountId)
    }

    private func isCodexLoginInProgress(for accountId: String) -> Bool {
        guard let state = codexLoginStates[accountId] else { return false }
        return state.isLoading || (state.userCode != nil && state.verificationURL != nil)
    }

    private func refreshAccount(_ accountId: String) {
        Task {
            do {
                _ = try await provider.refreshAccount(accountId)
            } catch {
                // The provider stores per-account errors; keep the settings popover usable.
            }
        }
    }

    private func attemptDeleteAccount(_ account: ProviderAccount) {
        guard provider.accounts.count > 1 else { return }
        pendingDeleteAccountId = account.accountId
    }

    private func deleteAccount(_ accountId: String) {
        guard provider.accounts.count > 1 else { return }
        cancelCodexLogin(for: accountId)
        guard provider.removeAccount(accountId) else { return }
        pendingDeleteAccountId = nil

        Task { await monitor.refresh(providerId: provider.id) }
    }

    private func saveAccount() {
        addAccountError = nil
        if !isCodexProvider && trimmedToken.isEmpty {
            addAccountError = "API token is required."
            return
        }

        let label = uniqueLabel()
        let accountId = normalizedAccountId(base: label)

        var probeConfig: [String: String] = [:]
        if isCodexProvider {
            probeConfig[CodexProfilePaths.probeConfigKey] = CodexProfilePaths.defaultCodexHome(for: accountId)
        } else {
            if !trimmedToken.isEmpty {
                probeConfig[ProbeConfigKey.accessToken] = trimmedToken
            }
            if !trimmedOptionalAccountId.isEmpty {
                probeConfig[ProbeConfigKey.accountId] = trimmedOptionalAccountId
            }
        }

        let config = ProviderAccountConfig(accountId: accountId, label: label, probeConfig: probeConfig)
        let added = provider.addAccount(config)
        guard added else {
            addAccountError = "Cannot add account yet. Check whether an account with the same ID already exists."
            return
        }

        closeAddAccountSheet()
    }

    // MARK: - Helpers

    private func codexLoginErrorDetails(for error: Error) -> (message: String, details: String?) {
        if let codexError = error as? CodexDeviceCodeLoginError {
            switch codexError {
            case .unsupportedDeviceCodeLogin:
                return (
                    "Device-code login is unavailable. Update Codex CLI and enable device-code auth in ChatGPT settings.",
                    codexError.localizedDescription
                )
            case let .parseFailure(message),
                 let .requestFailed(message),
                 let .loginFailed(message),
                 let .transportFailed(message):
                return ("Codex login failed. Copy details for diagnostics.", message)
            case .timedOut:
                return ("Codex login timed out. Start login again and enter the code before it expires.", codexError.localizedDescription)
            case .cancelled:
                return ("", nil)
            }
        }

        let message = error.localizedDescription
        return (message.isEmpty ? "Codex login failed. Try again." : "Codex login failed. Copy details for diagnostics.", message.isEmpty ? nil : message)
    }

    private func copyToClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private var trimmedToken: String {
        accountTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedOptionalAccountId: String {
        accountIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func uniqueLabel() -> String {
        let base = accountLabelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            return nextProfileLabel()
        }
        guard isLabelUnique(base) else {
            return nextAvailableLabel(prefix: base, startSuffix: 2)
        }
        return base
    }

    private func nextProfileLabel() -> String {
        nextAvailableLabel(prefix: isCodexProvider ? "Profile" : "Account", startSuffix: provider.accounts.count + 1)
    }

    private func nextAvailableLabel(prefix: String, startSuffix: Int) -> String {
        var suffix = max(1, startSuffix)
        while true {
            let candidate = "\(prefix) \(suffix)"
            if !isLabelUsed(candidate) { return candidate }
            suffix += 1
        }
    }

    private func isLabelUsed(_ label: String) -> Bool {
        provider.accounts.contains { $0.label.caseInsensitiveCompare(label) == .orderedSame }
    }

    private func isLabelUnique(_ label: String) -> Bool {
        !isLabelUsed(label)
    }

    private func normalizedAccountId(base: String) -> String {
        let compacted = base
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { char in char.isLetter || char.isNumber || char == "-" || char == "_" }

        let baseId = compacted.isEmpty ? UUID().uuidString : compacted
        var uniqueId = baseId
        var suffix = 2
        while provider.accounts.contains(where: { $0.accountId == uniqueId }) {
            uniqueId = "\(baseId)-\(suffix)"
            suffix += 1
        }
        return uniqueId
    }

    private enum ProbeConfigKey {
        static let connectionMode = CodexAccountConfigKey.connectionMode
        static let codexHomePath = CodexAccountConfigKey.codexHomePath
        static let accessToken = CodexAccountConfigKey.accessToken
        static let accountId = CodexAccountConfigKey.accountId
    }

    private struct CodexLoginState: Equatable {
        var isLoading = false
        var userCode: String?
        var verificationURL: String?
        var errorMessage: String?
        var errorDetails: String?
    }
}
