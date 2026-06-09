import Foundation
import Testing
@testable import Infrastructure

@Suite
struct SessionJSONLParserTests {
    let parser = SessionJSONLParser()

    @Test func `parses assistant message with usage data`() {
        let jsonl = """
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":200,"cache_read_input_tokens":30}},"timestamp":"2026-03-11T10:00:00.000Z"}
        """
        let records = parser.parse(content: jsonl)
        #expect(records.count == 1)
        #expect(records[0].model == "claude-sonnet-4-6")
        #expect(records[0].inputTokens == 100)
        #expect(records[0].outputTokens == 50)
        #expect(records[0].cacheCreationTokens == 200)
        #expect(records[0].cacheReadTokens == 30)
        #expect(records[0].totalTokens == 150)
    }

    @Test func `skips non-assistant messages`() {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"hello"},"timestamp":"2026-03-11T10:00:00.000Z"}
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":5}},"timestamp":"2026-03-11T10:00:01.000Z"}
        {"type":"progress","data":{"type":"hook_progress"},"timestamp":"2026-03-11T10:00:02.000Z"}
        """
        let records = parser.parse(content: jsonl)
        #expect(records.count == 1)
        #expect(records[0].model == "claude-sonnet-4-6")
    }

    @Test func `handles missing optional token fields`() {
        let jsonl = """
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":50}},"timestamp":"2026-03-11T10:00:00.000Z"}
        """
        let records = parser.parse(content: jsonl)
        #expect(records.count == 1)
        #expect(records[0].cacheCreationTokens == 0)
        #expect(records[0].cacheReadTokens == 0)
    }

    @Test func `parses multiple records from same session`() {
        let jsonl = """
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":50}},"timestamp":"2026-03-11T10:00:00.000Z"}
        {"type":"assistant","message":{"model":"claude-opus-4-6","usage":{"input_tokens":200,"output_tokens":100}},"timestamp":"2026-03-11T10:05:00.000Z"}
        """
        let records = parser.parse(content: jsonl)
        #expect(records.count == 2)
        #expect(records[0].model == "claude-sonnet-4-6")
        #expect(records[1].model == "claude-opus-4-6")
    }

    @Test func `handles malformed JSON lines gracefully`() {
        let jsonl = """
        not json at all
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":5}},"timestamp":"2026-03-11T10:00:00.000Z"}
        {"incomplete": true
        """
        let records = parser.parse(content: jsonl)
        #expect(records.count == 1)
    }

    @Test func `captures messageId and requestId for deduplication`() {
        let jsonl = """
        {"type":"assistant","requestId":"req_011Cax","message":{"id":"msg_01Dso","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":5}},"timestamp":"2026-03-11T10:00:00.000Z"}
        """
        let records = parser.parse(content: jsonl)
        #expect(records.count == 1)
        #expect(records[0].messageId == "msg_01Dso")
        #expect(records[0].requestId == "req_011Cax")
    }

    @Test func `leaves identity fields nil when absent`() {
        let jsonl = """
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":5}},"timestamp":"2026-03-11T10:00:00.000Z"}
        """
        let records = parser.parse(content: jsonl)
        #expect(records.count == 1)
        #expect(records[0].messageId == nil)
        #expect(records[0].requestId == nil)
    }

    @Test func `parses ISO8601 timestamp correctly`() {
        let jsonl = """
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":5}},"timestamp":"2026-03-11T10:30:45.123Z"}
        """
        let records = parser.parse(content: jsonl)
        #expect(records.count == 1)

        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: records[0].timestamp)
        #expect(components.year == 2026)
        #expect(components.month == 3)
        #expect(components.day == 11)
        #expect(components.hour == 10)
        #expect(components.minute == 30)
    }
}
