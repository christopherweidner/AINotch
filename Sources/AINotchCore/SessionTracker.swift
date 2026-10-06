// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A finished run, reported once when it ends.
public struct CompletedRun: Equatable, Sendable {
    public let sessionId: String
    public let project: String
    public let duration: TimeInterval
    public let tokens: TokenUsage
    public let cost: Double
    public let success: Bool
}

/// Folds transcript lines and hook events into per-session state.
///
/// A *run* lasts from the person's prompt until Claude **and every sub-agent it
/// started** are done. The main chain going quiet while a Task/Agent tool runs,
/// or the main chain ending its turn while background agents still work, does
/// not end the run: the timer keeps going until the last agent finishes.
public final class SessionTracker {
    public struct Configuration: Sendable {
        /// A main turn with no pending tool and no live sub-agent that writes
        /// nothing for this long has stalled (its process died, or it waits on
        /// something we cannot see).
        public var idleTurn: TimeInterval = 10 * 60
        /// Upper bound while a tool or sub-agent is pending: long builds and
        /// test suites write nothing until they return.
        public var idleWithPendingWork: TimeInterval = 60 * 60
        /// A sub-agent that wrote nothing for this long is gone.
        public var idleSubagent: TimeInterval = 15 * 60
        /// When the main chain ends, sub-agents silent this long are presumed done.
        public var subagentGraceAtMainEnd: TimeInterval = 3 * 60
        /// Work must be over this long before the run counts as finished, so a
        /// sub-agent hand-off or a background task's wake-up does not flash
        /// "done".
        public var finishDebounce: TimeInterval = 4
        /// A continuation (background task notification, a reply sent from the
        /// notch) this soon after the end resumes the same run and timer.
        public var resumeWindow: TimeInterval = 120
        /// A run found already over by more than this (read from history at
        /// launch) is dropped without a completion indicator.
        public var lateFinish: TimeInterval = 120
        /// Finished sessions stop being reported after this long.
        public var forgetFinished: TimeInterval = 6 * 3600

        public init() {}
    }

    struct Subagent {
        var lastActivity: Date
        var finished = false
    }

    struct Run {
        var started: Date
        var usage: [String: UsageSample] = [:]
        var ended: Date?
        var success = true
        var reported = false

        var tokens: TokenUsage { usage.values.reduce(TokenUsage()) { $0 + $1.usage } }
        var cost: Double { usage.values.reduce(0) { $0 + $1.cost } }
    }

    struct Session {
        let id: String
        var project = ""
        var model = ""
        var turnOpen = false
        var lastActivity: Date
        var pendingTools: [String: String] = [:]
        var subagents: [String: Subagent] = [:]
        var run: Run?
        var activity: String?
        var attention: String?
        var attentionSince: Date?
        /// A reply was sent from the notch: the next model activity resumes the run.
        var resumeNext = false
        /// Work stopped at this moment; the run ends once the debounce passes.
        var quietSince: Date?
    }

    public var configuration: Configuration
    private var sessions: [String: Session] = [:]

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: Transcript input

    public func ingest(_ line: TranscriptLine, now: Date = Date()) {
        var session = sessions[line.sessionId] ?? Session(id: line.sessionId, lastActivity: .distantPast)
        if let cwd = line.cwd, !line.isSubagent, !cwd.isEmpty { session.project = Self.projectName(cwd) }
        if line.isSubagent {
            ingestSubagent(line, into: &session, now: now)
        } else {
            for event in line.events { apply(event, to: &session, now: now) }
        }
        sessions[line.sessionId] = session
    }

