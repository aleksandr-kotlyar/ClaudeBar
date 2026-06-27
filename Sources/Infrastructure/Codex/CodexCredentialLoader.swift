import Foundation
import Domain

/// Codex OAuth credentials loaded from `~/.codex/auth.json`.
public struct CodexCredentialResult: @unchecked Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var accountId: String?
    public var lastRefresh: String?
    public var fullData: [String: Any]

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        accountId: String? = nil,
        lastRefresh: String? = nil,
        fullData: [String: Any]
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountId = accountId
        self.lastRefresh = lastRefresh
        self.fullData = fullData
    }
}

/// Loads Codex OAuth credentials from `~/.codex/auth.json`.
///
/// The auth file has the format:
/// ```json
/// {
///   "tokens": {
///     "access_token": "...",
///     "refresh_token": "...",
///     "account_id": "..."
///   },
///   "last_refresh": "2025-01-15T10:00:00.000Z"
/// }
/// ```
public struct CodexCredentialLoader: Sendable {
    private let homeDirectory: String
    private let codexHomeDirectory: String?

    /// Refresh age threshold: 8 days (matching Codex JS reference)
    private static let refreshAgeMs: Double = 8 * 24 * 60 * 60 * 1000

    public init(homeDirectory: String = NSHomeDirectory(), codexHomeDirectory: String? = nil) {
        self.homeDirectory = homeDirectory
        self.codexHomeDirectory = codexHomeDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The path to the auth file.
    public var authFilePath: String {
        if let codexHomeDirectory, !codexHomeDirectory.isEmpty {
            return (NSString(string: codexHomeDirectory).expandingTildeInPath as NSString)
                .appendingPathComponent("auth.json")
        }

        return (homeDirectory as NSString).appendingPathComponent(".codex/auth.json")
    }

    /// Loads credentials from `~/.codex/auth.json`.
    /// Returns nil if no valid OAuth credentials are found.
    /// Note: API key auth (`OPENAI_API_KEY`) is not supported for usage API.
    public func loadCredentials() -> CodexCredentialResult? {
        let path = authFilePath
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            // Check for OAuth tokens (not API key)
            guard let tokens = json["tokens"] as? [String: Any],
                  let accessToken = tokens["access_token"] as? String,
                  !accessToken.isEmpty else {
                return nil
            }

            let refreshToken = tokens["refresh_token"] as? String
            let accountId = tokens["account_id"] as? String
            let lastRefresh = json["last_refresh"] as? String

            return CodexCredentialResult(
                accessToken: accessToken,
                refreshToken: refreshToken,
                accountId: accountId,
                lastRefresh: lastRefresh,
                fullData: json
            )
        } catch {
            AppLog.credentials.error("Failed to load Codex credentials from file: \(error.localizedDescription)")
            return nil
        }
    }

    /// Checks if the token needs to be refreshed based on `last_refresh` date.
    /// Refresh is needed if `last_refresh` is nil or older than 8 days.
    public func needsRefresh(lastRefresh: String?) -> Bool {
        guard let lastRefresh else { return true }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lastDate = formatter.date(from: lastRefresh)

        if lastDate == nil {
            // Try without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            lastDate = formatter.date(from: lastRefresh)
        }

        guard let lastDate else { return true }

        let nowMs = Date().timeIntervalSince1970 * 1000
        let lastMs = lastDate.timeIntervalSince1970 * 1000
        return nowMs - lastMs > Self.refreshAgeMs
    }

    /// Saves updated credentials back to the auth file.
    public func saveCredentials(_ result: CodexCredentialResult) {
        var updatedData = result.fullData

        // Update the tokens section
        var tokens: [String: Any] = [
            "access_token": result.accessToken
        ]
        if let refreshToken = result.refreshToken {
            tokens["refresh_token"] = refreshToken
        }
        if let accountId = result.accountId {
            tokens["account_id"] = accountId
        }
        // Preserve any other token fields (like id_token)
        if let existingTokens = updatedData["tokens"] as? [String: Any] {
            for (key, value) in existingTokens {
                if tokens[key] == nil {
                    tokens[key] = value
                }
            }
        }
        updatedData["tokens"] = tokens

        if let lastRefresh = result.lastRefresh {
            updatedData["last_refresh"] = lastRefresh
        }

        let path = authFilePath
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: updatedData, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: URL(fileURLWithPath: path), options: .atomic)
            AppLog.credentials.info("Saved updated Codex credentials to file")
        } catch {
            AppLog.credentials.error("Failed to save Codex credentials to file: \(error.localizedDescription)")
        }
    }
}


/// Filesystem helper for per-account Codex CODEX_HOME directories.
public enum CodexProfileStorage {
    public static func ensureProfile(at codexHomeDirectory: String) throws {
        let expanded = NSString(string: codexHomeDirectory).expandingTildeInPath
        let directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try ensureFileCredentialStore(in: directoryURL)
    }

    private static func ensureFileCredentialStore(in codexHomeURL: URL) throws {
        let configURL = codexHomeURL.appendingPathComponent("config.toml")
        let key = "cli_auth_credentials_store"

        if FileManager.default.fileExists(atPath: configURL.path) {
            let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
            guard !existing.contains(key) else { return }

            let suffix = existing.hasSuffix("\n") || existing.isEmpty ? "" : "\n"
            let addition = "\(suffix)\(key) = \"file\"\n"
            try (existing + addition).write(to: configURL, atomically: true, encoding: .utf8)
            return
        }

        try "\(key) = \"file\"\n".write(to: configURL, atomically: true, encoding: .utf8)
    }
}
