// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Token counts for one or more API responses.
public struct TokenUsage: Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    /// All cache writes, including the one-hour ones counted in `cacheWriteLong`.
    public var cacheWrite = 0
    public var cacheWriteLong = 0

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, cacheWriteLong: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWriteLong = cacheWriteLong
    }

    public var total: Int { input + output + cacheRead + cacheWrite }
    /// Everything the model read for this request.
    public var prompt: Int { input + cacheRead + cacheWrite }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                   cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
                   cacheWriteLong: lhs.cacheWriteLong + rhs.cacheWriteLong)
    }

    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) { lhs = lhs + rhs }
}

/// One API response's usage as read from a transcript. Claude Code writes a
/// line per content block, repeating the same response; `key` deduplicates them.
public struct UsageSample: Equatable, Sendable {
    public let key: String
    public let model: String
    public let usage: TokenUsage
    public let fast: Bool
    public let date: Date

    public init(key: String, model: String, usage: TokenUsage, fast: Bool = false, date: Date) {
        self.key = key
        self.model = model
        self.usage = usage
        self.fast = fast
        self.date = date
    }

    public var cost: Double { Pricing.cost(usage, model: model, fast: fast) ?? 0 }
}

/// What the notch shows for a session.
public enum SessionPhase: Equatable, Sendable {
    /// Claude (or one of its sub-agents) is working.
    case working
    /// Claude asked something or wants permission.
    case needsInput
    /// The last run ended; `success` is false when it was interrupted.
    case finished(success: Bool)
    /// Nothing to show.
    case idle
}

public struct SessionSnapshot: Identifiable, Equatable, Sendable {
    public let id: String
    public var project: String
    public var model: String
    public var phase: SessionPhase
    public var startedAt: Date?
    public var endedAt: Date?
    public var tokens: TokenUsage
    public var cost: Double
    public var activeSubagents: Int
    /// A short label for what is happening right now, like "Bash" or "Editing".
    public var activity: String?
    /// Why the session needs the person, from a Notification hook.
    public var attention: String?
    public var lastActivity: Date

    public func elapsed(at now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (phase == .working || phase == .needsInput ? now : (endedAt ?? now)).timeIntervalSince(startedAt))
    }
}
