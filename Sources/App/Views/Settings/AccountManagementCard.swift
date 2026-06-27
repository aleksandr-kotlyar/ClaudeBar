import SwiftUI
import Domain

/// Settings section for multi-account management.
///
/// The control lives inside provider config cards and keeps one active account
/// snapshot in the parent provider for compatibility with the existing UI model.
struct AccountManagementCard: View {
    let provider: any MultiAccountProvider
    let monitor: QuotaMonitor

    @Environment(\.appTheme) private var theme
    @State private var isShowingAddSheet = false
    @State private var pendingDeleteAccountId: String?
    @State private var shouldConfirmDelete = false
    @State private var accountLabelInput = ""
    @State private var accountTokenInput = ""
    @State private var accountIdInput = ""

    @State private var showDeleteHint = false
    @State private var addAccountError: String?

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

            Divider()
                .background(theme.glassBorder)
                .padding(.vertical, 4)

            addAccountButton

            if provider.accounts.count == 1 {
                Text("At least one account is required.")
                    .font(.system(size: 8, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.textTertiary)
            }

            if showDeleteHint, let accountId = pendingDeleteAccountId {
                Text("Deleting \(displayName(for: accountId)) will switch to another account automatically.")
                    .font(.system(size: 8, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.textTertiary)
                    .transition(.opacity)
            }

            if let addAccountError {
                Text(addAccountError)
                    .font(.system(size: 8, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.statusWarning)
            }

            if isShowingAddSheet {
                addAccountForm
            }
        }
        .padding(.vertical, 2)
        .alert(
            "Delete account",
            isPresented: .init(
                get: { pendingDeleteAccountId != nil && shouldConfirmDelete },
                set: { isPresented in
                    if !isPresented {
                        pendingDeleteAccountId = nil
                        shouldConfirmDelete = false
                        showDeleteHint = false
                    }
                }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let accountId = pendingDeleteAccountId {
                    deleteAccount(accountId)
                }
                pendingDeleteAccountId = nil
                shouldConfirmDelete = false
                showDeleteHint = false
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteAccountId = nil
                shouldConfirmDelete = false
                showDeleteHint = false
            }
        } message: {
            if let accountId = pendingDeleteAccountId {
                Text("Delete \"\(displayName(for: accountId))\"? This will switch to another account automatically.")
            } else {
                Text("Delete this account?")
            }
        }
    }

    // MARK: - Account Row

    private func accountRow(_ account: ProviderAccount) -> some View {
        HStack(spacing: 10) {
            // Avatar
            ZStack {
                Circle()
                    .fill(
                        account.accountId == provider.activeAccount.accountId
                            ? theme.accentPrimary
                            : theme.glassBackground
                    )
                    .frame(width: 24, height: 24)

                Text(account.initialLetter)
                    .font(.system(size: 10, weight: .bold, design: theme.fontDesign))
                    .foregroundStyle(
                        account.accountId == provider.activeAccount.accountId
                            ? .white
                            : theme.textSecondary
                    )
            }

            // Account info
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.system(size: 12, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                if let email = account.email {
                    Text(email)
                        .font(.system(size: 9, weight: .medium, design: theme.fontDesign))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let snapshot = provider.accountSnapshots[account.accountId] {
                let status = snapshot.overallStatus
                Circle()
                    .fill(theme.statusColor(for: status))
                    .frame(width: 8, height: 8)
            }

            if account.accountId == provider.activeAccount.accountId {
                Text("Active")
                    .font(.system(size: 8, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(theme.accentPrimary.opacity(0.15))
                    )
            } else {
                Button {
                    let switched = provider.switchAccount(to: account.accountId)
                    guard switched else { return }
                    Task {
                        await monitor.refresh(providerId: provider.id)
                    }
                } label: {
                    Text("Use")
                        .font(.system(size: 8, weight: .medium, design: theme.fontDesign))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .stroke(theme.accentPrimary.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            Button {
                attemptDeleteAccount(account)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(
                        provider.accounts.count > 1 ? theme.textTertiary : theme.textSecondary
                    )
            }
            .buttonStyle(.plain)
            .disabled(provider.accounts.count <= 1)
        }
        .padding(.vertical, 4)
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
            accountLabelInput = ""
            accountTokenInput = ""
            accountIdInput = ""
            addAccountError = nil
        }
    }

    private var addAccountForm: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add Codex account")
                    .font(.system(size: 14, weight: .semibold, design: theme.fontDesign))
                    .foregroundStyle(theme.textPrimary)

                Text("Name")
                    .font(.system(size: 10, weight: .semibold, design: theme.fontDesign))
                    .foregroundStyle(theme.textSecondary)

                TextField("", text: $accountLabelInput, prompt: Text("Work account").foregroundStyle(theme.textTertiary))
                    .textFieldStyle(.roundedBorder)

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

            HStack(spacing: 8) {
                Button("Cancel") {
                    closeAddAccountSheet()
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    saveAccount()
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedToken.isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.cardGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(theme.glassBorder, lineWidth: 1)
                )
        )
        .transition(.opacity)
    }

    private func closeAddAccountSheet() {
        isShowingAddSheet = false
        addAccountError = nil
        accountLabelInput = ""
        accountTokenInput = ""
        accountIdInput = ""
    }

    private func attemptDeleteAccount(_ account: ProviderAccount) {
        guard provider.accounts.count > 1 else { return }

        if account.accountId == provider.activeAccount.accountId {
            pendingDeleteAccountId = account.accountId
            shouldConfirmDelete = true
            showDeleteHint = true
        } else {
            deleteAccount(account.accountId)
        }
    }

    private func deleteAccount(_ accountId: String) {
        guard provider.removeAccount(accountId) else { return }

        Task {
            await monitor.refresh(providerId: provider.id)
        }
    }

    private func saveAccount() {
        addAccountError = nil
        let label = uniqueLabel()
        let accountId = normalizedAccountId(base: label)

        var probeConfig: [String: String] = [ProbeConfigKey.accessToken: trimmedToken]

        if !trimmedOptionalAccountId.isEmpty {
            probeConfig[ProbeConfigKey.accountId] = trimmedOptionalAccountId
        }

        let config = ProviderAccountConfig(
            accountId: accountId,
            label: label,
            probeConfig: probeConfig
        )

        let added = provider.addAccount(config)
        guard added else {
            addAccountError = "Cannot add account yet. Check whether an account with the same ID already exists."
            return
        }

        _ = provider.switchAccount(to: accountId)
        closeAddAccountSheet()

        Task {
            await monitor.refresh(providerId: provider.id)
        }
    }

    private func displayName(for accountId: String) -> String {
        provider.accounts
            .first(where: { $0.accountId == accountId })?
            .displayName ?? accountId
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
            return nextAvailableLabel(prefix: "Account", startSuffix: 2)
        }

        guard isLabelUnique(base) else {
            return nextAvailableLabel(prefix: base, startSuffix: 2)
        }

        return base
    }

    private func nextAvailableLabel(prefix: String, startSuffix: Int) -> String {
        var suffix = startSuffix
        while true {
            let candidate = "\(prefix) \(suffix)"
            if !isLabelUsed(candidate) {
                return candidate
            }
            suffix += 1
        }
    }

    private func isLabelUsed(_ label: String) -> Bool {
        provider.accounts.contains {
            $0.label.caseInsensitiveCompare(label) == .orderedSame
        }
    }

    private func isLabelUnique(_ label: String) -> Bool {
        !isLabelUsed(label)
    }

    private func normalizedAccountId(base: String) -> String {
        let compacted = base
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { char in
                char.isLetter || char.isNumber || char == "-" || char == "_"
            }

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
        static let accessToken = "accessToken"
        static let accountId = "accountId"
    }
}
