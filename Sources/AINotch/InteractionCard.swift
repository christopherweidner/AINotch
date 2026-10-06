// SPDX-License-Identifier: GPL-3.0-or-later

import AINotchCore
import SwiftUI

/// The pop-up the island springs open into when Claude needs the person.
/// Whatever is submitted here goes straight back to the waiting Claude
/// session through its hook; "Answer in Claude" hands it back untouched.
struct InteractionCard: View {
    let interaction: Interaction
    let notch: CGSize
    let queued: Int
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch interaction.kind {
            case .questions(let questions):
                QuestionsForm(questions: questions) { answers in model.answer(interaction, with: answers) }
            case .permission(let tool, let detail):
                PermissionForm(tool: tool, detail: detail) { allow, message in
                    model.permit(interaction, allow: allow, message: message)
                }
            case .followUp(let question):
                FollowUpForm(question: question) { text in model.reply(interaction, text: text) }
            case .notice(let message):
                Text(message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Open Claude") {
                        model.openClaude()
                        model.dismiss(interaction)
                    }
                    .buttonStyle(.borderedProminent).tint(.claude)
                }
            }
        }
        .padding(.top, notch.height + 10)
        .padding([.horizontal, .bottom], 18)
        .frame(width: NotchLayout.cardWidth)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Color.claude).symbolEffect(.pulse)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(interaction.project).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if queued > 0 {
                Text("+\(queued) more").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button {
                model.dismiss(interaction)
            } label: {
                Text("Answer in Claude").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close this pop-up and answer in Claude's own window instead.")
        }
    }

    private var icon: String {
        switch interaction.kind {
        case .questions, .followUp: return "questionmark.bubble.fill"
        case .permission: return "lock.shield.fill"
        case .notice: return "bell.badge.fill"
        }
    }

    private var title: String {
        switch interaction.kind {
        case .questions, .followUp: return "Claude asks"
        case .permission: return "Permission needed"
        case .notice: return "Claude needs you"
        }
    }
}

/// Reply field shared by the cards: Return sends.
struct ReplyField: View {
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .lineLimit(1...4)
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused ? Color.claude.opacity(0.8) : Color.white.opacity(0.1)))
    }
}

struct FollowUpForm: View {
    let question: String
    let send: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(Self.tail(of: question))
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 140)
            HStack(alignment: .bottom, spacing: 8) {
                ReplyField(placeholder: "Reply to Claude…", text: $text) { send(text) }
                Button { send(text) } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(text.isEmpty ? Color.secondary : Color.claude)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// The end of a long answer is where the question is.
    static func tail(of text: String) -> String {
        text.count > 700 ? "…" + text.suffix(700) : text
    }
}

struct PermissionForm: View {
    let tool: String
    let detail: String
    let decide: (_ allow: Bool, _ message: String?) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude wants to use **\(tool)**").font(.system(size: 13))
            if !detail.isEmpty {
                ScrollView {
                    Text(detail)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 90)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            }
            ReplyField(placeholder: "Optional: tell Claude what to do instead…", text: $text) {
                decide(false, text)
            }
            HStack {
                Spacer()
                Button(text.isEmpty ? "Deny" : "Deny & send") { decide(false, text) }
                Button("Allow") { decide(true, nil) }
                    .buttonStyle(.borderedProminent)
                    .tint(.claude)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!text.isEmpty)
            }
            .controlSize(.regular)
        }
    }
}

struct QuestionsForm: View {
    let questions: [AskedQuestion]
    let submit: ([(question: String, answer: String)]) -> Void
    @State private var selections: [Int: Set<String>] = [:]
    @State private var custom: [Int: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 8) {
                    if let header = question.header, !header.isEmpty {
                        Text(header.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.claude)
                    }
                    Text(question.question).font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    FlowOptions(question: question, selected: selections[index] ?? []) { label in
                        toggle(label, at: index, multi: question.multiSelect)
                    }
                    ReplyField(placeholder: "Other…", text: Binding(get: { custom[index] ?? "" },
                                                                   set: { custom[index] = $0 })) {
                        if isComplete { submit(answers) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Send to Claude") { submit(answers) }
                    .buttonStyle(.borderedProminent)
                    .tint(.claude)
                    .disabled(!isComplete)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func toggle(_ label: String, at index: Int, multi: Bool) {
        var set = selections[index] ?? []
        if multi {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = set.contains(label) ? [] : [label]
        }
        selections[index] = set
    }

    private func answer(at index: Int) -> String {
        let question = questions[index]
        let picked = question.options.map(\.label).filter { selections[index]?.contains($0) ?? false }
        let other = (custom[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (picked + (other.isEmpty ? [] : [other])).joined(separator: ", ")
    }

    private var answers: [(question: String, answer: String)] {
        questions.indices.map { (questions[$0].question, answer(at: $0)) }
    }

    private var isComplete: Bool { questions.indices.allSatisfy { !answer(at: $0).isEmpty } }
}

struct FlowOptions: View {
    let question: AskedQuestion
    let selected: Set<String>
    let tap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(question.options, id: \.label) { option in
                Button { tap(option.label) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon(for: option.label))
                            .foregroundStyle(selected.contains(option.label) ? Color.claude : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label).font(.system(size: 13, weight: .medium))
                            if let detail = option.detail, !detail.isEmpty {
                                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected.contains(option.label) ? Color.claude.opacity(0.18) : Color.white.opacity(0.06)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func icon(for label: String) -> String {
        let on = selected.contains(label)
        if question.multiSelect { return on ? "checkmark.square.fill" : "square" }
        return on ? "largecircle.fill.circle" : "circle"
    }
}
