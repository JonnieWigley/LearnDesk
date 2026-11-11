import SwiftUI

struct QuizView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @EnvironmentObject var session: QuizSession

    var body: some View {
        Group {
            if let card = session.current {
                question(card)
            } else {
                idle
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    // MARK: Nothing in progress

    @ViewBuilder
    private var idle: some View {
        let due = store.dueCards().count
        let total = store.data.cards.count

        VStack(spacing: 12) {
            Spacer()
            if total == 0 {
                Text("No questions yet")
                    .font(.headline)
                Text("Log something in the Learning Journal and questions will be written from it.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                if session.answered > 0 {
                    Text(session.answered == 1 ? "1 question answered." : "\(session.answered) questions answered.")
                        .foregroundStyle(.secondary)
                }
                Text(due == 0 ? "Nothing due right now" : (due == 1 ? "1 question due" : "\(due) questions due"))
                    .font(.headline)
                if due == 0, let next = store.data.cards.map(\.due).min() {
                    Text("Next one is due \(next.formatted(.relative(presentation: .named))).")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Start Due") { session.startDue() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(due == 0)
                    Button("5 at Random") { session.startRandom(count: 5) }
                }
                Text("\(total) questions in total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: A question

    @ViewBuilder
    private func question(_ card: Card) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Tag(text: card.topic)
                    Spacer()
                    Text("\(session.remaining) left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("End") { session.stop() }
                        .controlSize(.small)
                }

                Text(card.question)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel()

                TextEditor(text: $session.answer)
                    .editorBox(height: 110)
                    .disabled(session.phase != .answering)

                if let problem = session.error {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                switch session.phase {
                case .answering:
                    answeringControls
                case .grading:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking…").foregroundStyle(.secondary)
                    }
                case .reviewed:
                    review(card)
                }
            }
        }
    }

    @ViewBuilder
    private var answeringControls: some View {
        HStack {
            if app.claudeReady {
                Button("Check") {
                    Task { await session.check() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(session.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button("Show Answer") { session.reveal() }
            Spacer()
            Button("Skip") { session.skip() }
                .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private func review(_ card: Card) -> some View {
        if let feedback = session.feedback {
            VStack(alignment: .leading, spacing: 4) {
                Text("Feedback").font(.caption).foregroundStyle(.secondary)
                Text(feedback).textSelection(.enabled)
            }
            .panel()
        }

        VStack(alignment: .leading, spacing: 4) {
            Text("Model answer").font(.caption).foregroundStyle(.secondary)
            Text(card.answer).textSelection(.enabled)
        }
        .panel()

        Text(session.suggested == nil
             ? "How well did you know it?"
             : "Suggested rating is highlighted. Pick another if you disagree.")
            .font(.caption)
            .foregroundStyle(.secondary)

        HStack {
            ForEach(Grade.allCases, id: \.self) { grade in
                gradeButton(grade)
            }
            Spacer()
            Button {
                store.deleteCard(card.id)
                session.skip()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Delete this question")
        }
    }

    @ViewBuilder
    private func gradeButton(_ grade: Grade) -> some View {
        if grade == session.suggested {
            Button(grade.label) { session.rate(grade) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        } else {
            Button(grade.label) { session.rate(grade) }
        }
    }
}
