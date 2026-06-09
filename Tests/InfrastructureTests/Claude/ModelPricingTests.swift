import Foundation
import Testing
@testable import Infrastructure

@Suite
struct ModelPricingTests {
    @Test func `sonnet pricing matches published rates`() {
        let price = ModelPricing.price(for: "claude-sonnet-4-6")
        #expect(price.inputPer1M == 3)
        #expect(price.outputPer1M == 15)
        #expect(price.cacheWritePer1M == Decimal(string: "3.75"))
        #expect(price.cacheReadPer1M == Decimal(string: "0.30"))
    }

    @Test func `opus 4_6 pricing matches published rates`() {
        let price = ModelPricing.price(for: "claude-opus-4-6")
        #expect(price.inputPer1M == 5)
        #expect(price.outputPer1M == 25)
        #expect(price.cacheWritePer1M == Decimal(string: "6.25"))
        #expect(price.cacheReadPer1M == Decimal(string: "0.50"))
    }

    @Test func `unknown model falls back to sonnet pricing`() {
        let price = ModelPricing.price(for: "some-unknown-model")
        #expect(price.inputPer1M == 3)
        #expect(price.outputPer1M == 15)
    }

    @Test func `model with opus in name uses opus 4_6 pricing`() {
        let price = ModelPricing.price(for: "claude-opus-4-99-20260101")
        #expect(price.inputPer1M == 5)
    }

    @Test func `calculates cost for token usage record`() {
        let record = TokenUsageRecord(
            messageId: nil,
            requestId: nil,
            model: "claude-sonnet-4-6",
            inputTokens: 1_000_000, // $3
            outputTokens: 100_000,  // $1.50
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            timestamp: Date()
        )
        let cost = ModelPricing.cost(for: record)
        #expect(cost == Decimal(string: "4.5"))
    }

    @Test func `calculates cost including cache tokens`() {
        let record = TokenUsageRecord(
            messageId: nil,
            requestId: nil,
            model: "claude-sonnet-4-6",
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 1_000_000, // $3.75
            cacheReadTokens: 1_000_000,     // $0.30
            timestamp: Date()
        )
        let cost = ModelPricing.cost(for: record)
        #expect(cost == Decimal(string: "4.05"))
    }

    @Test func `calculates cache savings as input price minus cache read price`() {
        // Sonnet: input $3/M, cache_read $0.30/M → save $2.70 per 1M cache reads
        let record = TokenUsageRecord(
            messageId: nil,
            requestId: nil,
            model: "claude-sonnet-4-6",
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 1_000_000,
            timestamp: Date()
        )
        let savings = ModelPricing.savings(for: record)
        #expect(savings == Decimal(string: "2.7"))
    }

    @Test func `cache savings is zero when no cache reads`() {
        let record = TokenUsageRecord(
            messageId: nil,
            requestId: nil,
            model: "claude-sonnet-4-6",
            inputTokens: 1_000_000,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            timestamp: Date()
        )
        #expect(ModelPricing.savings(for: record) == 0)
    }

    @Test func `cache savings scales with cache read tokens`() {
        // Opus 4.6: input $5/M, cache_read $0.50/M → save $4.50 per 1M
        let record = TokenUsageRecord(
            messageId: nil,
            requestId: nil,
            model: "claude-opus-4-6",
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 2_000_000,
            timestamp: Date()
        )
        // 2M × $4.50/M = $9.00
        #expect(ModelPricing.savings(for: record) == 9)
    }
}
