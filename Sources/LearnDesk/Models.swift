import Foundation

struct Idea: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case create = "Create"
        case research = "Research"
    }

    var id = UUID()
    var title: String
    var note = ""
    var kind: Kind
    var done = false
    var created = Date()
    var color: IdeaColor?
    var modified: Int64?
}

enum IdeaColor: String, Codable, CaseIterable {
    case red, orange, yellow, green, blue, purple, pink
}

struct JournalEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var topic: String
    var text: String
    var created = Date()
    var modified: Int64?
    /// Set when an entry is logged; cleared once this Mac has written its questions.
    var needsQuestions: Bool?
}

enum Grade: Int, CaseIterable {
    case again, hard, good, easy

    var label: String {
        switch self {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }
}

/// One quiz question, scheduled with a simplified SM-2 spaced-repetition scheme.
struct Card: Codable, Identifiable, Equatable {
    var id = UUID()
    var entryID: UUID
    var topic: String
    var question: String
    var answer: String
    var intervalDays: Double = 0
    var ease: Double = 2.5
    var reps = 0
    var lapses = 0
    var due: Date
    var lastReviewed: Date?
    var modified: Int64?

    mutating func review(_ grade: Grade, now: Date = Date()) {
        lastReviewed = now
        switch grade {
        case .again:
            reps = 0
            lapses += 1
            ease = max(1.3, ease - 0.2)
            intervalDays = 0
            due = now.addingTimeInterval(10 * 60)
            return
        case .hard:
            intervalDays = max(1, intervalDays * 1.2)
            ease = max(1.3, ease - 0.15)
        case .good:
            intervalDays = reps == 0 ? 1 : (reps == 1 ? 3 : intervalDays * ease)
        case .easy:
            intervalDays = reps == 0 ? 3 : max(4, intervalDays * ease * 1.3)
            ease += 0.15
        }
        reps += 1
        due = now.addingTimeInterval(intervalDays * 86_400)
    }
}

struct TodoItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var done = false
    var due: Date?
    var created = Date()
    var modified: Int64?
}

/// Anything that syncs between devices. `modified` is milliseconds since 1970;
/// when two devices disagree about an item, the later change wins.
protocol Syncable: Codable {
    var id: UUID { get set }
    var modified: Int64? { get set }
}

extension Idea: Syncable {}
extension JournalEntry: Syncable {}
extension Card: Syncable {}
extension TodoItem: Syncable {}

/// Remembers a deletion so it can be passed on to other devices.
struct Tombstone: Codable, Equatable {
    var id: UUID
    var kind: String
    var modified: Int64
}

struct AppData: Codable {
    var ideas: [Idea] = []
    var entries: [JournalEntry] = []
    var cards: [Card] = []
    var todos: [TodoItem] = []
    var tombstones: [Tombstone] = []

    init() {}

    // Sections added in later versions are optional, so older data files still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ideas = try container.decodeIfPresent([Idea].self, forKey: .ideas) ?? []
        entries = try container.decodeIfPresent([JournalEntry].self, forKey: .entries) ?? []
        cards = try container.decodeIfPresent([Card].self, forKey: .cards) ?? []
        todos = try container.decodeIfPresent([TodoItem].self, forKey: .todos) ?? []
        tombstones = try container.decodeIfPresent([Tombstone].self, forKey: .tombstones) ?? []
    }
}
