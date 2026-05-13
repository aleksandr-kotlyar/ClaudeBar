import Testing
import Foundation
import Mockable
@testable import Infrastructure
@testable import Domain

@Suite
struct OpenCodeUsageProbeTests {

    @Test
    func `isAvailable returns true when opencode exists and db path exists`() async {
        let mockExecutor = MockCLIExecutor()
        let tempDBPath = URL.temporaryDirectory
            .appendingPathComponent("opencode-\(UUID().uuidString).db")
            .path
        FileManager.default.createFile(atPath: tempDBPath, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: tempDBPath) }

        given(mockExecutor).locate(.value("opencode")).willReturn("/usr/local/bin/opencode")
        given(mockExecutor)
            .execute(
                binary: .value("opencode"),
                args: .value(["db", "path"]),
                input: .any,
                timeout: .any,
                workingDirectory: .any,
                autoResponses: .any
            )
            .willReturn(CLIResult(output: tempDBPath, exitCode: 0))

        let probe = OpenCodeUsageProbe(cliExecutor: mockExecutor)
        #expect(await probe.isAvailable() == true)
    }

    @Test
    func `isAvailable returns false when opencode not found`() async {
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.value("opencode")).willReturn(nil)

        let probe = OpenCodeUsageProbe(cliExecutor: mockExecutor)
        #expect(await probe.isAvailable() == false)
    }

    @Test
    func `probe returns snapshot with opencode-go and three quotas`() async throws {
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.value("opencode")).willReturn("/usr/local/bin/opencode")
        given(mockExecutor)
            .execute(binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any)
            .willReturn(
                CLIResult(
                    output: """
                    [{"five_hour_cost":2.5,"weekly_cost":7.5,"monthly_cost":15.0,"five_hour_oldest_ms":1710000000000}]
                    """,
                    exitCode: 0
                )
            )

        let probe = OpenCodeUsageProbe(cliExecutor: mockExecutor)
        let snapshot = try await probe.probe()

        #expect(snapshot.providerId == "opencode-go")
        #expect(snapshot.quotas.count == 3)
        #expect(snapshot.quotas.allSatisfy { $0.providerId == "opencode-go" })
    }

    @Test
    func `probe SQL includes providerID filter for opencode-go`() async throws {
        let mockExecutor = MockCLIExecutor()
        var capturedSQL = ""
        given(mockExecutor).locate(.value("opencode")).willReturn("/usr/local/bin/opencode")
        given(mockExecutor)
            .execute(binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any)
            .willProduce { _, args, _, _, _, _ in
                capturedSQL = args.dropFirst().first ?? ""
                return CLIResult(output: "[{\"five_hour_cost\":0,\"weekly_cost\":0,\"monthly_cost\":0,\"five_hour_oldest_ms\":null}]", exitCode: 0)
            }

        let probe = OpenCodeUsageProbe(cliExecutor: mockExecutor)
        _ = try await probe.probe()

        #expect(capturedSQL.contains("json_extract(data, '$.providerID') = 'opencode-go'"))
    }

    @Test
    func `parseWindowCosts decodes combined window fields`() throws {
        let data = Data("""
        [{"five_hour_cost":1.2,"weekly_cost":3.4,"monthly_cost":5.6,"five_hour_oldest_ms":1700000000000}]
        """.utf8)

        let windows = try OpenCodeUsageProbe.parseWindowCosts(data)
        #expect(windows.fiveHourCost == 1.2)
        #expect(windows.weeklyCost == 3.4)
        #expect(windows.monthlyCost == 5.6)
        #expect(windows.fiveHourOldestMs == 1_700_000_000_000)
    }

    @Test
    func `percentRemaining clamps to 100 and 0`() {
        #expect(OpenCodeUsageProbe.percentRemaining(used: -5, limit: 12) == 100)
        #expect(OpenCodeUsageProbe.percentRemaining(used: 20, limit: 12) == 0)
    }

    @Test
    func `fiveHourResetDate uses oldestMs plus five hours`() {
        let oldestMs: Int64 = 1_700_000_000_000
        let reset = OpenCodeUsageProbe.fiveHourResetDate(from: oldestMs, fallback: .distantPast)
        let expected = Date(timeIntervalSince1970: TimeInterval(oldestMs) / 1000).addingTimeInterval(5 * 3600)

        #expect(reset == expected)
    }
}
