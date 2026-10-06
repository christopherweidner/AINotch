// SPDX-License-Identifier: GPL-3.0-or-later
// Log semantics follow vorssaint-utils' AgentLogParser (GPL-3.0-or-later).

import Foundation

/// Something a Claude Code transcript line says happened.
public enum TranscriptEvent: Equatable, Sendable {
    /// A message that starts a turn. `injected` is true for text Claude Code
    /// writes on its own, like a background task's notification.
    case prompt(Date, injected: Bool)
    case usage(UsageSample)
    case toolStarted(id: String, name: String, Date)
    case toolFinished(id: String, Date)
    /// The model is mid-turn: it streamed text or asked for tools.
    case progress(Date)
    /// The model gave its final answer for this chain.
    case turnEnded(Date, completed: Bool)
    /// The person pressed Esc or ran a local command.
    case interrupted(Date)
}

public struct TranscriptLine: Equatable, Sendable {
    /// The session the line counts toward; for sub-agents, the parent's.
    public var sessionId: String
    public var cwd: String?
    /// True for sub-agent (Task/Agent tool) lines.
    public var isSubagent: Bool
    /// Identifies the sub-agent when `isSubagent`.
    public var agentId: String?
    public var events: [TranscriptEvent]
}

public enum TranscriptParser {
    /// Tools that run a sub-agent.
    public static let agentTools: Set<String> = ["Task", "Agent"]

    /// Parses one JSONL line. `path` is the transcript's file path, used to
    /// recognise sub-agent logs (`<session>/subagents/agent-<id>.jsonl`).
    public static func parse(_ line: Data, path: String, now: Date = Date()) -> TranscriptLine? {
        guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = json["type"] as? String, type == "user" || type == "assistant" else { return nil }
        let date = timestamp(json["timestamp"]) ?? now
        let pathInfo = subagentPathInfo(path)
        let sidechain = json["isSidechain"] as? Bool == true || pathInfo != nil
        let session = pathInfo?.session ?? (json["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var result = TranscriptLine(sessionId: session, cwd: json["cwd"] as? String, isSubagent: sidechain,
                                    agentId: sidechain ? ((json["agentId"] as? String) ?? pathInfo?.agent ?? path) : nil,
                                    events: [])
        guard let message = json["message"] as? [String: Any] else { return result }
        if type == "assistant" {
            result.events = assistant(message, json: json, date: date)
        } else {
            result.events = user(message, json: json, date: date)
        }
        return result
    }

    private static func assistant(_ message: [String: Any], json: [String: Any], date: Date) -> [TranscriptEvent] {
        var events: [TranscriptEvent] = []
        let model = message["model"] as? String ?? ""
        if let usage = message["usage"] as? [String: Any], !model.isEmpty, !model.hasPrefix("<") {
            let tokens = TokenUsage(
                input: int(usage["input_tokens"]), output: int(usage["output_tokens"]),
                cacheRead: int(usage["cache_read_input_tokens"]),
                cacheWrite: int(usage["cache_creation_input_tokens"]),
                cacheWriteLong: int((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"]))
            let id = message["id"] as? String ?? ""
            let request = json["requestId"] as? String ?? ""
            let key = id.isEmpty && request.isEmpty ? "\(json["uuid"] as? String ?? UUID().uuidString)" : "\(id):\(request)"
            events.append(.usage(UsageSample(key: key, model: model, usage: tokens,
                                             fast: usage["speed"] as? String == "fast", date: date)))
        }
        for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
            if let id = block["id"] as? String {
                events.append(.toolStarted(id: id, name: block["name"] as? String ?? "tool", date))
            }
        }
        switch message["stop_reason"] as? String {
        case "end_turn", "stop_sequence", "max_tokens", "refusal":
            let failed = json["isApiErrorMessage"] as? Bool == true || model.hasPrefix("<")
            events.append(.turnEnded(date, completed: !failed))
        default:
            events.append(.progress(date))
        }
        return events
    }

    private static func user(_ message: [String: Any], json: [String: Any], date: Date) -> [TranscriptEvent] {
        let content = message["content"]
        var texts: [String] = []
        var events: [TranscriptEvent] = []
        if let text = content as? String {
            texts = [text]
        } else if let blocks = content as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "tool_result":
                    if let id = block["tool_use_id"] as? String { events.append(.toolFinished(id: id, date)) }
                case "text":
                    if let text = block["text"] as? String { texts.append(text) }
                default: break
                }
            }
        }
        if texts.contains(where: { $0.hasPrefix("[Request interrupted by user") || $0.hasPrefix("<local-command-std") }) {
            return events + [.interrupted(date)]
        }
        // Tool results arrive mid-turn; only real text opens one.
        guard events.isEmpty, !texts.isEmpty else { return events }
        let meta = json["isMeta"] as? Bool == true
        let injected = meta || texts.allSatisfy { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("<task-notification") || trimmed.hasPrefix("<system-reminder")
                || trimmed.hasPrefix("<command-") || trimmed.hasPrefix("Stop hook feedback")
        }
        // Slash-command scaffolding and caveats are not a request to the model.
        if meta && texts.allSatisfy({ $0.hasPrefix("Caveat:") }) { return events }
        return [.prompt(date, injected: injected)]
    }

    /// `(session, agent)` for `.../<session>/subagents/agent-<id>.jsonl`.
    public static func subagentPathInfo(_ path: String) -> (session: String, agent: String)? {
        let parts = path.split(separator: "/").map(String.init)
        guard let index = parts.lastIndex(of: "subagents"), index > 0, index + 1 < parts.count else { return nil }
        var agent = (parts[index + 1] as NSString).deletingPathExtension
        if agent.hasPrefix("agent-") { agent.removeFirst("agent-".count) }
        return (parts[index - 1], agent)
    }

    /// The text of the last main-chain assistant message in a transcript,
    /// used to decide whether Claude ended its turn with a question.
    public static func lastAssistantText(in data: Data) -> String? {
        let lines = data.split(separator: UInt8(ascii: "\n"))
        for raw in lines.reversed() {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any] else { continue }
            if json["isSidechain"] as? Bool == true { continue }
            let type = json["type"] as? String
            if type == "user", let message = json["message"] as? [String: Any], message["content"] is String {
                return nil // A newer prompt: the answer belongs to an older turn.
            }
            guard type == "assistant", let message = json["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { continue }
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// Whether a final answer reads as a question to the person.
    public static func isQuestion(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return false }
        let stripped = last.trimmingCharacters(in: CharacterSet(charactersIn: "*_`)\"'” "))
        return stripped.hasSuffix("?")
    }

    // MARK: Helpers

    private static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return max(0, number.intValue) }
        return 0
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func timestamp(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return isoFractional.date(from: text) ?? isoPlain.date(from: text)
    }
}
