import Testing
import Foundation
import Mockable
@testable import Infrastructure
@testable import Domain

@Suite
struct GeminiAPIProbeTests {
    private struct TestClock: Clock {
        func sleep(for duration: Duration) async throws {}
        func sleep(nanoseconds: UInt64) async throws {}
    }

    // MARK: - Helpers

    private func makeTemporaryHomeDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }
    
    private func createCredentialsFile(in homeDirectory: URL, accessToken: String = "test-token") throws {
        let dotGemini = homeDirectory.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: dotGemini, withIntermediateDirectories: true)
        
        let credsURL = dotGemini.appendingPathComponent("oauth_creds.json")
        let json: [String: Any] = [
            "access_token": accessToken,
            "expiry_date": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: credsURL)
    }
    
    // MARK: - Tests
    
    @Test
    func `probe fails when credentials missing`() async throws {
        let homeDir = try makeTemporaryHomeDirectory()
        let mockService = MockNetworkClient()
        
        let probe = GeminiAPIProbe(
            homeDirectory: homeDir.path,
            timeout: 1.0,
            networkClient: mockService,
            maxRetries: 1
        )

        await #expect(throws: ProbeError.authenticationRequired) {
            try await probe.probe()
        }
    }

    @Test
    func `probe discovers project id and fetches quota`() async throws {
        let homeDir = try makeTemporaryHomeDirectory()
        try createCredentialsFile(in: homeDir)
        let mockService = MockNetworkClient()

        // Setup mocks: loadCodeAssist returns the cloudaicompanionProject, then
        // retrieveUserQuota returns model buckets. This mirrors how gemini-cli
        // bootstraps a session, which is the path ClaudeBar must follow to get
        // accurate per-user quota for personal-OAuth users.
        let projectsResponse = """
        { "cloudaicompanionProject": "alien-superstate-rq4hk" }
        """.data(using: .utf8)!

        let quotaResponse = """
        {
            "buckets": [
                {
                    "modelId": "gemini-pro",
                    "remainingFraction": 0.8,
                    "resetTime": "2025-12-21T12:00:00Z"
                }
            ]
        }
        """.data(using: .utf8)!

        given(mockService)
            .request(.any)
            .willProduce { request in
                let url = request.url?.absoluteString ?? ""
                if url.contains("loadCodeAssist") {
                    return (projectsResponse, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                } else {
                    return (quotaResponse, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
            }

        let probe = GeminiAPIProbe(
            homeDirectory: homeDir.path,
            timeout: 1.0,
            networkClient: mockService,
            maxRetries: 1
        )

        let snapshot = try await probe.probe()

        // Verify quota
        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quotas.first?.percentRemaining == 80.0)

        // Verify the discovered project ID was included in the quota request
        // (the bug this test pins down: without it, the API returns dummy 100%)
        verify(mockService)
            .request(.matching { request in
                guard let url = request.url?.absoluteString else { return false }
                if url.contains("retrieveUserQuota") {
                    if let body = request.httpBody,
                       let bodyStr = String(data: body, encoding: .utf8) {
                        return bodyStr.contains("alien-superstate-rq4hk")
                    }
                }
                return false
            })
            .called(1)
    }

    @Test
    func `probe sorts quotas by remaining fraction ascending`() async throws {
        // Ensures the most-used models bubble to the top so a glance at the
        // menu surfaces what's actually under pressure. Tiebreaker is model ID.
        let homeDir = try makeTemporaryHomeDirectory()
        try createCredentialsFile(in: homeDir)
        let mockService = MockNetworkClient()

        let projectsResponse = """
        { "cloudaicompanionProject": "alien-superstate-rq4hk" }
        """.data(using: .utf8)!

        // Distinct tiers, distinct fractions — covers the sort path without
        // tripping the alias-dedupe path (which collapses tier-mates).
        let quotaResponse = """
        {
            "buckets": [
                { "modelId": "gemini-2.5-pro",        "remainingFraction": 0.05, "resetTime": "2026-05-10T17:28:41Z" },
                { "modelId": "gemini-2.5-flash",      "remainingFraction": 0.4,  "resetTime": "2026-05-10T17:29:03Z" },
                { "modelId": "gemini-2.5-flash-lite", "remainingFraction": 0.99, "resetTime": "2026-05-11T14:56:33Z" },
                { "modelId": "gemini-other",          "remainingFraction": 1.0,  "resetTime": "2026-05-11T14:56:33Z" }
            ]
        }
        """.data(using: .utf8)!

        given(mockService)
            .request(.any)
            .willProduce { request in
                let url = request.url?.absoluteString ?? ""
                if url.contains("loadCodeAssist") {
                    return (projectsResponse, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                } else {
                    return (quotaResponse, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
            }

        let probe = GeminiAPIProbe(
            homeDirectory: homeDir.path,
            timeout: 1.0,
            networkClient: mockService,
            maxRetries: 1
        )

        let snapshot = try await probe.probe()

        let labels: [String] = snapshot.quotas.compactMap {
            if case let .modelSpecific(label) = $0.quotaType { return label }
            return nil
        }
        // Tiered models get tier labels (matching gemini-cli's /model UI);
        // unrecognized models keep their raw ID.
        #expect(labels == [
            "Pro",          // 5%
            "Flash",        // 40%
            "Flash Lite",   // 99%
            "gemini-other"  // 100%
        ])
    }

    @Test
    func `probe collapses tier-aliased model IDs into one row per tier`() async throws {
        // The Code Assist API reports one tier-level bucket under every model
        // alias the user can call (e.g. all three Pro IDs share the Pro
        // bucket and move in lockstep). Without dedupe, the menu shows the
        // same quota three times. Survivor is the newest-versioned alias.
        let homeDir = try makeTemporaryHomeDirectory()
        try createCredentialsFile(in: homeDir)
        let mockService = MockNetworkClient()

        let projectsResponse = """
        { "cloudaicompanionProject": "alien-superstate-rq4hk" }
        """.data(using: .utf8)!

        let quotaResponse = """
        {
            "buckets": [
                { "modelId": "gemini-2.5-pro",                "remainingFraction": 0.88, "resetTime": "2026-05-10T17:28:41Z" },
                { "modelId": "gemini-3-pro-preview",          "remainingFraction": 0.88, "resetTime": "2026-05-10T17:28:41Z" },
                { "modelId": "gemini-3.1-pro-preview",        "remainingFraction": 0.88, "resetTime": "2026-05-10T17:28:41Z" },
                { "modelId": "gemini-2.5-flash",              "remainingFraction": 0.96, "resetTime": "2026-05-10T17:29:03Z" },
                { "modelId": "gemini-3-flash-preview",        "remainingFraction": 0.96, "resetTime": "2026-05-10T17:29:03Z" },
                { "modelId": "gemini-2.5-flash-lite",         "remainingFraction": 1.0,  "resetTime": "2026-05-11T14:56:55Z" },
                { "modelId": "gemini-3.1-flash-lite-preview", "remainingFraction": 1.0,  "resetTime": "2026-05-11T14:56:55Z" }
            ]
        }
        """.data(using: .utf8)!

        given(mockService)
            .request(.any)
            .willProduce { request in
                let url = request.url?.absoluteString ?? ""
                if url.contains("loadCodeAssist") {
                    return (projectsResponse, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                } else {
                    return (quotaResponse, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
            }

        let probe = GeminiAPIProbe(
            homeDirectory: homeDir.path,
            timeout: 1.0,
            networkClient: mockService,
            maxRetries: 1
        )

        let snapshot = try await probe.probe()

        #expect(snapshot.quotas.count == 3)

        let labels: [String] = snapshot.quotas.compactMap {
            if case let .modelSpecific(label) = $0.quotaType { return label }
            return nil
        }
        // Tier labels match gemini-cli's /model view — independent of which
        // version alias survived the dedupe, the quota represents the tier.
        #expect(labels == [
            "Pro",         // 88% — most used
            "Flash",       // 96%
            "Flash Lite"   // 100%
        ])
    }

    @Test
    func `probe falls back to newest preview when only previews are available`() async throws {
        // If a tier exposes only preview aliases (e.g. on accounts where the
        // stable model has been retired), the highest-versioned preview wins.
        let homeDir = try makeTemporaryHomeDirectory()
        try createCredentialsFile(in: homeDir)
        let mockService = MockNetworkClient()

        let projectsResponse = """
        { "cloudaicompanionProject": "alien-superstate-rq4hk" }
        """.data(using: .utf8)!

        let quotaResponse = """
        {
            "buckets": [
                { "modelId": "gemini-3-pro-preview",   "remainingFraction": 0.5, "resetTime": "2026-05-10T17:28:41Z" },
                { "modelId": "gemini-3.1-pro-preview", "remainingFraction": 0.5, "resetTime": "2026-05-10T17:28:41Z" }
            ]
        }
        """.data(using: .utf8)!

        given(mockService)
            .request(.any)
            .willProduce { request in
                let url = request.url?.absoluteString ?? ""
                if url.contains("loadCodeAssist") {
                    return (projectsResponse, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                } else {
                    return (quotaResponse, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
            }

        let probe = GeminiAPIProbe(
            homeDirectory: homeDir.path,
            timeout: 1.0,
            networkClient: mockService,
            maxRetries: 1
        )

        let snapshot = try await probe.probe()

        #expect(snapshot.quotas.count == 1)
        if case let .modelSpecific(label) = snapshot.quotas.first?.quotaType {
            // Even with only previews available, the row is labeled by tier.
            #expect(label == "Pro")
        } else {
            Issue.record("expected modelSpecific quota")
        }
    }

    @Test
    func `probe parses reset time into Date and human readable text`() async throws {
        let homeDir = try makeTemporaryHomeDirectory()
        try createCredentialsFile(in: homeDir)
        let mockService = MockNetworkClient()

        let projectsResponse = """
        { "cloudaicompanionProject": "gen-lang-client-123456" }
        """.data(using: .utf8)!

        // Use a reset time 2 hours in the future
        let futureDate = Date().addingTimeInterval(2 * 3600 + 15 * 60) // 2h 15m from now
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let resetTimeString = formatter.string(from: futureDate)

        let quotaResponse = """
        {
            "buckets": [
                {
                    "modelId": "gemini-pro",
                    "remainingFraction": 0.8,
                    "resetTime": "\(resetTimeString)"
                }
            ]
        }
        """.data(using: .utf8)!

        given(mockService)
            .request(.any)
            .willProduce { request in
                let url = request.url?.absoluteString ?? ""
                if url.contains("loadCodeAssist") {
                    return (projectsResponse, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                } else {
                    return (quotaResponse, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
            }

        let probe = GeminiAPIProbe(
            homeDirectory: homeDir.path,
            timeout: 1.0,
            networkClient: mockService,
            maxRetries: 1
        )

        let snapshot = try await probe.probe()
        let quota = try #require(snapshot.quotas.first)

        // resetsAt should be a parsed Date, not nil
        let resetsAt = try #require(quota.resetsAt)
        let timeDiff = abs(resetsAt.timeIntervalSince(futureDate))
        #expect(timeDiff < 2) // Within 2 seconds tolerance

        // resetText should be human-readable, not raw ISO 8601
        let resetText = try #require(quota.resetText)
        #expect(resetText.contains("Resets in"))
        #expect(!resetText.contains("T"))  // Should NOT contain ISO 8601 'T' separator
    }

    @Test
    func `probe handles api error gracefully`() async throws {
        let homeDir = try makeTemporaryHomeDirectory()
        try createCredentialsFile(in: homeDir)
        let mockService = MockNetworkClient()
        
        given(mockService)
            .request(.any)
            .willProduce { _ in
                (Data(), HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }
            
        let probe = GeminiAPIProbe(
            homeDirectory: homeDir.path,
            timeout: 1.0,
            networkClient: mockService,
            maxRetries: 1
        )

        await #expect(throws: ProbeError.executionFailed("HTTP 500")) {
            try await probe.probe()
        }
    }

    @Test
    func `probe refreshes token and retries after 401`() async throws {
        let homeDir = try makeTemporaryHomeDirectory()
        try createCredentialsFile(in: homeDir)
        let mockService = MockNetworkClient()
        let mockExecutor = MockCLIExecutor()

        let projectsResponse = """
        { "cloudaicompanionProject": "gen-lang-client-123456" }
        """.data(using: .utf8)!

        let quotaResponse = """
        {
            "buckets": [
                {
                    "modelId": "gemini-pro",
                    "remainingFraction": 0.8,
                    "resetTime": "2025-12-21T12:00:00Z"
                }
            ]
        }
        """.data(using: .utf8)!

        var quotaCalls = 0
        given(mockService)
            .request(.any)
            .willProduce { request in
                let url = request.url?.absoluteString ?? ""
                if url.contains("retrieveUserQuota") {
                    quotaCalls += 1
                    if quotaCalls == 1 {
                        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
                    }
                    return (quotaResponse, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                return (projectsResponse, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }

        given(mockExecutor).locate(.value("gemini")).willReturn("/usr/local/bin/gemini")
        given(mockExecutor).execute(
            binary: .value("gemini"),
            args: .value([]),
            input: .value("/quit\n"),
            timeout: .value(15.0),
            workingDirectory: .value(nil),
            autoResponses: .value([:])
        ).willReturn(CLIResult(output: ""))

        let probe = GeminiAPIProbe(
            homeDirectory: homeDir.path,
            timeout: 1.0,
            networkClient: mockService,
            maxRetries: 1,
            cliExecutor: mockExecutor,
            clock: TestClock()
        )

        let snapshot = try await probe.probe()

        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quotas.first?.percentRemaining == 80.0)
        verify(mockExecutor).execute(
            binary: .value("gemini"),
            args: .value([]),
            input: .value("/quit\n"),
            timeout: .value(15.0),
            workingDirectory: .value(nil),
            autoResponses: .value([:])
        ).called(1)
    }

    @Test
    func `probe returns authentication required when refresh cli is missing`() async throws {
        let homeDir = try makeTemporaryHomeDirectory()
        try createCredentialsFile(in: homeDir)
        let mockService = MockNetworkClient()
        let mockExecutor = MockCLIExecutor()

        let projectsResponse = """
        { "cloudaicompanionProject": "gen-lang-client-123456" }
        """.data(using: .utf8)!

        given(mockService)
            .request(.any)
            .willProduce { request in
                let url = request.url?.absoluteString ?? ""
                if url.contains("retrieveUserQuota") {
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
                }
                return (projectsResponse, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }

        given(mockExecutor).locate(.value("gemini")).willReturn(nil)

        let probe = GeminiAPIProbe(
            homeDirectory: homeDir.path,
            timeout: 1.0,
            networkClient: mockService,
            maxRetries: 1,
            cliExecutor: mockExecutor,
            clock: TestClock()
        )

        await #expect(throws: ProbeError.authenticationRequired) {
            try await probe.probe()
        }
    }

    @Test
    func `probe returns authentication required when retry still 401`() async throws {
        let homeDir = try makeTemporaryHomeDirectory()
        try createCredentialsFile(in: homeDir)
        let mockService = MockNetworkClient()
        let mockExecutor = MockCLIExecutor()

        let projectsResponse = """
        { "cloudaicompanionProject": "gen-lang-client-123456" }
        """.data(using: .utf8)!

        var quotaCalls = 0
        given(mockService)
            .request(.any)
            .willProduce { request in
                let url = request.url?.absoluteString ?? ""
                if url.contains("retrieveUserQuota") {
                    quotaCalls += 1
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
                }
                return (projectsResponse, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }

        given(mockExecutor).locate(.value("gemini")).willReturn("/usr/local/bin/gemini")
        given(mockExecutor).execute(
            binary: .value("gemini"),
            args: .value([]),
            input: .value("/quit\n"),
            timeout: .value(15.0),
            workingDirectory: .value(nil),
            autoResponses: .value([:])
        ).willReturn(CLIResult(output: ""))

        let probe = GeminiAPIProbe(
            homeDirectory: homeDir.path,
            timeout: 1.0,
            networkClient: mockService,
            maxRetries: 1,
            cliExecutor: mockExecutor,
            clock: TestClock()
        )

        await #expect(throws: ProbeError.authenticationRequired) {
            try await probe.probe()
        }
    }

    @Test
    func `probe returns error when retry fails with http error`() async throws {
        let homeDir = try makeTemporaryHomeDirectory()
        try createCredentialsFile(in: homeDir)
        let mockService = MockNetworkClient()
        let mockExecutor = MockCLIExecutor()

        let projectsResponse = """
        { "cloudaicompanionProject": "gen-lang-client-123456" }
        """.data(using: .utf8)!

        var quotaCalls = 0
        given(mockService)
            .request(.any)
            .willProduce { request in
                let url = request.url?.absoluteString ?? ""
                if url.contains("retrieveUserQuota") {
                    quotaCalls += 1
                    if quotaCalls == 1 {
                        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
                    }
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
                }
                return (projectsResponse, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }

        given(mockExecutor).locate(.value("gemini")).willReturn("/usr/local/bin/gemini")
        given(mockExecutor).execute(
            binary: .value("gemini"),
            args: .value([]),
            input: .value("/quit\n"),
            timeout: .value(15.0),
            workingDirectory: .value(nil),
            autoResponses: .value([:])
        ).willReturn(CLIResult(output: ""))

        let probe = GeminiAPIProbe(
            homeDirectory: homeDir.path,
            timeout: 1.0,
            networkClient: mockService,
            maxRetries: 1,
            cliExecutor: mockExecutor,
            clock: TestClock()
        )

        await #expect(throws: ProbeError.executionFailed("HTTP 500")) {
            try await probe.probe()
        }
    }
}
