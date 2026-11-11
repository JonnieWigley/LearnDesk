import SwiftUI

struct JournalView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @State private var topic = ""
    @State private var text = ""

    private var canSave: Bool {
        !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Topic, e.g. C#", text: $topic)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $text)
                    .editorBox(height: 96)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("What did you learn?")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                HStack {
                    if !app.claudeReady {
                        Text("Claude Code not found (menu bar icon > Settings), so no questions will be written.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(app.claudeReady ? "Log & Make Questions" : "Log", action: save)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canSave)
                }
            }

            Divider()

            ScrollView {
                LazyVStack(spacing: 6) {
                    if store.data.entries.isEmpty {
                        Text("No entries yet.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                    }
                    ForEach(store.data.entries) { entry in
                        EntryRow(entry: entry)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func save() {
        guard canSave else { return }
        let entry = store.addEntry(
            topic: topic.trimmingCharacters(in: .whitespacesAndNewlines),
            text: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        topic = ""
        text = ""
        if app.claudeReady {
            Task { await store.generateCards(for: entry.id) }
        }
    }
}

struct EntryRow: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    let entry: JournalEntry
    @State private var expanded = false

    var body: some View {
        let count = store.cardCount(for: entry.id)
        let busy = store.generating.contains(entry.id)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Tag(text: entry.topic)
                Text(shortDate.string(from: entry.created))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Writing questions…").font(.caption).foregroundStyle(.secondary)
                } else if count > 0 {
                    Text(count == 1 ? "1 question" : "\(count) questions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(entry.text)
                .lineLimit(expanded ? nil : 3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let problem = store.generationErrors[entry.id] {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(expanded ? "Less" : "More") { expanded.toggle() }
                    .buttonStyle(.link)
                Spacer()
                if app.claudeReady && !busy {
                    Button(count == 0 ? "Make Questions" : "More Questions") {
                        Task { await store.generateCards(for: entry.id) }
                    }
                    .controlSize(.small)
                }
                if expanded {
                    Button("Delete", role: .destructive) {
                        store.deleteEntry(entry.id)
                    }
                    .controlSize(.small)
                    .help("Deletes this entry and its questions")
                }
            }
            .font(.caption)
        }
        .panel()
    }
}
