// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import AINotchCore

/// Builds Claude Code transcript lines the way the CLI writes them.
enum Fixture {
    static let base = Date(timeIntervalSince1970: 1_800_000_000)
    static let session = "11111111-2222-3333-4444-555555555555"
    static let mainPath = "/Users/me/.claude/projects/-Users-me-app/\(session).jsonl"
    static func agentPath(_ id: String) -> String {
        "/Users/me/.claude/projects/-Users-me-app/\(session)/subagents/agent-\(id).jsonl"
    }

    static func iso(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: base.addingTimeInterval(offset))
    }

    static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    static func prompt(_ text: String, at t: TimeInterval, sidechain: Bool = false, agent: String? = nil,
                       meta: Bool = false) -> Data {
        var object: [String: Any] = ["type": "user", "sessionId": session, "cwd": "/Users/me/app",
                                     "isSidechain": sidechain, "timestamp": iso(t),
                                     "message": ["role": "user", "content": text]]
        if meta { object["isMeta"] = true }
        if let agent { object["agentId"] = agent }
        return json(object)
    }

    static func toolResult(_ id: String, at t: TimeInterval, sidechain: Bool = false, agent: String? = nil) -> Data {
        var object: [String: Any] = ["type": "user", "sessionId": session, "isSidechain": sidechain, "timestamp": iso(t),
                                     "message": ["role": "user", "content": [
                                         ["type": "tool_result", "tool_use_id": id, "content": "ok"]]]]
        if let agent { object["agentId"] = agent }
        return json(object)
    }

    static func assistant(at t: TimeInterval, stop: String?, tools: [(id: String, name: String)] = [],
                          text: String = "Working on it.", id: String = UUID().uuidString,
                          output: Int = 100, sidechain: Bool = false, agent: String? = nil,
                          model: String = "claude-sonnet-4-5-20250929") -> Data {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        content += tools.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": [:] as [String: Any]] }
        var message: [String: Any] = ["id": id, "model": model, "content": content,
                                      "usage": ["input_tokens": 10, "output_tokens": output,
                                                "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 200]]
        message["stop_reason"] = stop ?? NSNull()
        var object: [String: Any] = ["type": "assistant", "sessionId": session, "cwd": "/Users/me/app",
                                     "isSidechain": sidechain, "timestamp": iso(t), "requestId": "req-\(id)",
                                     "message": message]
        if let agent { object["agentId"] = agent }
        return json(object)
    }
}

extension SessionTracker {
    func feed(_ line: Data, path: String = Fixture.mainPath, now: TimeInterval) {
        let date = Fixture.base.addingTimeInterval(now)
        if let parsed = TranscriptParser.parse(line, path: path, now: date) { ingest(parsed, now: date) }
    }

    func at(_ t: TimeInterval) -> [SessionSnapshot] { snapshots(now: Fixture.base.addingTimeInterval(t)) }

    @discardableResult
    func tick(_ t: TimeInterval) -> [CompletedRun] { tick(now: Fixture.base.addingTimeInterval(t)) }
}
