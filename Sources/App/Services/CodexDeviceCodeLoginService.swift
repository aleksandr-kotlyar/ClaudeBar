import Foundation
import AppKit
import WebKit
import Infrastructure

struct CodexDeviceCodeLoginStart: Equatable {
    let loginId: String
    let userCode: String
    let verificationURL: String
}

struct CodexAccountReadResult: Equatable {
    let email: String?
    let plan: String?
}

enum CodexDeviceCodeLoginError: LocalizedError, Sendable, Equatable {
    case unsupportedDeviceCodeLogin
    case parseFailure(String)
    case requestFailed(String)
    case loginFailed(String)
    case timedOut
    case transportFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedDeviceCodeLogin:
            return "Codex login started with device code is not supported by this client version"
        case let .parseFailure(message),
             let .requestFailed(message),
             let .loginFailed(message),
             let .transportFailed(message):
            return message
        case .timedOut:
            return "Codex login attempt timed out"
        case .cancelled:
            return "Codex login was canceled"
        }
    }
}

final class CodexDeviceCodeLoginSession: @unchecked Sendable {
    private let transport: RPCTransport
    private var nextRequestID: Int = 1

    fileprivate(set) var loginId: String
    fileprivate(set) var userCode: String
    fileprivate(set) var verificationURL: String

    init(
        transport: RPCTransport,
        loginId: String,
        userCode: String,
        verificationURL: String
    ) {
        self.transport = transport
        self.loginId = loginId
        self.userCode = userCode
        self.verificationURL = verificationURL
    }

    deinit {
        cancel()
    }

    func cancel() {
        transport.close()
    }

    func waitForCompletion(timeout: TimeInterval = 300) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            if Task.isCancelled {
                throw CodexDeviceCodeLoginError.cancelled
            }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw CodexDeviceCodeLoginError.timedOut
            }

            let payload = try await receiveMessage(within: remaining)

            guard let method = payload["method"] as? String,
                  method == "account/login/completed" else {
                continue
            }

            guard let params = (payload["params"] as? [String: Any]) ?? (payload["result"] as? [String: Any]) else {
                continue
            }

            let eventLoginId = CodexDeviceCodeLoginService.firstNonEmptyString(
                in: params,
                keys: ["loginId", "login_id", "id"]
            )

            guard eventLoginId == loginId else {
                continue
            }

            if let status = CodexDeviceCodeLoginService.firstNonEmptyString(
                in: params,
                keys: ["status", "state", "result"]
            )?.lowercased() {
                switch status {
                case "done", "completed", "success", "authenticated", "authorized", "ok":
                    return
                case "failed", "error", "canceled", "cancelled", "expired":
                    let message = CodexDeviceCodeLoginService.firstNonEmptyString(
                        in: params,
                        keys: ["error", "message", "reason"]
                    ) ?? "Device-code login failed"
                    throw CodexDeviceCodeLoginError.loginFailed(message)
                default:
                    break
                }
            }

            if let success = CodexDeviceCodeLoginService.firstNonEmptyBool(
                in: params,
                keys: ["success", "authenticated"]
            ) {
                if success {
                    return
                }

                let message = CodexDeviceCodeLoginService.firstNonEmptyString(
                    in: params,
                    keys: ["error", "message", "reason"]
                ) ?? "Device-code login failed"
                throw CodexDeviceCodeLoginError.loginFailed(message)
            }
        }
    }

    func readAccount() async throws -> CodexAccountReadResult {
        let result = try await request(method: "account/read", params: nil)
        let email = CodexDeviceCodeLoginService.email(from: result)
        let plan = CodexDeviceCodeLoginService.plan(from: result)
        return CodexAccountReadResult(email: email, plan: plan)
    }

    private func request(method: String, params: [String: Any]?) async throws -> [String: Any] {
        nextRequestID += 1
        let requestID = nextRequestID
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": params ?? [:]
        ]

        try sendPayload(payload)

        while true {
            let payload = try await receiveMessage(within: 60)

            guard let responseID = payload["id"] as? Int,
                  responseID == requestID else {
                continue
            }

            if let error = payload["error"] as? [String: Any] {
                throw CodexDeviceCodeLoginService.parseError(from: error)
            }

            guard let result = payload["result"] as? [String: Any] else {
                throw CodexDeviceCodeLoginError.parseFailure("Missing RPC result")
            }

            return result
        }
    }

    private static func jsonrpcClientInfo() -> [String: Any] {
        [
            "name": "claudebar",
            "version": "1.0.0"
        ]
    }

    func initialize() async throws {
        _ = try await request(method: "initialize", params: ["clientInfo": Self.jsonrpcClientInfo()])
        try sendPayload(["jsonrpc": "2.0", "method": "initialized", "params": [:]])
    }

    func startLogin(type: String = "chatgptDeviceCode") async throws -> CodexDeviceCodeLoginStart {
        let params: [String: Any] = ["type": type]
        let result = try await request(method: "account/login/start", params: params)
        return try CodexDeviceCodeLoginService.parseLoginStart(result)
    }

    private func receiveMessage(within seconds: TimeInterval) async throws -> [String: Any] {
        if seconds <= 0 {
            throw CodexDeviceCodeLoginError.timedOut
        }

        return try await withThrowingTaskGroup(of: JSONPayloadBox.self) { group in
            group.addTask {
                JSONPayloadBox(value: try await self.readNextMessage())
            }

            group.addTask {
                let nanos = UInt64(max(0.1, seconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanos)
                throw CodexDeviceCodeLoginError.timedOut
            }

            defer {
                group.cancelAll()
            }

            guard let result = try await group.next() else {
                throw CodexDeviceCodeLoginError.timedOut
            }
            return result.value
        }
    }

    private func readNextMessage() async throws -> [String: Any] {
        while true {
            let data = try await transport.receive()
            guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return jsonObject
        }
    }

    private func sendPayload(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try transport.send(data)
    }
}

