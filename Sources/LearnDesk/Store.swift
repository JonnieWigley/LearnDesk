import Combine
import Foundation

/// All app data, persisted as one JSON file in Application Support.
@MainActor
final class Store: ObservableObject {
    @Published var data = AppData() {
        didSet { save() }
    }
    @Published var generating: Set<UUID> = []
    @Published var generationErrors: [UUID: String] = [:]
    @Published var saveError: String?

    let fileURL: URL

    /// Called after every change made on this Mac (not after changes pulled from sync).
    var onLocalChange: (() -> Void)?

    static func stamp() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Replace everything with the result of a sync merge.
    func applySynced(_ merged: AppData) {
        data = merged
    }

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LearnDesk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("data.json")
        load()
    }

    private func load() {
        guard let raw = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode(AppData.self, from: raw) {
            data = loaded
        } else {
            // Don't overwrite a file we couldn't read: set it aside first.
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("data.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            saveError = "The data file couldn't be read. It was kept as \(backup.lastPathComponent)."
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(data).write(to: fileURL, options: .atomic)
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    // MARK: Ideas

    func addIdea(title: String, kind: Idea.Kind) {
        data.ideas.insert(Idea(title: title, kind: kind, modified: Self.stamp()), at: 0)
        onLocalChange?()
    }

    func updateIdea(_ idea: Idea) {
        guard let i = data.ideas.firstIndex(where: { $0.id == idea.id }) else { return }
        data.ideas[i] = idea
        data.ideas[i].modified = Self.stamp()
        onLocalChange?()
    }

    func deleteIdea(_ id: UUID) {
        var next = data
        next.ideas.removeAll { $0.id == id }
        next.tombstones.append(Tombstone(id: id, kind: "idea", modified: Self.stamp()))
        data = next
        onLocalChange?()
    }

    // MARK: To do

    func addTodo(title: String) {
        data.todos.insert(TodoItem(title: title, modified: Self.stamp()), at: 0)
        onLocalChange?()
    }

    func updateTodo(_ item: TodoItem) {
        guard let i = data.todos.firstIndex(where: { $0.id == item.id }) else { return }
        data.todos[i] = item
        data.todos[i].modified = Self.stamp()
        onLocalChange?()
    }

    func deleteTodo(_ id: UUID) {
        var next = data
        next.todos.removeAll { $0.id == id }
        next.tombstones.append(Tombstone(id: id, kind: "todo", modified: Self.stamp()))
        data = next
        onLocalChange?()
    }

    // MARK: Journal

    var topics: [String] {
        var seen = Set<String>()
        return data.entries
            .sorted { $0.created > $1.created }
            .map(\.topic)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    @discardableResult
    func addEntry(topic: String, text: String) -> JournalEntry {
        let entry = JournalEntry(topic: topic, text: text, modified: Self.stamp(), needsQuestions: true)
        data.entries.insert(entry, at: 0)
        onLocalChange?()
        return entry
    }

    /// Changes an entry's topic and text. Questions already written from it are kept;
    /// they just follow a renamed topic.
    func updateEntry(_ id: UUID, topic: String, text: String) {
        guard let i = data.entries.firstIndex(where: { $0.id == id }),
              data.entries[i].topic != topic || data.entries[i].text != text
        else { return }
        let now = Self.stamp()
        var next = data
        if next.entries[i].topic != topic {
            for c in next.cards.indices where next.cards[c].entryID == id {
                next.cards[c].topic = topic
                next.cards[c].modified = now
            }
        }
        next.entries[i].topic = topic
        next.entries[i].text = text
        next.entries[i].modified = now
        data = next
        onLocalChange?()
    }

    func deleteEntry(_ id: UUID) {
        let now = Self.stamp()
        var next = data
        for card in next.cards where card.entryID == id {
            next.tombstones.append(Tombstone(id: card.id, kind: "card", modified: now))
        }
        next.tombstones.append(Tombstone(id: id, kind: "entry", modified: now))
        next.entries.removeAll { $0.id == id }
        next.cards.removeAll { $0.entryID == id }
        data = next
        generationErrors[id] = nil
        onLocalChange?()
    }

    func cardCount(for entryID: UUID) -> Int {
        data.cards.filter { $0.entryID == entryID }.count
    }

    func generateCards(for entryID: UUID) async {
        guard let entry = data.entries.first(where: { $0.id == entryID }),
              !generating.contains(entryID)
        else { return }
        generating.insert(entryID)
        generationErrors[entryID] = nil
        defer { generating.remove(entryID) }

        do {
            let generated = try await Claude.generateCards(topic: entry.topic, notes: entry.text)
            // The entry may have been deleted while we waited.
            guard data.entries.contains(where: { $0.id == entryID }) else { return }
            let firstDue = Date().addingTimeInterval(86_400)
            let now = Self.stamp()
            data.cards.append(contentsOf: generated.map {
                Card(entryID: entryID, topic: entry.topic, question: $0.question,
                     answer: $0.answer, due: firstDue, modified: now)
            })
            if let i = data.entries.firstIndex(where: { $0.id == entryID }), data.entries[i].needsQuestions != nil {
                data.entries[i].needsQuestions = nil
                data.entries[i].modified = now
            }
            onLocalChange?()
        } catch {
            generationErrors[entryID] = error.localizedDescription
            lastGenerationFailure = Date()
        }
    }

    private var lastGenerationFailure = Date.distantPast

    /// Write questions for one entry that is still waiting (logged on the phone, or
    /// logged here while Claude was unavailable). After a failure, wait a while before retrying.
    func generatePending() async {
        guard generating.isEmpty,
              Date().timeIntervalSince(lastGenerationFailure) > 15 * 60,
              Claude.locate() != nil,
              let entry = data.entries.last(where: { $0.needsQuestions == true })
        else { return }
        await generateCards(for: entry.id)
    }

    // MARK: Cards

    func dueCards(now: Date = Date()) -> [Card] {
        data.cards.filter { $0.due <= now }.sorted { $0.due < $1.due }
    }

    func review(_ id: UUID, grade: Grade) {
        guard let i = data.cards.firstIndex(where: { $0.id == id }) else { return }
        var card = data.cards[i]
        card.review(grade)
        card.modified = Self.stamp()
        data.cards[i] = card
        onLocalChange?()
    }

    func deleteCard(_ id: UUID) {
        var next = data
        next.cards.removeAll { $0.id == id }
        next.tombstones.append(Tombstone(id: id, kind: "card", modified: Self.stamp()))
        data = next
        onLocalChange?()
    }
}
