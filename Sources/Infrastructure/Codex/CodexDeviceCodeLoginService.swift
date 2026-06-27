import Foundation
import Domain

/// Result returned after starting Codex managed ChatGPT device-code login.
public struct CodexDeviceCodeLoginResponse: Sendable {
    public let loginId: String
    public let verificationURL: String
    public let userCode: String
    public let session: CodexDeviceCodeLoginSession
}

/// Completion notification emitted by `codex app-server` for a login attempt.
public struct CodexDeviceCodeLoginCompletion: Sendable, Equatable {
    public let loginId: String
    public let success: Bool
    public let error: String?
}

/// Live app-server session for one pending device-code login.
///
/// The transport must remain open while the user completes the browser-side
/// device flow so the app-server can emit `account/login/completed` and persist
/// credentials in the selected CODEX_HOME.
public final class CodexDeviceCodeLoginSession: @unchecked Sendable {
    private let transport: RPCTransport
    private let loginId: String
    private var nextID: Int
    private let closeTransportOnEnd: Bool

    init(transport: RPCTransport, loginId: String, nextID: Int, closeTransportOnEnd: Bool = true) {
        self.transport = transport
        self.loginId = loginId
        self.nextID = nextID
        self.closeTransportOnEnd = closeTransportOnEnd
    }

    deinit {
        if closeTransportOnEnd {
            transport.close()
        }
    }

    /// Waits for the matching `account/login/completed` notification.
    public func waitForCompletion() async throws -> CodexDeviceCodeLoginCompletion {
        defer {
            if closeTransportOnEnd {
                transport.close()
            }
        }

        while true {
            let message = try await readNextMessage()
            guard message["method"] as? String == "account/login/completed",
                  let params = message["params"] as? [String: Any] else {
                continue
            }

            let notificationLoginId = params["loginId"] as? String
            guard notificationLoginId == nil || notificationLoginId == loginId else {
                continue
            }

            let success = params["success"] as? Bool ?? false
            let error = params["error"] as? String
            let completion = CodexDeviceCodeLoginCompletion(
                loginId: notificationLoginId ?? loginId,
                success: success,
                error: error
            )

            if success {
                return completion
            }

            throw ProbeError.executionFailed(error ?? "Codex device-code login failed")
        }
    }

    /// Cancels the pending managed ChatGPT login.
    public func cancel() throws {
        let id = nextID
        nextID += 1
        try sendPayload([
            "id": id,
            "method": "account/login/cancel",
            "params": ["loginId": loginId]
        ])
    }

    private func sendPayload(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try transport.send(data)
    }

    private func readNextMessage() async throws -> [String: Any] {
        while true {
            let data = try await transport.receive()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return json
        }
    }
}

/// Starts device-code login via `codex app-server` for a selected CODEX_HOME.
public struct CodexDeviceCodeLoginService: Sendable {
    private let executable: String
    private let transportFactory: @Sendable (String, [String], [String: String]) throws -> RPCTransport

    public init(
        executable: String = "codex",
        transportFactory: @escaping @Sendable (String, [String], [String: String]) throws -> RPCTransport = { executable, arguments, environment in
            try ProcessRPCTransport(executable: executable, arguments: arguments, environment: environment)
        }
    ) {
        self.executable = executable
        self.transportFactory = transportFactory
    }

    /// Starts ChatGPT device-code login for the selected profile folder.
    /// - Parameter codexHomePath: User-selected CODEX_HOME folder. If an auth.json path is supplied, its parent folder is used.
    public func start(codexHomePath rawCodexHomePath: String) async throws -> CodexDeviceCodeLoginResponse {
        guard let codexHomePath = CodexCredentialLoader.normalizedCodexHomePath(rawCodexHomePath) else {
            throw ProbeError.executionFailed("CODEX_HOME folder is not configured")
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHomePath

        let transport = try transportFactory(
            executable,
            ["-s", "read-only", "-a", "untrusted", "app-server"],
            environment
        )

        do {
            _ = try await Self.request(
                transport: transport,
                id: 1,
                method: "initialize",
                params: ["clientInfo": ["name": "claudebar", "version": "1.0.0"]]
            )
            try Self.sendPayload(transport: transport, payload: ["method": "initialized", "params": [:]])

            let message = try await Self.request(
                transport: transport,
                id: 2,
                method: "account/login/start",
                params: ["type": "chatgptDeviceCode"]
            )

            guard let result = message["result"] as? [String: Any],
                  result["type"] as? String == "chatgptDeviceCode",
                  let loginId = result["loginId"] as? String,
                  let verificationURL = result["verificationUrl"] as? String,
                  let userCode = result["userCode"] as? String else {
                throw ProbeError.parseFailed("Invalid Codex device-code login response")
            }

            let session = CodexDeviceCodeLoginSession(
                transport: transport,
                loginId: loginId,
                nextID: 3
            )

            return CodexDeviceCodeLoginResponse(
                loginId: loginId,
                verificationURL: verificationURL,
                userCode: userCode,
                session: session
            )
        } catch {
            transport.close()
            throw error
        }
    }

    private static func request(
        transport: RPCTransport,
        id: Int,
        method: String,
        params: [String: Any]? = nil
    ) async throws -> [String: Any] {
        try sendPayload(transport: transport, payload: [
            "id": id,
            "method": method,
            "params": params ?? [:]
        ])

        while true {
            let message = try await readNextMessage(transport: transport)
            guard let messageID = message["id"] as? Int, messageID == id else {
                continue
            }

            if let error = message["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw ProbeError.executionFailed("RPC error: \(message)")
            }

            return message
        }
    }

    private static func sendPayload(transport: RPCTransport, payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try transport.send(data)
    }

    private static func readNextMessage(transport: RPCTransport) async throws -> [String: Any] {
        while true {
            let data = try await transport.receive()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return json
        }
    }
}