private struct JSONPayloadBox: @unchecked Sendable {
    let value: [String: Any]
}

struct CodexDeviceCodeLoginService {
    static func start(codexHomeDirectory: String) async throws -> CodexDeviceCodeLoginSession {
        let expandedCodexHome = NSString(string: codexHomeDirectory).expandingTildeInPath
        try CodexProfileStorage.ensureProfile(at: expandedCodexHome)

        let transport = try ProcessRPCTransport(
            executable: "codex",
            arguments: ["-s", "read-only", "-a", "untrusted", "app-server"],
            environment: ["CODEX_HOME": expandedCodexHome]
        )

        let session = CodexDeviceCodeLoginSession(
            transport: transport,
            loginId: "",
            userCode: "",
            verificationURL: ""
        )

        do {
            try await session.initialize()
            let start = try await session.startLogin()
            session.loginId = start.loginId
            session.userCode = start.userCode
            session.verificationURL = start.verificationURL
            return session
        } catch {
            session.cancel()
            throw error
        }
    }

    static func runLegacyLoginFlow() throws -> CLIResult {
        throw CodexDeviceCodeLoginError.unsupportedDeviceCodeLogin
    }

    static func isLegacyDeviceAuthUnsupported(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return normalized.contains("unrecognized argument") ||
            normalized.contains("unrecognized option") ||
            normalized.contains("unknown option") ||
            normalized.contains("unexpected argument") ||
            normalized.contains("did not expect argument")
    }

    static func firstNonEmptyString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        return nil
    }

    static func firstNonEmptyBool(in dict: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let boolValue = dict[key] as? Bool {
                return boolValue
            }
        }

        return nil
    }

    static func parseLoginStart(_ result: [String: Any]) throws -> CodexDeviceCodeLoginStart {
        if firstNonEmptyString(in: result, keys: ["authUrl", "authURL", "authorizationUrl"]) != nil {
            throw CodexDeviceCodeLoginError.unsupportedDeviceCodeLogin
        }

        guard let loginId = firstNonEmptyString(in: result, keys: ["loginId", "login_id", "id"]) else {
            throw CodexDeviceCodeLoginError.parseFailure("Missing loginId")
        }

        guard let userCode = firstNonEmptyString(
            in: result,
            keys: ["userCode", "user_code", "code", "device_code", "verificationCode", "verification_code"]
        ) else {
            throw CodexDeviceCodeLoginError.parseFailure("Missing user code")
        }

        guard let verificationURL = firstNonEmptyString(
            in: result,
            keys: ["verificationUrl", "verificationURL", "verificationUri", "verification_uri", "url"]
        ) else {
            throw CodexDeviceCodeLoginError.parseFailure("Missing verification URL")
        }

        return CodexDeviceCodeLoginStart(
            loginId: loginId,
            userCode: userCode,
            verificationURL: verificationURL
        )
    }

    static func parseError(from payload: [String: Any]) -> CodexDeviceCodeLoginError {
        let code = payload["code"] as? Int
        let rawMessage = payload["message"] as? String ?? "Request failed"
        let message = rawMessage.lowercased()

        if code == -32_601 {
            return .unsupportedDeviceCodeLogin
        }

        if message.contains("method not found") ||
            message.contains("unsupported") ||
            message.contains("not supported") {
            return .unsupportedDeviceCodeLogin
        }

        return .requestFailed(rawMessage)
    }

    static func email(from payload: [String: Any]) -> String? {
        if let direct = firstNonEmptyString(in: payload, keys: ["email", "userEmail"]) {
            return direct
        }

        if let account = payload["account"] as? [String: Any],
           let direct = firstNonEmptyString(in: account, keys: ["email", "userEmail"]) {
            return direct
        }

        if let user = payload["user"] as? [String: Any],
           let direct = firstNonEmptyString(in: user, keys: ["email", "userEmail"]) {
            return direct
        }

        if let profile = payload["profile"] as? [String: Any],
           let direct = firstNonEmptyString(in: profile, keys: ["email", "userEmail"]) {
            return direct
        }

        return nil
    }

    static func plan(from payload: [String: Any]) -> String? {
        if let direct = firstNonEmptyString(in: payload, keys: ["plan", "planType", "subscription", "tier"]) {
            return direct
        }

        if let account = payload["account"] as? [String: Any] {
            if let direct = firstNonEmptyString(in: account, keys: ["plan", "planType", "subscription", "tier"]) {
                return direct
            }

            if let plan = account["plan"] as? [String: Any],
               let direct = firstNonEmptyString(in: plan, keys: ["name", "title", "type"]) {
                return direct
            }
        }

        if let subscription = payload["subscription"] as? [String: Any],
           let direct = firstNonEmptyString(in: subscription, keys: ["name", "plan", "type", "tier"]) {
            return direct
        }

        return nil
    }
}


/// Opens Codex device-code verification in an app-owned, non-persistent WebKit window.
/// This deliberately avoids the default browser cookie jar so completing Codex login
/// does not switch or invalidate the user's normal ChatGPT browser session.
@MainActor
enum CodexAuthPageOpener {
    private static var retainedWindows: [NSWindow] = []

    static func openIsolatedWindow(url: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: url))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex login"
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        retainedWindows.append(window)
        retainedWindows.removeAll { !$0.isVisible }
    }
}
