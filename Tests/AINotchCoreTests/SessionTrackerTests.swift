// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import AINotchCore

final class SessionTrackerTests: XCTestCase {
    func testSimpleTurnStartsAndFinishesWithTotals() {
        let tracker = SessionTracker()
        tracker.feed(Fixture.prompt("fix the bug", at: 0), now: 0)
        tracker.feed(Fixture.assistant(at: 5, stop: "tool_use", tools: [("t1", "Bash")]), now: 5)
        XCTAssertEqual(tracker.at(6).first?.phase, .working)
        XCTAssertEqual(tracker.at(6).first?.activity, "Running command")
        tracker.feed(Fixture.toolResult("t1", at: 20), now: 20)
        tracker.feed(Fixture.assistant(at: 30, stop: "end_turn", text: "Done."), now: 30)

        XCTAssertTrue(tracker.tick(31).isEmpty, "finish is debounced")
        let done = tracker.tick(40)
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done.first?.duration ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(done.first?.tokens.output, 200)
        XCTAssertGreaterThan(done.first?.cost ?? 0, 0)
        XCTAssertEqual(tracker.at(40).first?.phase, .finished(success: true))
        XCTAssertEqual(tracker.at(40).first?.project, "app")
        XCTAssertTrue(tracker.tick(50).isEmpty, "a run is reported once")
    }

    func testDuplicateUsageLinesCountOnce() {
        let tracker = SessionTracker()
        tracker.feed(Fixture.prompt("hi", at: 0), now: 0)
        tracker.feed(Fixture.assistant(at: 1, stop: nil, id: "msg_1", output: 5), now: 1)
        tracker.feed(Fixture.assistant(at: 2, stop: "end_turn", id: "msg_1", output: 50), now: 2)
        XCTAssertEqual(tracker.at(3).first?.tokens.output, 50)
    }

