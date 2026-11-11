import Combine
import Foundation

/// The run of questions currently being asked.
@MainActor
final class QuizSession: ObservableObject {
    enum Phase {
        case answering, grading, reviewed
    }

    @Published private(set) var queue: [UUID] = []
    @Published private(set) var phase: Phase = .answering
    @Published private(set) var feedback: String?
    @Published private(set) var suggested: Grade?
    @Published private(set) var error: String?
    @Published private(set) var answered = 0
    @Published var answer = ""

    private let store: Store

    init(store: Store) {
        self.store = store
    }

    var isActive: Bool { current != nil }

    var current: Card? {
        guard let id = queue.first else { return nil }
        return store.data.cards.first { $0.id == id }
    }

    var remaining: Int { queue.count }

    func startDue() {
        begin(with: store.dueCards().map(\.id))
    }

    func startRandom(count: Int) {
        begin(with: Array(store.data.cards.shuffled().prefix(count)).map(\.id))
    }

    func stop() {
        begin(with: [])
    }

    private func begin(with ids: [UUID]) {
        queue = ids
        answered = 0
        resetCard()
    }

    private func resetCard() {
        answer = ""
        feedback = nil
        suggested = nil
        error = nil
        phase = .answering
        // Skip over cards deleted since the queue was built.
        while let id = queue.first, !store.data.cards.contains(where: { $0.id == id }) {
            queue.removeFirst()
        }
    }

    /// Ask Claude to grade the typed answer.
    func check() async {
        guard let card = current, phase == .answering else { return }
        phase = .grading
        error = nil
        let notes = store.data.entries.first { $0.id == card.entryID }?.text
        do {
            let result = try await Claude.grade(card: card, notes: notes, learnerAnswer: answer)
            guard current?.id == card.id, phase == .grading else { return }
            feedback = result.feedback
            suggested = Grade(rawValue: min(3, max(0, result.score)))
            phase = .reviewed
        } catch {
            guard current?.id == card.id else { return }
            self.error = error.localizedDescription
            phase = .answering
        }
    }

    /// Show the model answer without AI grading; the learner rates themselves.
    func reveal() {
        guard current != nil else { return }
        phase = .reviewed
    }

    func rate(_ grade: Grade) {
        guard let id = queue.first else { return }
        store.review(id, grade: grade)
        queue.removeFirst()
        if grade == .again {
            queue.append(id) // ask it again before the session ends
        } else {
            answered += 1
        }
        resetCard()
    }

    func skip() {
        guard !queue.isEmpty else { return }
        queue.removeFirst()
        resetCard()
    }
}
