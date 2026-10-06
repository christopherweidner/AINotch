// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import AINotchCore

final class PricingTests: XCTestCase {
    func testLongestPrefixAndDatedIds() {
        XCTAssertEqual(Pricing.price(for: "claude-opus-4-1-20250805")?.input, 15)
        XCTAssertEqual(Pricing.price(for: "claude-opus-4-5-20251101")?.input, 5)
        XCTAssertEqual(Pricing.price(for: "claude-opus-5-5")?.input, 4)
        XCTAssertEqual(Pricing.price(for: "claude-opus-5")?.input, 5)
        XCTAssertEqual(Pricing.price(for: "us.anthropic.claude-sonnet-4-5-20250929-v1:0")?.input, 3)
        XCTAssertEqual(Pricing.price(for: "claude-sonnet-4-5[1m]")?.input, 3)
        XCTAssertNil(Pricing.price(for: "gpt-5"))
    }

    func testCostIncludesCacheTiers() {
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                               cacheWrite: 2_000_000, cacheWriteLong: 1_000_000)
        // haiku 4.5: 1 + 5 + 0.1 + 1.25 + 2
        XCTAssertEqual(Pricing.cost(usage, model: "claude-haiku-4-5-20251001") ?? 0, 9.35, accuracy: 1e-9)
        XCTAssertEqual(Pricing.cost(TokenUsage(output: 1_000_000), model: "claude-opus-5-5", fast: true) ?? 0, 40, accuracy: 1e-9)
    }

    func testLongContextPremium() {
        let usage = TokenUsage(input: 300_000, output: 1000)
        let expected = (300_000.0 * 3 * 2 + 1000 * 15 * 1.5) / 1_000_000
        XCTAssertEqual(Pricing.cost(usage, model: "claude-sonnet-4-5") ?? 0, expected, accuracy: 1e-9)
    }
}

final class ParserTests: XCTestCase {
    func testSubagentPathInfo() {
        let info = TranscriptParser.subagentPathInfo(Fixture.agentPath("abc123"))
        XCTAssertEqual(info?.session, Fixture.session)
        XCTAssertEqual(info?.agent, "abc123")
        XCTAssertNil(TranscriptParser.subagentPathInfo(Fixture.mainPath))
    }

    func testSubagentFileLinesBelongToParentSession() {
        let line = Fixture.assistant(at: 0, stop: "end_turn", sidechain: false)
        let parsed = TranscriptParser.parse(line, path: Fixture.agentPath("q"))
        XCTAssertEqual(parsed?.isSubagent, true)
        XCTAssertEqual(parsed?.agentId, "q")
        XCTAssertEqual(parsed?.sessionId, Fixture.session)
    }

    func testToolResultsDoNotOpenTurns() {
        let parsed = TranscriptParser.parse(Fixture.toolResult("x", at: 0), path: Fixture.mainPath)
        XCTAssertEqual(parsed?.events, [.toolFinished(id: "x", Fixture.base)])
    }

    func testInjectedPrompts() {
        let parsed = TranscriptParser.parse(Fixture.prompt("<task-notification>x</task-notification>", at: 0),
                                            path: Fixture.mainPath)
        XCTAssertEqual(parsed?.events, [.prompt(Fixture.base, injected: true)])
    }

    func testQuestionDetection() {
        XCTAssertTrue(TranscriptParser.isQuestion("I found two options.\n\nShould I use **Postgres**?"))
        XCTAssertTrue(TranscriptParser.isQuestion("Which one do you prefer?)"))
        XCTAssertFalse(TranscriptParser.isQuestion("Is it done? Yes, all tests pass."))
        XCTAssertFalse(TranscriptParser.isQuestion(""))
    }

    func testLastAssistantText() {
        var data = Fixture.prompt("hi", at: 0)
        data.append(0x0A)
        data.append(Fixture.assistant(at: 1, stop: "end_turn", text: "Shall I continue?"))
        data.append(0x0A)
        data.append(Fixture.assistant(at: 2, stop: "end_turn", text: "sub stuff", sidechain: true))
        XCTAssertEqual(TranscriptParser.lastAssistantText(in: data), "Shall I continue?")
    }
}

final class HookInstallerTests: XCTestCase {
    func testInstallPreservesOtherHooksAndIsIdempotent() {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "afplay done.aiff"]]]]],
        ]
        let once = HookInstaller.installing(into: existing, helperPath: "/Applications/AINotch.app/Contents/MacOS/ainotch-hook")
        let twice = HookInstaller.installing(into: once, helperPath: "/Applications/AINotch.app/Contents/MacOS/ainotch-hook")
        XCTAssertTrue(HookInstaller.isInstalled(in: twice))
        XCTAssertEqual(twice["model"] as? String, "opus")
        let stop = (twice["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        XCTAssertEqual(stop?.count, 2, "user hook kept, ours added once")

        let removed = HookInstaller.removing(from: twice)
        XCTAssertFalse(HookInstaller.isInstalled(in: removed))
        let hooks = removed["hooks"] as? [String: Any]
        XCTAssertEqual(hooks?.keys.sorted(), ["Stop"])
    }

    func testCommandQuotesPathWithSpaces() {
        XCTAssertEqual(HookInstaller.command(forHelper: "/Users/a b/AINotch.app/x/ainotch-hook"),
                       "'/Users/a b/AINotch.app/x/ainotch-hook'")
    }

    func testFileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"theme":"dark"}"#.utf8).write(to: url)
        try HookInstaller.install(helperPath: "/tmp/ainotch-hook", at: url)
        XCTAssertTrue(HookInstaller.isInstalled(at: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".ainotch-backup"))
        try HookInstaller.uninstall(at: url)
        XCTAssertFalse(HookInstaller.isInstalled(at: url))
        XCTAssertEqual(try HookInstaller.readSettings(at: url)["theme"] as? String, "dark")
    }
}

