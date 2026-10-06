// SPDX-License-Identifier: GPL-3.0-or-later
// Price table adapted from vorssaint-utils (GPL-3.0-or-later), Resources/agent-prices.json.

import Foundation

/// US dollars per million tokens, from Anthropic's published API prices.
public struct ModelPrice: Equatable, Sendable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double
    public let cacheWriteLong: Double
    public var fastMultiplier: Double = 1
    /// Prompts above this many tokens bill input at `longInput`x and output at `longOutput`x.
    public var longContextAbove: Int? = nil
    public var longInput: Double = 1
    public var longOutput: Double = 1
}

public enum Pricing {
    /// Matched by longest prefix, so dated ids like `claude-sonnet-4-5-20250929` resolve.
    public static let table: [(id: String, price: ModelPrice)] = [
        ("claude-fable-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5, cacheWriteLong: 20)),
        ("claude-mythos-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5, cacheWriteLong: 20)),
        ("claude-fable-5", ModelPrice(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5, cacheWriteLong: 20)),
        ("claude-mythos-5", ModelPrice(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5, cacheWriteLong: 20)),
        ("claude-mythos-preview", ModelPrice(input: 25, output: 125, cacheRead: 2.5, cacheWrite: 31.25, cacheWriteLong: 50)),
        ("claude-opus-5-5", ModelPrice(input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5, cacheWriteLong: 8, fastMultiplier: 2)),
        ("claude-opus-5", ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, cacheWriteLong: 10, fastMultiplier: 2)),
        ("claude-opus-4-8", ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, cacheWriteLong: 10, fastMultiplier: 2)),
        ("claude-opus-4-7", ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, cacheWriteLong: 10)),
        ("claude-opus-4-6", ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, cacheWriteLong: 10)),
        ("claude-opus-4-5", ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, cacheWriteLong: 10)),
        ("claude-opus-4-1", ModelPrice(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75, cacheWriteLong: 30)),
        ("claude-opus-4", ModelPrice(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75, cacheWriteLong: 30)),
        ("claude-sonnet-5-5", ModelPrice(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5, cacheWriteLong: 4)),
        ("claude-sonnet-5", ModelPrice(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5, cacheWriteLong: 4)),
        ("claude-sonnet-4-6", ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75, cacheWriteLong: 6)),
        ("claude-sonnet-4-5", ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75, cacheWriteLong: 6,
                                         longContextAbove: 200_000, longInput: 2, longOutput: 1.5)),
        ("claude-sonnet-4", ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75, cacheWriteLong: 6,
                                       longContextAbove: 200_000, longInput: 2, longOutput: 1.5)),
        ("claude-3-7-sonnet", ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75, cacheWriteLong: 6)),
        ("claude-3-5-sonnet", ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75, cacheWriteLong: 6)),
        ("claude-haiku-4-5", ModelPrice(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25, cacheWriteLong: 2)),
        ("claude-3-5-haiku", ModelPrice(input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1, cacheWriteLong: 1.6)),
        ("claude-3-opus", ModelPrice(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75, cacheWriteLong: 30)),
        ("claude-3-haiku", ModelPrice(input: 0.25, output: 1.25, cacheRead: 0.03, cacheWrite: 0.3, cacheWriteLong: 0.5)),
    ]

    /// Strips provider prefixes and suffixes like `[1m]` or `anthropic.` so
    /// Bedrock/Vertex ids price like the first-party ones.
    public static func normalize(_ model: String) -> String {
        var id = model.lowercased()
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if let range = id.range(of: "claude-") { id = String(id[range.lowerBound...]) }
        if let at = id.firstIndex(of: "@") { id = String(id[..<at]) }
        return id
    }

    public static func price(for model: String) -> ModelPrice? {
        let id = normalize(model)
        return table.filter { id == $0.id || id.hasPrefix($0.id + "-") }
            .max { $0.id.count < $1.id.count }?.price
    }

    /// Dollar cost of one response, or nil for a model without a known price.
    public static func cost(_ usage: TokenUsage, model: String, fast: Bool = false) -> Double? {
        guard let price = price(for: model) else { return nil }
        var inputRate = 1.0
        var outputRate = 1.0
        if let above = price.longContextAbove, usage.prompt > above {
            inputRate = price.longInput
            outputRate = price.longOutput
        }
        let shortWrites = max(0, usage.cacheWrite - usage.cacheWriteLong)
        let promptCost = Double(usage.input) * price.input + Double(usage.cacheRead) * price.cacheRead
            + Double(shortWrites) * price.cacheWrite + Double(usage.cacheWriteLong) * price.cacheWriteLong
        let total = promptCost * inputRate + Double(usage.output) * price.output * outputRate
        return total / 1_000_000 * (fast ? price.fastMultiplier : 1)
    }
}
