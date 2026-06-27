import SwiftUI
import Domain
import Infrastructure

/// Codex provider configuration card for SettingsView.
struct CodexConfigCard: View {
    let monitor: QuotaMonitor

    @State private var settings = AppSettings.shared
    @State private var hasCredentials: Bool = false
    @State private var codexHomePathInput: String = ""
    @State private var showDeleteCredentialsAlert: Bool = false
    @Environment(\.appTheme) private var theme

    @State private var codexConfigExpanded: Bool = false
    @State private var codexProbeMode: CodexProbeMode = .rpc

    private var credentialLoader: CodexCredentialLoader {
        CodexCredentialLoader(
            codexHomePath: settings.codex.codexHomePath()
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: $codexConfigExpanded) {
            Divider()
                .background(theme.glassBorder)
                .padding(.vertical, 12)

            codexConfigForm
        } label: {
            codexConfigHeader
                .contentShape(.rect)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        codexConfigExpanded.toggle()
                    }
                }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.cardGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    theme.glassBorder, theme.glassBorder.opacity(0.5)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
        )
        .onAppear {
            codexProbeMode = settings.codex.codexProbeMode()
            codexHomePathInput = settings.codex.codexHomePath()
            refreshCredentialStatus()
        }
        .alert(
            "Delete Codex CLI credentials",
            isPresented: $showDeleteCredentialsAlert
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Codex CLI credentials…", role: .destructive) {
                deleteCliCredentials()
            }
        } message: {
            Text("This removes `auth.json` from the configured Codex home and requires re-authenticating in the Codex CLI. It does not change the current ClaudeBar probe mode.")
        }
    }

    private var codexConfigHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [theme.accentPrimary.opacity(0.2), theme.accentSecondary.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 28, height: 28)

                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accentPrimary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Configuration")
                    .font(.system(size: 14, weight: .bold, design: theme.fontDesign))
                    .foregroundStyle(theme.textPrimary)

                Text("Data fetching method")
                    .font(.system(size: 10, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer()
        }
    }

    private var codexConfigForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("DATA SOURCE")
                    .font(.system(size: 9, weight: .semibold, design: theme.fontDesign))
                    .foregroundStyle(theme.textSecondary)
                    .tracking(0.5)

                Picker("", selection: $codexProbeMode) {
                    ForEach(CodexProbeMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: codexProbeMode) { _, newValue in
                    setCodexProbeMode(newValue)
                    refreshCredentialStatus()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(codexProbeMode == .rpc ? theme.accentPrimary : theme.textTertiary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use Codex CLI (RPC)")
                            .font(.system(size: 10, weight: .semibold, design: theme.fontDesign))
                            .foregroundStyle(codexProbeMode == .rpc ? theme.textPrimary : theme.textSecondary)

                        Text("Fetch usage from codex app-server over JSON-RPC.")
                            .font(.system(size: 9, weight: .medium, design: theme.fontDesign))
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "network")
                        .font(.system(size: 10))
                        .foregroundStyle(codexProbeMode == .api ? theme.accentPrimary : theme.textTertiary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use Direct API")
                            .font(.system(size: 10, weight: .semibold, design: theme.fontDesign))
                            .foregroundStyle(codexProbeMode == .api ? theme.textPrimary : theme.textSecondary)

                        Text("Call usage API directly through the Codex OAuth credentials below.")
                            .font(.system(size: 9, weight: .medium, design: theme.fontDesign))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }

            Text("CODEX HOME")
                .font(.system(size: 9, weight: .semibold, design: theme.fontDesign))
                .foregroundStyle(theme.textSecondary)
                .tracking(0.5)

            TextField(
                "",
                text: $codexHomePathInput,
                prompt: Text("~/.codex").foregroundStyle(theme.textTertiary)
            )
            .font(.system(size: 12, weight: .medium, design: theme.fontDesign))
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.glassBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.glassBorder, lineWidth: 1)
                    )
            )
            .onChange(of: codexHomePathInput) { _, newValue in
                settings.codex.setCodexHomePath(newValue)
                refreshCredentialStatus()
            }

            Text("Leave empty to use default `~/.codex`, or set a custom directory or `$CODEX_HOME`.")
                .font(.system(size: 8, weight: .medium, design: theme.fontDesign))
                .foregroundStyle(theme.textTertiary)

            Divider()

            Text("CREDENTIALS")
                .font(.system(size: 9, weight: .semibold, design: theme.fontDesign))
                .foregroundStyle(theme.textSecondary)
                .tracking(0.5)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: hasCredentials ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(hasCredentials ? theme.statusHealthy : theme.statusWarning)

                Text(hasCredentials ? "OAuth credentials found" : "No OAuth credentials found")
                    .font(.system(size: 9, weight: .semibold, design: theme.fontDesign))
                    .foregroundStyle(hasCredentials ? theme.statusHealthy : theme.statusWarning)
            }

            if !hasCredentials {
                Text("Run `codex` in terminal to authenticate, then credentials will be available.")
                    .font(.system(size: 9, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.textTertiary)
            }

            Divider()

            if hasCredentials {
                Text("DANGER ZONE")
                    .font(.system(size: 9, weight: .semibold, design: theme.fontDesign))
                    .foregroundStyle(theme.statusWarning)
                    .tracking(0.5)

                Text("Use this only to remove `auth.json` from the configured Codex home.")
                    .font(.system(size: 8, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.textTertiary)

                Button {
                    showDeleteCredentialsAlert = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                        Text("Delete Codex CLI credentials…")
                            .font(.system(size: 9, weight: .semibold, design: theme.fontDesign))
                    }
                    .foregroundStyle(theme.statusWarning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.glassBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.statusWarning.opacity(0.5), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            }

            Divider()

            Text("PROBE STATUS")
                .font(.system(size: 9, weight: .semibold, design: theme.fontDesign))
                .foregroundStyle(theme.textSecondary)
                .tracking(0.5)

            Text("Refresh calls use \(codexProbeMode == .api ? "Direct API" : "Codex CLI (RPC)").")
                .font(.system(size: 8, weight: .medium, design: theme.fontDesign))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(2)

            Text("Switching modes only changes the probe source and does not delete `auth.json`.")
                .font(.system(size: 8, weight: .medium, design: theme.fontDesign))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(3)
        }
    }

    private func refreshCredentialStatus() {
        hasCredentials = credentialLoader.loadCredentials() != nil
    }

    private func setCodexProbeMode(_ mode: CodexProbeMode) {
        settings.codex.setCodexProbeMode(mode)
        codexProbeMode = mode
    }

    private func deleteCliCredentials() {
        _ = credentialLoader.disconnect()
        refreshCredentialStatus()
    }
}