    /// The bug this project fixes: the main chain goes silent while a
    /// foreground sub-agent works, and the timer must keep running.
    func testForegroundSubagentKeepsRunAlivePastMainIdleLimit() {
        let tracker = SessionTracker()
        tracker.feed(Fixture.prompt("implement the plan with subagents", at: 0), now: 0)
        tracker.feed(Fixture.assistant(at: 10, stop: "tool_use", tools: [("task1", "Task")]), now: 10)
        // The sub-agent writes to its own file for 25 minutes; the main log is silent.
        var t: TimeInterval = 12
        while t < 1500 {
            tracker.feed(Fixture.assistant(at: t, stop: "tool_use", tools: [("s\(Int(t))", "Edit")],
                                           sidechain: true, agent: "a1"), path: Fixture.agentPath("a1"), now: t)
            XCTAssertTrue(tracker.tick(t + 1).isEmpty)
            XCTAssertEqual(tracker.at(t + 1).first?.phase, .working, "still working at \(t)s")
            t += 120
        }
        XCTAssertEqual(tracker.at(t).first?.activeSubagents, 1)
        XCTAssertEqual(tracker.at(t).first?.activity, "Sub-agent")
        tracker.feed(Fixture.assistant(at: 1500, stop: "end_turn", sidechain: true, agent: "a1"),
                     path: Fixture.agentPath("a1"), now: 1500)
        // Hand-off back to the main chain: not finished yet.
        XCTAssertTrue(tracker.tick(1502).isEmpty)
        XCTAssertEqual(tracker.at(1502).first?.phase, .working)
        tracker.feed(Fixture.toolResult("task1", at: 1503), now: 1503)
        tracker.feed(Fixture.assistant(at: 1520, stop: "end_turn"), now: 1520)
        let done = tracker.tick(1530)
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done.first?.duration ?? 0, 1520, accuracy: 0.01)
        // 13 sub-agent steps + its final answer + 2 main responses.
        XCTAssertEqual(done.first?.tokens.output, 100 * 16, "sub-agent tokens count toward the run")
    }

    /// A long tool (test suite) inside a sub-agent writes nothing for minutes.
    func testPendingAgentToolSurvivesSilentSubagent() {
        let tracker = SessionTracker()
        tracker.feed(Fixture.prompt("go", at: 0), now: 0)
        tracker.feed(Fixture.assistant(at: 1, stop: "tool_use", tools: [("task1", "Task")]), now: 1)
        tracker.feed(Fixture.assistant(at: 2, stop: "tool_use", tools: [("b", "Bash")], sidechain: true, agent: "a1"),
                     path: Fixture.agentPath("a1"), now: 2)
        // 14 minutes of silence: longer than the plain idle limit.
        XCTAssertTrue(tracker.tick(14 * 60).isEmpty)
        XCTAssertEqual(tracker.at(14 * 60).first?.phase, .working)
    }

    /// Background agents: the main chain ends its turn while agents still work.
    func testBackgroundSubagentsOutliveMainTurn() {
        let tracker = SessionTracker()
        tracker.feed(Fixture.prompt("run these in the background", at: 0), now: 0)
        tracker.feed(Fixture.assistant(at: 2, stop: "tool_use", tools: [("t1", "Task"), ("t2", "Task")]), now: 2)
        tracker.feed(Fixture.prompt("task A", at: 3, sidechain: true, agent: "a"), path: Fixture.agentPath("a"), now: 3)
        tracker.feed(Fixture.prompt("task B", at: 3, sidechain: true, agent: "b"), path: Fixture.agentPath("b"), now: 3)
        tracker.feed(Fixture.toolResult("t1", at: 4), now: 4)
        tracker.feed(Fixture.toolResult("t2", at: 4), now: 4)
        tracker.feed(Fixture.assistant(at: 6, stop: "end_turn", text: "Both agents are running."), now: 6)

        XCTAssertTrue(tracker.tick(60).isEmpty, "main ended, agents still working")
        XCTAssertEqual(tracker.at(60).first?.phase, .working)
        XCTAssertEqual(tracker.at(60).first?.activeSubagents, 2)
        XCTAssertEqual(tracker.at(60).first?.activity, "2 sub-agents")

        tracker.feed(Fixture.assistant(at: 90, stop: "end_turn", sidechain: true, agent: "a"),
                     path: Fixture.agentPath("a"), now: 90)
        XCTAssertTrue(tracker.tick(120).isEmpty)
        tracker.feed(Fixture.assistant(at: 200, stop: "end_turn", sidechain: true, agent: "b"),
                     path: Fixture.agentPath("b"), now: 200)
        // Claude Code wakes the main agent with a task notification: same run.
        tracker.feed(Fixture.prompt("<task-notification>agent b done</task-notification>", at: 201), now: 201)
        tracker.feed(Fixture.assistant(at: 230, stop: "end_turn", text: "All done."), now: 230)
        let done = tracker.tick(240)
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done.first?.duration ?? 0, 230, accuracy: 0.01, "one timer from prompt to last agent")
    }

    func testTaskNotificationShortlyAfterFinishResumesSameRun() {
        let tracker = SessionTracker()
        tracker.feed(Fixture.prompt("go", at: 0), now: 0)
        tracker.feed(Fixture.assistant(at: 10, stop: "end_turn"), now: 10)
        XCTAssertEqual(tracker.tick(20).count, 1)
        tracker.feed(Fixture.prompt("<task-notification>done</task-notification>", at: 40), now: 40)
        XCTAssertEqual(tracker.at(41).first?.phase, .working)
        XCTAssertEqual(tracker.at(41).first?.startedAt, Fixture.base, "timer keeps its original start")
        tracker.feed(Fixture.assistant(at: 50, stop: "end_turn"), now: 50)
        XCTAssertEqual(tracker.tick(60).first?.duration ?? 0, 50, accuracy: 0.01)
    }

    func testNewHumanPromptStartsFreshRun() {
        let tracker = SessionTracker()
        tracker.feed(Fixture.prompt("one", at: 0), now: 0)
        tracker.feed(Fixture.assistant(at: 10, stop: "end_turn"), now: 10)
        tracker.tick(20)
        tracker.feed(Fixture.prompt("two", at: 30), now: 30)
        XCTAssertEqual(tracker.at(31).first?.startedAt, Fixture.base.addingTimeInterval(30))
        XCTAssertEqual(tracker.at(31).first?.tokens.output, 0)
    }

    func testStopHookDoesNotEndRunWhileSubagentsWork() {
        let tracker = SessionTracker()
        tracker.promptSubmitted(session: Fixture.session, cwd: "/Users/me/app", now: Fixture.base)
        tracker.feed(Fixture.assistant(at: 1, stop: "tool_use", tools: [("t", "Task")]), now: 1)
        tracker.feed(Fixture.prompt("sub", at: 2, sidechain: true, agent: "x"), path: Fixture.agentPath("x"), now: 2)
        tracker.subagentStopped(session: Fixture.session, agentId: "other", now: Fixture.base.addingTimeInterval(3))
        tracker.mainStopped(session: Fixture.session, now: Fixture.base.addingTimeInterval(5))
        XCTAssertTrue(tracker.tick(30).isEmpty)
        tracker.subagentStopped(session: Fixture.session, agentId: "x", now: Fixture.base.addingTimeInterval(40))
        XCTAssertEqual(tracker.tick(50).count, 1)
    }

    func testInterruptEndsRunUnsuccessfully() {
        let tracker = SessionTracker()
        tracker.feed(Fixture.prompt("go", at: 0), now: 0)
        tracker.feed(Fixture.assistant(at: 1, stop: "tool_use", tools: [("t", "Task")]), now: 1)
        tracker.feed(Fixture.prompt("sub", at: 2, sidechain: true, agent: "x"), path: Fixture.agentPath("x"), now: 2)
        tracker.feed(Fixture.prompt("[Request interrupted by user for tool use]", at: 5), now: 5)
        let done = tracker.tick(20)
        XCTAssertEqual(done.first?.success, false)
    }

    func testStalledTurnIsHiddenWithoutCelebration() {
        let tracker = SessionTracker()
        tracker.feed(Fixture.prompt("go", at: 0), now: 0)
        tracker.feed(Fixture.assistant(at: 1, stop: nil), now: 1)
        XCTAssertTrue(tracker.tick(11 * 60).isEmpty)
        XCTAssertTrue(tracker.at(11 * 60).isEmpty)
    }

    func testHistoryReadAtLaunchDoesNotReportOldRuns() {
        let tracker = SessionTracker()
        tracker.feed(Fixture.prompt("old", at: 0), now: 3600)
        tracker.feed(Fixture.assistant(at: 10, stop: "end_turn"), now: 3600)
        XCTAssertTrue(tracker.tick(3601).isEmpty)
        XCTAssertTrue(tracker.at(3601).isEmpty)
    }

    func testAppLaunchedMidSubagentPicksUpRun() {
        let tracker = SessionTracker()
        tracker.feed(Fixture.assistant(at: 100, stop: "tool_use", tools: [("e", "Edit")], sidechain: true, agent: "z"),
                     path: Fixture.agentPath("z"), now: 101)
        XCTAssertEqual(tracker.at(102).first?.phase, .working)
    }

    func testAttentionAndReplyResumesRun() {
        let tracker = SessionTracker()
        tracker.feed(Fixture.prompt("go", at: 0), now: 0)
        tracker.feed(Fixture.assistant(at: 10, stop: "end_turn", text: "Which database should I use?"), now: 10)
        tracker.setAttention(session: Fixture.session, message: "Which database should I use?",
                             now: Fixture.base.addingTimeInterval(11))
        XCTAssertEqual(tracker.at(12).first?.phase, .needsInput)
        // The person takes five minutes to answer.
        tracker.tick(300)
        tracker.replied(session: Fixture.session, now: Fixture.base.addingTimeInterval(300))
        tracker.feed(Fixture.assistant(at: 310, stop: "end_turn"), now: 310)
        XCTAssertEqual(tracker.at(311).first?.startedAt, Fixture.base)
        XCTAssertEqual(tracker.tick(320).first?.duration ?? 0, 310, accuracy: 0.01)
    }

    func testAcknowledgeClearsFinishedIndicator() {
        let tracker = SessionTracker()
        tracker.feed(Fixture.prompt("go", at: 0), now: 0)
        tracker.feed(Fixture.assistant(at: 1, stop: "end_turn"), now: 1)
        tracker.tick(10)
        tracker.acknowledge(session: Fixture.session)
        XCTAssertTrue(tracker.at(11).isEmpty)
    }

    func testNotificationAttentionClearsWhenClaudeMovesOn() {
        let tracker = SessionTracker()
        tracker.feed(Fixture.prompt("go", at: 0), now: 0)
        tracker.feed(Fixture.assistant(at: 1, stop: "tool_use", tools: [("b", "Bash")]), now: 1)
        // A line written before the notification arrives late: still waiting.
        tracker.setAttention(session: Fixture.session, message: "Claude needs your permission to use Bash",
                             now: Fixture.base.addingTimeInterval(2))
        tracker.feed(Fixture.assistant(at: 1.5, stop: "tool_use", tools: [("c", "Read")]), now: 2.2)
        XCTAssertEqual(tracker.at(3).first?.phase, .needsInput)
        // Approved in the terminal: the tool returns.
        tracker.feed(Fixture.toolResult("b", at: 30), now: 30)
        XCTAssertEqual(tracker.at(31).first?.phase, .working)
    }
}
