import SwiftUI

struct JournalView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @State private var topic = ""
    @State private var text = ""
    /// The earlier entry loaded into the form for editing, if any.
    @State private var editingID: UUID?
    /// What was half-typed in the form before an edit started; put back afterwards.
    @State private var setAside: (topic: String, text: String)?

    private var canSave: Bool {
        !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                if editingID != nil {
                    Text("Editing an earlier entry")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                    if editingID != nil {
                        Text("Questions already written stay as they are.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel", action: endEdit)
                            .keyboardShortcut(.cancelAction)
                        Button("Save", action: saveEdit)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!canSave)
                    } else {
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
                        EntryRow(entry: entry, isEditing: editingID == entry.id) { edit(entry) }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .onChange(of: store.data.entries.map(\.id)) { ids in
            // The entry being edited was deleted, here or on the phone.
            if let editingID, !ids.contains(editingID) { endEdit() }
        }
    }

    private func edit(_ entry: JournalEntry) {
        guard editingID != entry.id else { return }
        if editingID == nil { setAside = (topic, text) }
        editingID = entry.id
        topic = entry.topic
        text = entry.text
    }

    private func endEdit() {
        editingID = nil
        topic = setAside?.topic ?? ""
        text = setAside?.text ?? ""
        setAside = nil
    }

    private func saveEdit() {
        guard let editingID, canSave else { return }
        store.updateEntry(
            editingID,
            topic: topic.trimmingCharacters(in: .whitespacesAndNewlines),
            text: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        endEdit()
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
    let isEditing: Bool
    /// Clicking the entry loads it into the form at the top.
    let onEdit: () -> Void
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
        .overlay {
            if isEditing {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .help("Click to edit")
    }
}
