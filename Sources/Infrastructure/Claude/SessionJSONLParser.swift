import Foundation

/// A single token usage record extracted from a JSONL assistant message.
struct TokenUsageRecord: Sendable, Equatable {
    /// `message.id` (e.g. "msg_01Dso…"). Claude Code repeats this across streamed
    /// content blocks and parallel tool calls — used for deduplication. `nil` if absent.
    let messageId: String?
    /// Top-level `requestId` (e.g. "req_011Cax…"). Combined with `messageId` to form the
    /// dedup key. `nil` if absent.
    let requestId: String?
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let timestamp: Date

    var totalTokens: Int {
        inputTokens + outputTokens
    }
}

/// Parses Claude Code session JSONL files to extract token usage records.
struct SessionJSONLParser {
    /// Parse a single JSONL file and extract all token usage records.
    func parse(fileURL: URL) throws -> [TokenUsageRecord] {
        let data = try Data(contentsOf: fileURL)
        guard let content = String(data: data, encoding: .utf8) else { return [] }
        return parse(content: content)
    }

    /// Parse content string directly.
    func parse(content: String) -> [TokenUsageRecord] {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        var records: [TokenUsageRecord] = []
        for line in content.split(separator: "\n") {
            if let record = parseLine(line, dateFormatter: dateFormatter, fallbackFormatter: fallbackFormatter) {
                records.append(record)
            }
        }
        return records
    }

    /// Extract a single record from one JSONL line, or `nil` if it is not a usage-bearing
    /// assistant message (or fails to parse).
    private func parseLine(
        _ line: Substring,
        dateFormatter: ISO8601DateFormatter,
        fallbackFormatter: ISO8601DateFormatter
    ) -> TokenUsageRecord? {
        guard let lineData = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              json["type"] as? String == "assistant",
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String,
              let timestampStr = json["timestamp"] as? String,
              let timestamp = dateFormatter.date(from: timestampStr) ?? fallbackFormatter.date(from: timestampStr)
        else { return nil }

        return TokenUsageRecord(
            messageId: message["id"] as? String,
            requestId: json["requestId"] as? String,
            model: model,
            inputTokens: usage["input_tokens"] as? Int ?? 0,
            outputTokens: usage["output_tokens"] as? Int ?? 0,
            cacheCreationTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
            cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
            timestamp: timestamp
        )
    }
}
