// SPDX-License-Identifier: GPL-3.0-or-later

import AINotchCore
import AppKit
import SwiftUI

/// Something Claude is waiting on the person for, shown as a pop-up card.
struct Interaction: Identifiable {
    enum Kind {
        /// `AskUserQuestion`: answers go back through the PreToolUse hook.
        case questions([AskedQuestion])
        /// A tool needs permission: allow or deny through PermissionRequest.
        case permission(tool: String, detail: String)
        /// Claude ended its turn with a question: a reply continues it through Stop.
        case followUp(String)
        /// A Notification hook message; nothing to send back.
        case notice(String)
    }

    let id = UUID()
    let sessionId: String
    let project: String
    let kind: Kind
    let responder: HookResponder?
    let created = Date()
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [SessionSnapshot] = []
    @Published private(set) var interactions: [Interaction] = []
    /// The run that just ended, shown with its totals for a moment.
    @Published private(set) var celebration: CompletedRun?
    @Published var isHovering = false
    @Published private(set) var hooksInstalled = HookInstaller.isInstalled()

    @AppStorage("answerFromNotch") var answerFromNotch = true
    @AppStorage("holdOnQuestions") var holdOnQuestions = true
    /// Seconds a card waits before handing the question back to Claude.
    @AppStorage("replyTimeout") var replyTimeout = 600.0

    let tracker = SessionTracker()
    private var watcher: TranscriptWatcher?
    private var server: HookServer?
    private var clock: Timer?
    private var celebrationTask: Task<Void, Never>?

    var interaction: Interaction? { interactions.first }
    var primary: SessionSnapshot? { sessions.first }
    var workingCount: Int { sessions.filter { $0.phase == .working }.count }

    nonisolated static var helperPath: String {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.deletingLastPathComponent().appendingPathComponent("ainotch-hook").path
    }

    func start() {
        let server = HookServer(path: AINotchPaths.socket.path) { [weak self] message, responder in
            Task { @MainActor in self?.handle(message, responder: responder) }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("AINotch: hook socket unavailable: \(error)")
        }
        let watcher = TranscriptWatcher(root: AINotchPaths.claudeDirectory.appendingPathComponent("projects")) { [weak self] lines in
            Task { @MainActor in self?.ingest(lines) }
        }
        watcher.start()
        self.watcher = watcher
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        server?.stop()
        watcher?.stop()
        for interaction in interactions { interaction.responder?.send(nil) }
    }

    // MARK: Transcript input

    private func ingest(_ lines: [TranscriptLine]) {
        let now = Date()
        for line in lines { tracker.ingest(line, now: now) }
        refresh(now: now)
    }

    private func tick() {
        let now = Date()
        for run in tracker.tick(now: now) where run.success {
            celebrate(run)
        }
        // Close cards whose hook is gone (Esc in the terminal, timeout).
        for interaction in interactions {
            let expired = now.timeIntervalSince(interaction.created) > replyTimeout
            if interaction.responder?.isAbandoned == true || expired {
                dismiss(interaction, sendEmpty: true)
            }
        }
        // A notice goes away once Claude carries on.
        let waiting = Set(tracker.snapshots(now: now).filter { $0.attention != nil }.map(\.id))
        for interaction in interactions {
            if case .notice = interaction.kind, !waiting.contains(interaction.sessionId) {
                remove(interaction)
            }
        }
        refresh(now: now)
    }

    private func refresh(now: Date = Date()) {
        let next = tracker.snapshots(now: now)
        if next != sessions {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { sessions = next }
        }
    }