    private func ingestSubagent(_ line: TranscriptLine, into session: inout Session, now: Date) {
        let key = line.agentId ?? "agent"
        var agent = session.subagents[key] ?? Subagent(lastActivity: .distantPast)
        for event in line.events {
            switch event {
            case .turnEnded(let date, _), .interrupted(let date):
                agent.finished = true
                agent.lastActivity = max(agent.lastActivity, date)
            case .prompt(let date, _), .progress(let date), .toolStarted(_, _, let date), .toolFinished(_, let date):
                if case .prompt = event { agent.finished = false }
                agent.lastActivity = max(agent.lastActivity, date)
                guard !agent.finished, now.timeIntervalSince(date) < configuration.idleSubagent else { continue }
                ensureSubagentRun(&session, at: date)
                touch(&session, at: date, now: now)
                if case .toolStarted(_, let name, _) = event { session.activity = Self.label(forTool: name) }
            case .usage(let sample):
                // A sub-agent's tokens count toward the run it serves.
                agent.lastActivity = max(agent.lastActivity, sample.date)
                if !agent.finished, now.timeIntervalSince(sample.date) < configuration.idleSubagent {
                    ensureSubagentRun(&session, at: sample.date)
                    touch(&session, at: sample.date, now: now)
                }
                session.run?.usage[sample.key] = sample
            }
        }
        session.subagents[key] = agent
    }

    /// A working sub-agent always belongs to a live run: one the app missed
    /// the start of (launched mid-flight), or one that just "finished".
    private func ensureSubagentRun(_ session: inout Session, at date: Date) {
        if let run = session.run, run.ended == nil { return }
        if session.run != nil, canResume(session, at: date) {
            resume(&session, at: date)
        } else {
            session.run = Run(started: date)
            session.quietSince = nil
        }
    }

    private func apply(_ event: TranscriptEvent, to session: inout Session, now: Date) {
        // Anything Claude writes after asking means it moved on (the person
        // answered in the terminal or the app).
        if let since = session.attentionSince, Self.date(of: event).timeIntervalSince(since) > 1 {
            session.attention = nil
            session.attentionSince = nil
        }
        switch event {
        case .prompt(let date, let injected):
            session.attention = nil
            session.attentionSince = nil
            if injected {
                // Claude Code waking itself (a background agent finished):
                // continue the same run if it ended moments ago.
                if canResume(session, at: date) { resume(&session, at: date) }
            } else if !session.turnOpen || session.run == nil {
                beginRun(&session, at: date)
            }
            session.turnOpen = true
            touch(&session, at: date, now: now)
        case .usage(let sample):
            session.model = sample.model
            ensureRun(&session, at: sample.date)
            session.run?.usage[sample.key] = sample
            touch(&session, at: sample.date, now: now)
        case .toolStarted(let id, let name, let date):
            ensureRun(&session, at: date)
            session.pendingTools[id] = name
            session.activity = Self.label(forTool: name)
            session.turnOpen = true
            touch(&session, at: date, now: now)
        case .toolFinished(let id, let date):
            session.pendingTools[id] = nil
            touch(&session, at: date, now: now)
        case .progress(let date):
            ensureRun(&session, at: date)
            session.turnOpen = true
            touch(&session, at: date, now: now)
        case .turnEnded(let date, let completed):
            session.turnOpen = false
            session.pendingTools.removeAll()
            session.activity = nil
            if !completed { session.run?.success = false }
            touch(&session, at: date, now: now)
            retireSilentSubagents(&session, at: date)
        case .interrupted(let date):
            session.turnOpen = false
            session.pendingTools.removeAll()
            session.activity = nil
            session.run?.success = false
            // Esc stops sub-agents too.
            for key in session.subagents.keys { session.subagents[key]?.finished = true }
            touch(&session, at: date, now: now)
        }
    }

    // MARK: Hook input

    public func promptSubmitted(session id: String, cwd: String?, now: Date = Date()) {
        var session = sessions[id] ?? Session(id: id, lastActivity: now)
        if let cwd, !cwd.isEmpty { session.project = Self.projectName(cwd) }
        apply(.prompt(now, injected: false), to: &session, now: now)
        sessions[id] = session
    }

    /// The main agent stopped (Stop hook). Sub-agents may still be working.
    public func mainStopped(session id: String, now: Date = Date()) {
        guard var session = sessions[id], session.turnOpen else { return }
        apply(.turnEnded(now, completed: true), to: &session, now: now)
        sessions[id] = session
    }

    public func subagentStopped(session id: String, agentId: String?, now: Date = Date()) {
        guard var session = sessions[id], let agentId, session.subagents[agentId] != nil else { return }
        session.subagents[agentId]?.finished = true
        sessions[id] = session
    }