final class HookReplyTests: XCTestCase {
    func testRepliesAreValidJSON() throws {
        for reply in [HookReply.answer([("Which DB?", "Postgres")]), HookReply.permission(allow: true),
                      HookReply.permission(allow: false, message: "use rg"), HookReply.continueWith("yes")] {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(reply.utf8)))
        }
        let deny = try JSONSerialization.jsonObject(with: Data(HookReply.permission(allow: false).utf8)) as? [String: Any]
        let decision = (deny?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "deny")
    }

    func testAskedQuestionParsing() {
        let questions = AskedQuestion.parse(toolInput: ["questions": [[
            "question": "Which DB?", "header": "DB", "multiSelect": false,
            "options": [["label": "Postgres", "description": "relational"], ["label": "Redis"]],
        ]]])
        XCTAssertEqual(questions.first?.options.map(\.label), ["Postgres", "Redis"])
    }

    func testWhichEventsBlock() {
        XCTAssertTrue(HookMessage.wantsReply(event: "Stop", payload: [:]))
        XCTAssertTrue(HookMessage.wantsReply(event: "PreToolUse", payload: ["tool_name": "AskUserQuestion"]))
        XCTAssertFalse(HookMessage.wantsReply(event: "PreToolUse", payload: ["tool_name": "Bash"]))
        XCTAssertFalse(HookMessage.wantsReply(event: "SubagentStop", payload: [:]))
    }
}

final class SocketTests: XCTestCase {
    func testBlockingRoundTripAndFireAndForget() throws {
        let path = "/tmp/ainotch-test-\(getpid())-\(Int.random(in: 0...9999)).sock"
        let received = expectation(description: "fire-and-forget delivered")
        let server = HookServer(path: path) { message, responder in
            if message.wantsReply {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    responder.send(HookReply.continueWith("answer for \(message.sessionId)"))
                }
            } else {
                received.fulfill()
            }
        }
        try server.start()
        defer { server.stop() }

        _ = HookClient.send(HookMessage(event: "Notification", payload: ["session_id": "s"], wantsReply: false),
                            socketPath: path, timeout: 5)
        let reply = HookClient.send(HookMessage(event: "Stop", payload: ["session_id": "s1"], wantsReply: true),
                                    socketPath: path, timeout: 5)
        XCTAssertEqual(reply, HookReply.continueWith("answer for s1"))
        wait(for: [received], timeout: 5)
    }

    func testClientIsSilentWhenAppIsNotRunning() {
        XCTAssertNil(HookClient.send(HookMessage(event: "Stop", payload: [:], wantsReply: true),
                                     socketPath: "/tmp/does-not-exist-\(UUID().uuidString).sock", timeout: 1))
    }

    func testResponderNoticesAbandonedHook() throws {
        let path = "/tmp/ainotch-test-abandon-\(getpid()).sock"
        let held = expectation(description: "held")
        let box = Box()
        let server = HookServer(path: path) { _, responder in
            box.responder = responder
            held.fulfill()
        }
        try server.start()
        defer { server.stop() }
        _ = HookClient.send(HookMessage(event: "Stop", payload: [:], wantsReply: true), socketPath: path, timeout: 1)
        wait(for: [held], timeout: 5)
        // The client timed out and closed its end.
        XCTAssertEqual(box.responder?.isAbandoned, true)
    }
}

private final class Box: @unchecked Sendable { var responder: HookResponder? }

final class TailerTests: XCTestCase {
    func testReadsOnlyCompleteAppendedLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try Data("a\nb\npart".utf8).write(to: url)
        let tailer = TranscriptTailer()
        XCTAssertEqual(tailer.newLines(at: url.path).map { String(decoding: $0, as: UTF8.self) }, ["a", "b"])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handle.write(Data("ial\nc\n".utf8))
        try handle.close()
        XCTAssertEqual(tailer.newLines(at: url.path).map { String(decoding: $0, as: UTF8.self) }, ["partial", "c"])
        XCTAssertTrue(tailer.newLines(at: url.path).isEmpty)
    }

    func testCatchUpSkipsPartialFirstLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try Data("xxxxxxxxxx\nlast\n".utf8).write(to: url)
        let tailer = TranscriptTailer()
        tailer.catchUpBytes = 8
        XCTAssertEqual(tailer.newLines(at: url.path).map { String(decoding: $0, as: UTF8.self) }, ["last"])
    }

    func testFormat() {
        XCTAssertEqual(NotchFormat.clock(42), "0:42")
        XCTAssertEqual(NotchFormat.clock(3725), "1:02:05")
        XCTAssertEqual(NotchFormat.tokens(4250), "4.2K")
        XCTAssertEqual(NotchFormat.tokens(48_000), "48K")
        XCTAssertEqual(NotchFormat.cost(0.4234), "$0.42")
        XCTAssertEqual(NotchFormat.cost(148.2), "$148")
    }
}
