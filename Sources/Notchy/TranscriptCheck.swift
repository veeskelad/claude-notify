import Foundation

// "Was this request answered in the session itself?" PostToolUse misses a denied tool (it never
// runs), and a subagent's request outlives the main turn's Stop. The transcript has the truth:
// once the call is answered either way, a tool_result for its tool_use follows.
//
// PermissionRequest carries no tool_use_id, so the call is found as the last tool_use with the
// request's match key (the hook's match_key: tool name, plus command / file / url).

enum TranscriptCheck {
    private static let tailBytes: UInt64 = 512 * 1024

    /// The transcript the request's call is written to: the session's, or its subagent's.
    static func path(transcript: String, agentId: String) -> String {
        guard !agentId.isEmpty, transcript.hasSuffix(".jsonl") else { return transcript }
        return "\(transcript.dropLast(".jsonl".count))/subagents/agent-\(agentId).jsonl"
    }

    /// nil when it can't tell (no transcript, call not found).
    static func answered(path: String, match: String) -> Bool? {
        guard !path.isEmpty, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }
        let size = handle.seekToEndOfFile()
        handle.seek(toFileOffset: size > tailBytes ? size - tailBytes : 0)
        guard let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else { return nil }

        var lastCall: String?
        var results = Set<String>()
        for line in text.split(separator: "\n") where line.contains("\"tool_use\"") || line.contains("\"tool_result\"") {
            guard let data = line.data(using: .utf8),
                  let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let content = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]]
            else { continue }
            for item in content {
                switch item["type"] as? String {
                case "tool_use":
                    if let id = item["id"] as? String, let name = item["name"] as? String,
                       key(name, item["input"] as? [String: Any] ?? [:]) == match {
                        lastCall = id
                    }
                case "tool_result":
                    if let id = item["tool_use_id"] as? String { results.insert(id) }
                default:
                    break
                }
            }
        }
        guard let call = lastCall else { return nil }
        return results.contains(call)
    }

    /// Same as the hook's match_key.
    static func key(_ tool: String, _ input: [String: Any]) -> String {
        let target = ["command", "file_path", "notebook_path", "url"]
            .lazy.compactMap { input[$0] as? String }.first { !$0.isEmpty } ?? ""
        if tool == "AskUserQuestion" || tool == "ExitPlanMode" || target.isEmpty { return tool }
        return "\(tool):\(target)"
    }
}