    public func setAttention(session id: String, message: String?, cwd: String? = nil, now: Date = Date()) {
        var session = sessions[id] ?? Session(id: id, lastActivity: now)
        if let cwd, !cwd.isEmpty, session.project.isEmpty { session.project = Self.projectName(cwd) }
        session.attention = message
        session.attentionSince = message == nil ? nil : now
        if message == nil { session.quietSince = now }
        sessions[id] = session
    }

    /// The person answered from the notch; Claude will carry on in the same run.
    public func replied(session id: String, now: Date = Date()) {
        guard var session = sessions[id] else { return }
        session.attention = nil
        session.attentionSince = nil
        session.resumeNext = true
        if canResume(session, at: now) { resume(&session, at: now) }
        session.turnOpen = true
        session.lastActivity = now
        sessions[id] = session
    }

    public func sessionEnded(session id: String, now: Date = Date()) {
        guard var session = sessions[id] else { return }
        session.turnOpen = false
        session.pendingTools.removeAll()
        for key in session.subagents.keys { session.subagents[key]?.finished = true }
        session.attention = nil
        session.attentionSince = nil
        sessions[id] = session
    }

    /// Hides a finished session's completion indicator.
    public func acknowledge(session id: String) {
        guard sessions[id]?.run?.ended != nil else { return }
        sessions[id]?.run = nil
    }

    public func acknowledgeAllFinished() {
        for (id, session) in sessions where session.run?.ended != nil { sessions[id]?.run = nil }
    }

    // MARK: Clock

    /// Advances time: ends runs whose work is over and returns them once.
    @discardableResult
    public func tick(now: Date = Date()) -> [CompletedRun] {
        var finished: [CompletedRun] = []
        for id in sessions.keys {
            guard var session = sessions[id] else { continue }
            defer { sessions[id] = session }
            if session.run?.ended == nil, session.run != nil {
                if session.attention != nil {
                    // Waiting on the person is part of the run, not its end.
                    session.quietSince = now
                    continue
                }
                if isWorking(session, now: now) {
                    session.quietSince = nil
                    continue
                }
                if session.turnOpen, now.timeIntervalSince(session.lastActivity) >= idleLimit(session) {
                    // Stalled: hide it without a celebration.
                    session.turnOpen = false
                    session.pendingTools.removeAll()
                    session.run?.success = false
                }
                let quiet = session.quietSince ?? lastWork(session)
                session.quietSince = quiet
                guard now.timeIntervalSince(quiet) >= configuration.finishDebounce else { continue }
                if now.timeIntervalSince(quiet) > configuration.lateFinish {
                    // History read at launch: nothing new finished.
                    session.run = nil
                    continue
                }
                session.run?.ended = quiet
                session.activity = nil
                if var run = session.run, !run.reported {
                    run.reported = true
                    session.run = run
                    finished.append(CompletedRun(sessionId: id, project: session.project,
                                                 duration: max(0, quiet.timeIntervalSince(run.started)),
                                                 tokens: run.tokens, cost: run.cost, success: run.success))
                }
            } else if let ended = session.run?.ended, now.timeIntervalSince(ended) > configuration.forgetFinished {
                session.run = nil
            }
        }
        sessions = sessions.filter { _, session in
            session.run != nil || session.attention != nil
                || now.timeIntervalSince(session.lastActivity) < configuration.forgetFinished
        }
        return finished
    }

    // MARK: Output

