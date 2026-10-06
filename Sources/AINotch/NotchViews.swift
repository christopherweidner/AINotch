// SPDX-License-Identifier: GPL-3.0-or-later

import AINotchCore
import SwiftUI

extension Color {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let done = Color(red: 0.30, green: 0.82, blue: 0.48)
}

/// What the island looks like right now.
enum IslandMode: Equatable {
    case hidden
    case working
    case finished
    case expanded
    case celebration
    case card
}

struct NotchRootView: View {
    let geometry: NotchGeometry
    let onShapeFrame: (CGRect) -> Void
    @EnvironmentObject private var model: AppModel

    private var mode: IslandMode {
        if model.interaction != nil { return .card }
        if model.celebration != nil { return .celebration }
        guard let primary = model.primary else { return .hidden }
        if model.isHovering { return .expanded }
        switch primary.phase {
        case .working, .needsInput: return .working
        case .finished: return .finished
        case .idle: return .hidden
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            island
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: NotchShapeFrameKey.self,
                                           value: mode == .hidden ? .zero : proxy.frame(in: .named("canvas")))
                })
            Spacer(minLength: 0)
        }
        .frame(width: NotchLayout.canvas.width, height: NotchLayout.canvas.height, alignment: .top)
        .coordinateSpace(name: "canvas")
        .onPreferenceChange(NotchShapeFrameKey.self) { onShapeFrame($0) }
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: mode)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var island: some View {
        let notch = geometry.notchSize
        switch mode {
        case .hidden:
            // Invisible on displays without a notch; blends into the camera housing otherwise.
            IslandShape(radius: NotchLayout.cornerRadius)
                .fill(geometry.hasNotch ? Color.black : Color.clear)
                .frame(width: notch.width, height: notch.height)
        case .working, .finished:
            if let session = model.primary {
                CompactIsland(session: session, notch: notch, extra: model.sessions.count - 1)
                    .islandBackground(radius: NotchLayout.cornerRadius)
            }
        case .expanded:
            ExpandedIsland(notch: notch)
                .islandBackground(radius: NotchLayout.expandedCornerRadius)
        case .celebration:
            if let run = model.celebration {
                CompletionBanner(run: run, notch: notch)
                    .islandBackground(radius: NotchLayout.expandedCornerRadius)
            }
        case .card:
            if let interaction = model.interaction {
                InteractionCard(interaction: interaction, notch: notch, queued: model.interactions.count - 1)
                    .id(interaction.id)
                    .islandBackground(radius: NotchLayout.expandedCornerRadius)
            }
        }
    }
}

/// Square top edge that merges with the screen bezel, rounded bottom.
struct IslandShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
            .path(in: rect)
    }
}

extension View {
    func islandBackground(radius: CGFloat) -> some View {
        background(IslandShape(radius: radius).fill(Color.black))
            .clipShape(IslandShape(radius: radius))
            .shadow(color: .black.opacity(radius > NotchLayout.cornerRadius ? 0.35 : 0), radius: 12, y: 6)
    }
}

// MARK: Compact

struct CompactIsland: View {
    let session: SessionSnapshot
    let notch: CGSize
    let extra: Int
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            leftWing
                .frame(width: NotchLayout.wing, alignment: .leading)
                .padding(.leading, 12)
            Spacer(minLength: notch.width)
            rightWing
                .frame(width: NotchLayout.wing, alignment: .trailing)
                .padding(.trailing, 12)
        }
        .frame(width: notch.width + 2 * (NotchLayout.wing + 12), height: notch.height)
        .contentShape(Rectangle())
        .onTapGesture {
            if case .finished = session.phase { model.openClaude(acknowledging: session.id) }
        }
        .help(session.phase == .finished(success: true) ? "Done. Click to open Claude." : session.project)
    }

    @ViewBuilder private var leftWing: some View {
        switch session.phase {
        case .finished(let success):
            Image(systemName: success ? "checkmark.circle.fill" : "stop.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(success ? Color.done : Color.secondary)
                .symbolEffect(.bounce, value: session.endedAt)
        case .needsInput:
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.claude)
                .symbolEffect(.pulse)
        default:
            HStack(spacing: 6) {
                ActivityBars()
                if session.activeSubagents > 0 {
                    Text("×\(session.activeSubagents)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.claude)
                        .transition(.scale.combined(with: .opacity))
                }
                if extra > 0 {
                    Text("+\(extra)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var rightWing: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(NotchFormat.clock(session.elapsed(at: context.date)))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(session.phase == .finished(success: true) ? Color.done : .white)
                .contentTransition(.numericText())
        }
    }
}

/// Live "Claude is working" indicator.
struct ActivityBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(Color.claude)
                        .frame(width: 3, height: 5 + 9 * abs(sin(t * 3.2 + Double(index) * 0.8)))
                }
            }
            .frame(height: 15)
        }
    }
}