    private func celebrate(_ run: CompletedRun) {
        celebrationTask?.cancel()
        withAnimation(.spring()) { celebration = run }
        NSSound(named: "Glass")?.play()
        celebrationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.spring()) { self?.celebration = nil }
        }
    }

    // MARK: Hook input

    private func handle(_ message: HookMessage, responder: HookResponder) {
        let now = Date()
        let session = message.sessionId
        switch message.event {
        case "UserPromptSubmit":
            tracker.promptSubmitted(session: session, cwd: message.cwd, now: now)
        case "PreToolUse":
            let questions = AskedQuestion.parse(toolInput: message.toolInput)
            guard answerFromNotch, !questions.isEmpty else { return responder.send(nil) }
            present(Interaction(sessionId: session, project: project(message), kind: .questions(questions),
                                responder: responder), attention: questions.first?.question)
        case "PermissionRequest":
            guard answerFromNotch else { return responder.send(nil) }
            let tool = message.toolName ?? "a tool"
            present(Interaction(sessionId: session, project: project(message),
                                kind: .permission(tool: tool, detail: Self.describe(tool: tool, input: message.toolInput)),
                                responder: responder), attention: "Permission: \(tool)")
        case "Notification":
            let text = message.string("message") ?? "Claude needs your attention"
            // Idle reminders repeat what the completion indicator already says,
            // and permission prompts already have their own card.
            let type = message.string("notification_type") ?? ""
            let covered = type == "idle_prompt" || interactions.contains { $0.sessionId == session }
                || (type == "permission_prompt" && answerFromNotch && hooksInstalled)
            if !covered {
                present(Interaction(sessionId: session, project: project(message), kind: .notice(text), responder: nil),
                        attention: text)
            }
        case "Stop":
            stopped(message, responder: responder, now: now)
        case "SubagentStop":
            let agent = message.string("agent_id") ?? message.string("agent_transcript_path")
                .flatMap { TranscriptParser.subagentPathInfo($0)?.agent }
            tracker.subagentStopped(session: session, agentId: agent, now: now)
        case "SessionEnd":
            tracker.sessionEnded(session: session, now: now)
            for interaction in interactions where interaction.sessionId == session {
                dismiss(interaction, sendEmpty: true)
            }
        default:
            break
        }
        refresh(now: now)
    }

    /// Claude finished its turn. If its last words were a question, keep the
    /// session open and ask in the notch; a reply makes Claude continue.
    private func stopped(_ message: HookMessage, responder: HookResponder, now: Date) {
        let text = message.string("last_assistant_message") ?? message.transcriptPath.flatMap { Self.lastAssistantText(transcript: $0) }
        guard answerFromNotch, holdOnQuestions, let text, TranscriptParser.isQuestion(text) else {
            responder.send(nil)
            tracker.mainStopped(session: message.sessionId, now: now)
            return
        }
        present(Interaction(sessionId: message.sessionId, project: project(message), kind: .followUp(text),
                            responder: responder), attention: text)
    }

    private func present(_ interaction: Interaction, attention: String?) {
        tracker.setAttention(session: interaction.sessionId, message: attention ?? "Waiting", cwd: nil)
        withAnimation(.spring()) { interactions.append(interaction) }
    }

    private func project(_ message: HookMessage) -> String {
        if let known = tracker.project(of: message.sessionId), !known.isEmpty { return known }
        return message.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude"
    }

    // MARK: Answers

    func answer(_ interaction: Interaction, with answers: [(question: String, answer: String)]) {
        interaction.responder?.send(HookReply.answer(answers))
        finish(interaction, replied: false)
    }

    func permit(_ interaction: Interaction, allow: Bool, message: String? = nil) {
        interaction.responder?.send(HookReply.permission(allow: allow, message: message))
        finish(interaction, replied: false)
    }

    func reply(_ interaction: Interaction, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        interaction.responder?.send(HookReply.continueWith(trimmed))
        finish(interaction, replied: true)
    }

    /// Hands the question back to Claude's own UI.
    func dismiss(_ interaction: Interaction, sendEmpty: Bool = true) {
        if sendEmpty { interaction.responder?.send(nil) }
        remove(interaction)
        if case .followUp = interaction.kind, !hasPending(interaction.sessionId) {
            // Nobody answered: the turn really ended.
            tracker.mainStopped(session: interaction.sessionId)
        }
        refresh()
    }

    private func finish(_ interaction: Interaction, replied: Bool) {
        remove(interaction)
        if replied { tracker.replied(session: interaction.sessionId) }
        refresh()
    }

    private func remove(_ interaction: Interaction) {
        withAnimation(.spring()) { interactions.removeAll { $0.id == interaction.id } }
        // Another card for the same session keeps it waiting on the person.
        let next = interactions.first { $0.sessionId == interaction.sessionId }
        tracker.setAttention(session: interaction.sessionId, message: next.map { _ in "Waiting" })
    }

    private func hasPending(_ session: String) -> Bool {
        interactions.contains { $0.sessionId == session }
    }

    // MARK: Completion indicator

    /// Clicking the "done" indicator brings Claude forward and clears it.
    func openClaude(acknowledging session: String? = nil) {
        ClaudeLauncher.open()
        if let session { tracker.acknowledge(session: session) } else { tracker.acknowledgeAllFinished() }
        withAnimation(.spring()) { celebration = nil }
        refresh()
    }

    // MARK: Hooks

    func setHooksInstalled(_ install: Bool) {
        do {
            if install {
                try HookInstaller.install(helperPath: Self.helperPath)
            } else {
                try HookInstaller.uninstall()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not update \(HookInstaller.settingsURL.path)"
            alert.runModal()
        }
        hooksInstalled = HookInstaller.isInstalled()
    }

    // MARK: Helpers

    private static func lastAssistantText(transcript path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 512 << 10 ? size - (512 << 10) : 0)
        return (try? handle.readToEnd()).flatMap(TranscriptParser.lastAssistantText)
    }

    static func describe(tool: String, input: [String: Any]) -> String {
        for key in ["command", "file_path", "url", "pattern", "path", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty { return String(value.prefix(400)) }
        }
        return ""
    }
}
