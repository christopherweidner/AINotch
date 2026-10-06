// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A Claude Code hook invocation as forwarded by `ainotch-hook`.
public struct HookMessage: Sendable {
    public let event: String
    /// The hook's JSON input, as Claude Code wrote it to the hook's stdin.
    public let payload: [String: SendableJSON]
    public let wantsReply: Bool

    public init(event: String, payload: [String: Any], wantsReply: Bool) {
        self.event = event
        self.payload = payload.mapValues(SendableJSON.init)
        self.wantsReply = wantsReply
    }

    public var sessionId: String { payload["session_id"]?.string ?? "unknown" }
    public var cwd: String? { payload["cwd"]?.string }
    public var transcriptPath: String? { payload["transcript_path"]?.string }
    public var toolName: String? { payload["tool_name"]?.string }
    public var toolInput: [String: Any] { payload["tool_input"]?.value as? [String: Any] ?? [:] }

    public func string(_ key: String) -> String? { payload[key]?.string }

    // MARK: Wire format: one JSON object per line.

    public func encoded() -> Data {
        let object: [String: Any] = ["v": 1, "event": event, "wantsReply": wantsReply,
                                     "payload": payload.mapValues(\.value)]
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    public static func decode(_ data: Data) -> HookMessage? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = object["event"] as? String else { return nil }
        return HookMessage(event: event, payload: object["payload"] as? [String: Any] ?? [:],
                           wantsReply: object["wantsReply"] as? Bool ?? false)
    }

    /// Which hook calls wait for the person. Everything else is fire-and-forget,
    /// so Claude Code is never slowed down by the notch.
    public static func wantsReply(event: String, payload: [String: Any]) -> Bool {
        switch event {
        case "PermissionRequest", "Stop": return true
        case "PreToolUse": return payload["tool_name"] as? String == "AskUserQuestion"
        default: return false
        }
    }
}

/// JSON values are not `Sendable`; this box only ever holds immutable
/// property-list types produced by `JSONSerialization`.
public struct SendableJSON: @unchecked Sendable {
    public let value: Any
    public init(_ value: Any) { self.value = value }
    public var string: String? { value as? String }
}

/// A question Claude's `AskUserQuestion` tool asks.
public struct AskedQuestion: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public let label: String
        public let detail: String?
    }

    public let header: String?
    public let question: String
    public let options: [Option]
    public let multiSelect: Bool

    public static func parse(toolInput: [String: Any]) -> [AskedQuestion] {
        (toolInput["questions"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let question = entry["question"] as? String else { return nil }
            let options = (entry["options"] as? [[String: Any]] ?? []).compactMap { option -> Option? in
                guard let label = option["label"] as? String else { return nil }
                return Option(label: label, detail: option["description"] as? String)
            }
            return AskedQuestion(header: entry["header"] as? String, question: question, options: options,
                                 multiSelect: entry["multiSelect"] as? Bool ?? false)
        }
    }
}

/// The JSON a hook prints to hand the person's answer back to Claude Code.
public enum HookReply {
    /// Answers `AskUserQuestion` on the person's behalf. The tool call is
    /// declined with the answer as the reason, which Claude reads and acts on.
    public static func answer(_ answers: [(question: String, answer: String)]) -> String {
        let lines = answers.map { "\"\($0.question)\" → \($0.answer)" }.joined(separator: "\n")
        return json(["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": "The user already answered from the AINotch pop-up. Do not ask again; "
                + "continue using these answers:\n" + lines,
        ]])
    }

    public static func permission(allow: Bool, message: String? = nil) -> String {
        var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if !allow { decision["message"] = message.flatMap { $0.isEmpty ? nil : $0 } ?? "The user denied this from AINotch." }
        return json(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]])
    }

    /// Keeps Claude going after it stopped with a question, with the person's reply.
    public static func continueWith(_ reply: String) -> String {
        json(["decision": "block", "reason": "The user replied from the AINotch pop-up: \(reply)"])
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
