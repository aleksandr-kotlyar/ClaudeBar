import Foundation

/// How a Codex account is connected to ClaudeBar.
///
/// This is intentionally separate from `CodexProbeMode` (RPC vs direct API):
/// connection mode describes where credentials/profile state come from.
public enum CodexConnectionMode: String, Codable, CaseIterable, Sendable, Hashable {
    /// Use the normal Codex CLI / IDE / Codex.app session.
    /// ClaudeBar must not set CODEX_HOME or create/copy profile files.
    case existingSession

    /// Use a user-selected Codex profile folder as CODEX_HOME.
    /// The expected auth file is `<CODEX_HOME>/auth.json`.
    case customCodexHome

    /// Use a user-selected profile folder and optionally start device-code login.
    /// Probing still uses the selected CODEX_HOME after login.
    case deviceCodeProfile

    /// Use manually supplied API token/account ID without Codex CLI auth.
    case manualApiToken

    public var displayName: String {
        switch self {
        case .existingSession:
            return "Existing Codex session"
        case .customCodexHome:
            return "Custom Codex profile folder"
        case .deviceCodeProfile:
            return "Device-code profile"
        case .manualApiToken:
            return "Manual API token"
        }
    }

    public var shortLabel: String {
        switch self {
        case .existingSession:
            return "Existing session"
        case .customCodexHome:
            return "Custom CODEX_HOME"
        case .deviceCodeProfile:
            return "Device code"
        case .manualApiToken:
            return "Manual token"
        }
    }

    public var description: String {
        switch self {
        case .existingSession:
            return "Use existing Codex CLI / IDE session"
        case .customCodexHome:
            return "Use a selected CODEX_HOME folder without copying auth files"
        case .deviceCodeProfile:
            return "Start optional device-code login for a selected profile folder"
        case .manualApiToken:
            return "Use manually entered API token and optional account ID"
        }
    }
}

/// Optional capability for a Codex API probe that can use manual tokens or a selected CODEX_HOME.
public protocol CodexAPIProbing: Sendable {
    func probe(overrideAccessToken: String?, accountId: String?, codexHomePath: String?) async throws -> UsageSnapshot
}

/// Optional capability for a Codex API probe that can check credentials in a selected CODEX_HOME.
public protocol CodexCredentialAvailabilityChecking: Sendable {
    func hasCredentials(codexHomePath: String?) -> Bool
}


/// Shared probeConfig keys for Codex account configuration.
public enum CodexAccountConfigKey {
    public static let connectionMode = "connectionMode"
    public static let codexHomePath = "codexHomePath"
    public static let accessToken = "accessToken"
    public static let accountId = "accountId"
}

public extension ProviderAccountConfig {
    /// Best-effort Codex connection mode for legacy and current account configs.
    ///
    /// Legacy configs did not store `connectionMode`. We infer manual token when an
    /// access token exists, custom profile when CODEX_HOME exists, and otherwise use
    /// the normal existing Codex session.
    var codexConnectionMode: CodexConnectionMode {
        if let raw = probeConfig[CodexAccountConfigKey.connectionMode],
           let mode = CodexConnectionMode(rawValue: raw) {
            return mode
        }

        if let token = probeConfig[CodexAccountConfigKey.accessToken],
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .manualApiToken
        }

        if let codexHome = probeConfig[CodexAccountConfigKey.codexHomePath],
           !codexHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .customCodexHome
        }

        return .existingSession
    }

    var codexHomePath: String? {
        guard let path = probeConfig[CodexAccountConfigKey.codexHomePath]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return path
    }

    var codexAccessToken: String? {
        guard let token = probeConfig[CodexAccountConfigKey.accessToken]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    var codexAccountId: String? {
        guard let accountId = probeConfig[CodexAccountConfigKey.accountId]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountId.isEmpty else {
            return nil
        }
        return accountId
    }
}
