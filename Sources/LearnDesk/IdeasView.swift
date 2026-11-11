import SwiftUI

struct IdeasView: View {
    enum Filter: String, CaseIterable {
        case create = "Create"
        case research = "Research"
        case open = "Open"
        case done = "Complete"
    }

    @EnvironmentObject var store: Store
    @State private var title = ""
    @State private var filter: Filter = .create

    /// The Create and Research headers are also where new ideas get added.
    private var kind: Idea.Kind? {
        switch filter {
        case .create: return .create
        case .research: return .research
        case .open, .done: return nil
        }
    }

    private var visible: [Idea] {
        store.data.ideas.filter { idea in
            switch filter {
            case .open: return !idea.done
            case .create: return !idea.done && idea.kind == .create
            case .research: return !idea.done && idea.kind == .research
            case .done: return idea.done
            }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            if let kind {
                HStack(spacing: 6) {
                    TextField("Add to \(kind.rawValue)…", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus")
                    }
                    .help("Add idea")
                    .disabled(trimmedTitle.isEmpty)
                }
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    if visible.isEmpty {
                        Text(filter == .done ? "Nothing completed yet." : "Nothing added here yet.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                    }
                    ForEach(visible) { idea in
                        IdeaRow(idea: idea)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        guard let kind, !trimmedTitle.isEmpty else { return }
        store.addIdea(title: trimmedTitle, kind: kind)
        title = ""
    }
}

struct IdeaRow: View {
    @EnvironmentObject var store: Store
    let idea: Idea
    @State private var expanded = false

    private var note: Binding<String> {
        Binding(
            get: { idea.note },
            set: { text in
                var changed = idea
                changed.note = text
                store.updateIdea(changed)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    var changed = idea
                    changed.done.toggle()
                    store.updateIdea(changed)
                } label: {
                    Image(systemName: idea.done ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain)
                .help(idea.done ? "Mark as open" : "Mark as complete")

                Text(idea.title)
                    .strikethrough(idea.done)
                    .foregroundStyle(idea.done ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Tag(text: idea.kind.rawValue)

                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: idea.note.isEmpty ? "note.text.badge.plus" : "note.text")
                }
                .buttonStyle(.plain)
                .help("Notes")
            }

            if expanded {
                TextEditor(text: note)
                    .editorBox(height: 70)
                HStack(spacing: 6) {
                    swatchButton(nil)
                    ForEach(IdeaColor.allCases, id: \.self) { color in
                        swatchButton(color)
                    }
                }
                HStack {
                    Text("Added \(shortDate.string(from: idea.created))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete", role: .destructive) {
                        store.deleteIdea(idea.id)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .padding(.leading, idea.color == nil ? 0 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(idea.color?.swatch.opacity(0.16) ?? Color.primary.opacity(0.06))
        .overlay(alignment: .leading) {
            if let color = idea.color {
                color.swatch.frame(width: 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func swatchButton(_ color: IdeaColor?) -> some View {
        Button {
            var changed = idea
            changed.color = color
            store.updateIdea(changed)
        } label: {
            ZStack {
                Circle()
                    .fill(color?.swatch ?? Color.clear)
                    .frame(width: 16, height: 16)
                Circle()
                    .strokeBorder(Color.primary.opacity(idea.color == color ? 0.9 : 0.25),
                                  lineWidth: idea.color == color ? 2 : 1)
                    .frame(width: 20, height: 20)
                if color == nil {
                    Image(systemName: "slash.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help(color?.rawValue.capitalized ?? "No colour")
    }
}
