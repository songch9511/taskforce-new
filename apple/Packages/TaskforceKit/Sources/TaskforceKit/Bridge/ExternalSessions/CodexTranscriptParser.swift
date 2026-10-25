#if os(macOS)
import Foundation

/// Only explicit conversational message records; event mirrors and injected context are excluded.
enum CodexTranscriptParser {
    struct Parsed { let turns: [ClaudeAppTurn]; let hasEarlier: Bool }
    static func matchesSession(_ data: Data, id: String) -> Bool {
        guard let end = data.firstIndex(of: 10), end <= 1 << 20,
              let object = try? JSONSerialization.jsonObject(with: data[..<end]) as? [String: Any],
              object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any] else { return false }
        return payload["id"] as? String == id
    }
    static func parse(_ data: Data, offset: Int64 = 0) -> Parsed {
        var turns: [ClaudeAppTurn] = []
        var position = offset, earlier = offset > 0
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if data.last != 10, !lines.isEmpty { lines.removeLast() }
        for (index, line) in lines.enumerated() {
            defer { position += Int64(line.count + 1) }
            if offset > 0 && index == 0 { continue }
            guard line.count <= 1 << 20,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "response_item", let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message", let role = payload["role"] as? String,
                  role == "user" || role == "assistant", let content = payload["content"] as? [[String: Any]] else { continue }
            if role == "assistant", let channel = payload["channel"] as? String,
               channel != "final" && channel != "commentary" { continue }
            let metadata = payload["internal_chat_message_metadata_passthrough"] as? [String: Any]
            let kinds = metadata?["content_item_kinds"] as? [String]
            // Malformed parallel metadata must never expose an injected block.
            if role == "user", payload["internal_chat_message_metadata_passthrough"] != nil, kinds?.count != content.count { continue }
            var kept: [String] = []
            for (blockIndex, block) in content.enumerated() {
                guard let type = block["type"] as? String, type == "input_text" || type == "output_text",
                      let text = block["text"] as? String else { continue }
                if role == "user" {
                    if let kinds {
                        guard kinds[blockIndex] == "user.text" || kinds[blockIndex] == "user.image" else { continue }
                    } else if isInjected(text) { continue }
                }
                kept.append(text)
            }
            let raw = kept.joined(separator: "\n")
            guard !raw.isEmpty else { continue }
            var scalars = String.UnicodeScalarView(), bytes = 0, truncated = false
            for scalar in raw.unicodeScalars where !ClaudeAppTranscriptReader.isStripped(scalar) {
                if bytes + scalar.utf8.count > 32 << 10 { truncated = true; break }
                scalars.append(scalar); bytes += scalar.utf8.count
            }
            let text = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let timestamp = (object["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            turns.append(ClaudeAppTurn(id: "codex-\(position)", kind: role == "user" ? .user(text) : .assistant(text), timestamp: timestamp, truncated: truncated))
            if turns.count > 200 { turns.removeFirst(); earlier = true }
        }
        return Parsed(turns: turns, hasEarlier: earlier)
    }
    private static func isInjected(_ text: String) -> Bool {
        let start = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["# AGENTS.md instructions", "<environment_context>", "<permissions instructions>", "<skill>", "<skills_instructions>", "<turn_aborted>", "<external_codex_apps_open_page>", "<INSTRUCTIONS>"].contains { start.hasPrefix($0) }
    }
}
#endif