// MARK: Expanded (hover)

struct ExpandedIsland: View {
    let notch: CGSize
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.sessions.prefix(4)) { session in
                SessionRow(session: session)
            }
            if model.sessions.contains(where: { if case .finished = $0.phase { return true } else { return false } }) {
                Button {
                    model.openClaude()
                } label: {
                    Label("Open Claude", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.done)
                .controlSize(.small)
            }
        }
        .padding(.top, notch.height + 8)
        .padding([.horizontal, .bottom], 16)
        .frame(width: NotchLayout.expandedWidth)
    }
}

struct SessionRow: View {
    let session: SessionSnapshot
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    statusIcon
                    Text(session.project.isEmpty ? "Claude" : session.project)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if !session.model.isEmpty {
                        Text(Self.shortModel(session.model))
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(NotchFormat.clock(session.elapsed(at: context.date)))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                HStack(spacing: 12) {
                    Stat(icon: "text.word.spacing", value: NotchFormat.tokens(session.tokens.total))
                    Stat(icon: "dollarsign.circle", value: NotchFormat.cost(session.cost))
                    if session.activeSubagents > 0 {
                        Stat(icon: "person.2.fill", value: "\(session.activeSubagents) sub-agent\(session.activeSubagents == 1 ? "" : "s")")
                    }
                    Spacer()
                    Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                if session.phase == .working {
                    IndeterminateBar()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if case .finished = session.phase { model.openClaude(acknowledging: session.id) }
        }
    }

    private var caption: String {
        switch session.phase {
        case .working: return session.activity ?? "Thinking"
        case .needsInput: return "Waiting for you"
        case .finished(let success): return success ? "Done · click to open" : "Stopped"
        case .idle: return ""
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch session.phase {
        case .working: ActivityBars().scaleEffect(0.8)
        case .needsInput: Image(systemName: "questionmark.bubble.fill").foregroundStyle(Color.claude)
        case .finished(let success):
            Image(systemName: success ? "checkmark.circle.fill" : "stop.circle.fill")
                .foregroundStyle(success ? Color.done : Color.secondary)
        case .idle: EmptyView()
        }
    }

    static func shortModel(_ model: String) -> String {
        let id = Pricing.normalize(model).replacingOccurrences(of: "claude-", with: "")
        let parts = id.split(separator: "-").filter { $0.count < 8 } // drop date stamps
        guard let family = parts.first else { return id }
        return family.capitalized + " " + parts.dropFirst().joined(separator: ".")
    }
}

struct Stat: View {
    let icon: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(value).font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.75))
    }
}

/// A sliding highlight: work in progress with no known end.
struct IndeterminateBar: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            GeometryReader { proxy in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                let width = proxy.size.width * 0.3
                Capsule().fill(Color.white.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(LinearGradient(colors: [.claude.opacity(0), .claude, .claude.opacity(0)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: width)
                            .offset(x: (proxy.size.width + width) * phase - width)
                    }
                    .clipShape(Capsule())
            }
            .frame(height: 3)
        }
    }
}

// MARK: Completion

struct CompletionBanner: View {
    let run: CompletedRun
    let notch: CGSize
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.done)
                    .symbolEffect(.bounce, value: run.sessionId)
                Text("Claude finished")
                    .font(.system(size: 14, weight: .semibold))
                if !run.project.isEmpty {
                    Text(run.project).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Pill(title: "Time", value: NotchFormat.clock(run.duration))
                Pill(title: "Tokens", value: NotchFormat.tokens(run.tokens.total))
                Pill(title: "Cost", value: NotchFormat.cost(run.cost))
            }
            Text("Click to open Claude").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.top, notch.height + 8)
        .padding([.horizontal, .bottom], 16)
        .frame(width: NotchLayout.expandedWidth)
        .contentShape(Rectangle())
        .onTapGesture { model.openClaude(acknowledging: run.sessionId) }
    }
}

struct Pill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title.uppercased()).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
    }
}
