import SwiftUI

struct TodoView: View {
    enum Filter: String, CaseIterable {
        case open = "Open"
        case done = "Complete"
    }

    @EnvironmentObject var store: Store
    @State private var title = ""
    @State private var filter: Filter = .open

    /// Open items: dated ones first, soonest at the top. Complete items: newest first.
    private var visible: [TodoItem] {
        let items = store.data.todos.filter { $0.done == (filter == .done) }
        guard filter == .open else { return items }
        return items.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.created > b.created
            }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Add a to-do…", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "plus")
                }
                .help("Add to-do")
                .disabled(trimmedTitle.isEmpty)
            }

            Picker("", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            ScrollView {
                LazyVStack(spacing: 6) {
                    if visible.isEmpty {
                        Text(filter == .done ? "Nothing completed yet." : "Nothing to do.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                    }
                    ForEach(visible) { item in
                        TodoRow(item: item)
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
        guard !trimmedTitle.isEmpty else { return }
        store.addTodo(title: trimmedTitle)
        title = ""
        filter = .open
    }
}

struct TodoRow: View {
    @EnvironmentObject var store: Store
    let item: TodoItem
    @State private var expanded = false

    private var overdue: Bool {
        guard let due = item.due, !item.done else { return false }
        return due < Calendar.current.startOfDay(for: Date())
    }

    private var dueDate: Binding<Date> {
        Binding(
            get: { item.due ?? Date() },
            set: { setDue($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    var changed = item
                    changed.done.toggle()
                    store.updateTodo(changed)
                } label: {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain)
                .help(item.done ? "Mark as open" : "Mark as complete")

                Text(item.title)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let due = item.due {
                    Text(shortDate.string(from: due))
                        .font(.caption)
                        .foregroundStyle(overdue ? Color.red : Color.secondary)
                }

                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: "calendar")
                }
                .buttonStyle(.plain)
                .help("Due date and delete")
            }

            if expanded {
                HStack {
                    if item.due != nil {
                        DatePicker("Due", selection: dueDate, displayedComponents: .date)
                            .fixedSize()
                        Button("No Date") { setDue(nil) }
                            .controlSize(.small)
                    } else {
                        Button("Add Due Date") { setDue(Date()) }
                            .controlSize(.small)
                    }
                    Spacer()
                    Button("Delete", role: .destructive) {
                        store.deleteTodo(item.id)
                    }
                    .controlSize(.small)
                }
            }
        }
        .panel()
    }

    private func setDue(_ date: Date?) {
        var changed = item
        changed.due = date
        store.updateTodo(changed)
    }
}