    public func snapshots(now: Date = Date()) -> [SessionSnapshot] {
        sessions.values.compactMap { session -> SessionSnapshot? in
            let phase: SessionPhase
            if session.attention != nil {
                phase = .needsInput
            } else if let run = session.run {
                phase = run.ended == nil ? .working : .finished(success: run.success)
            } else {
                return nil
            }
            let live = activeSubagents(session, now: now)
            var activity = session.activity
            if live > 0, session.pendingTools.values.allSatisfy({ TranscriptParser.agentTools.contains($0) }) {
                activity = live == 1 ? "Sub-agent" : "\(live) sub-agents"
            }
            return SessionSnapshot(id: session.id, project: session.project, model: session.model, phase: phase,
                                   startedAt: session.run?.started, endedAt: session.run?.ended,
                                   tokens: session.run?.tokens ?? TokenUsage(), cost: session.run?.cost ?? 0,
                                   activeSubagents: live, activity: phase == .working ? activity : nil,
                                   attention: session.attention, lastActivity: session.lastActivity)
        }
        .sorted { lhs, rhs in
            if Self.rank(lhs.phase) != Self.rank(rhs.phase) { return Self.rank(lhs.phase) < Self.rank(rhs.phase) }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    public func project(of id: String) -> String? { sessions[id]?.project }

    // MARK: Rules

    func isWorking(_ session: Session, now: Date) -> Bool {
        if activeSubagents(session, now: now) > 0 { return true }
        guard session.turnOpen else { return false }
        return now.timeIntervalSince(session.lastActivity) < idleLimit(session)
    }

    private func idleLimit(_ session: Session) -> TimeInterval {
        session.pendingTools.isEmpty ? configuration.idleTurn : configuration.idleWithPendingWork
    }

    func activeSubagents(_ session: Session, now: Date) -> Int {
        session.subagents.values.filter {
            !$0.finished && now.timeIntervalSince($0.lastActivity) < configuration.idleSubagent
        }.count
    }

    private func lastWork(_ session: Session) -> Date {
        session.subagents.values.map(\.lastActivity).reduce(session.lastActivity, max)
    }

    /// When the main chain answers, a foreground sub-agent has necessarily
    /// returned; only background agents that are still writing stay live.
    private func retireSilentSubagents(_ session: inout Session, at date: Date) {
        for (key, agent) in session.subagents
        where !agent.finished && date.timeIntervalSince(agent.lastActivity) > configuration.subagentGraceAtMainEnd {
            session.subagents[key]?.finished = true
        }
    }

    private func canResume(_ session: Session, at date: Date) -> Bool {
        guard let run = session.run else { return false }
        guard let ended = run.ended else { return true }
        return session.resumeNext || date.timeIntervalSince(ended) <= configuration.resumeWindow
    }

    private func resume(_ session: inout Session, at date: Date) {
        session.run?.ended = nil
        session.run?.reported = false
        session.run?.success = true
        session.quietSince = nil
        session.resumeNext = false
    }

    private func beginRun(_ session: inout Session, at date: Date) {
        session.run = Run(started: date)
        session.subagents = session.subagents.filter { !$0.value.finished }
        session.pendingTools.removeAll()
        session.quietSince = nil
        session.resumeNext = false
        session.attention = nil
        session.attentionSince = nil
    }

    /// Model activity with no run: resume after a notch reply, else start one
    /// (the app launched mid-turn, or the prompt line was missed).
    private func ensureRun(_ session: inout Session, at date: Date) {
        if let run = session.run, run.ended == nil { return }
        if session.run != nil, canResume(session, at: date) {
            resume(&session, at: date)
        } else {
            beginRun(&session, at: date)
        }
        session.turnOpen = true
    }

    private func touch(_ session: inout Session, at date: Date, now: Date) {
        session.lastActivity = max(session.lastActivity, min(date, now))
        session.quietSince = nil
    }

    private static func date(of event: TranscriptEvent) -> Date {
        switch event {
        case .prompt(let date, _), .progress(let date), .toolStarted(_, _, let date), .toolFinished(_, let date),
             .turnEnded(let date, _), .interrupted(let date):
            return date
        case .usage(let sample):
            return sample.date
        }
    }

    private static func rank(_ phase: SessionPhase) -> Int {
        switch phase {
        case .needsInput: return 0
        case .working: return 1
        case .finished: return 2
        case .idle: return 3
        }
    }

    static func projectName(_ cwd: String) -> String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// A compact label for the notch.
    public static func label(forTool name: String) -> String {
        switch name {
        case "Task", "Agent": return "Sub-agent"
        case "Bash", "BashOutput": return "Running command"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Editing"
        case "Read", "Grep", "Glob", "LS": return "Reading"
        case "WebFetch", "WebSearch": return "Browsing"
        case "TodoWrite": return "Planning"
        case "AskUserQuestion": return "Asking"
        default: return name.hasPrefix("mcp__") ? (name.split(separator: "_").last.map(String.init) ?? name) : name
        }
    }
}
