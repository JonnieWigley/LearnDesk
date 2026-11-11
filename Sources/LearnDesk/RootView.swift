import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Grab handle. Empty space anywhere else in the widget drags too.
            Capsule()
                .fill(Color.primary.opacity(0.25))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .frame(height: 20)
                .allowsHitTesting(false)

            Picker("", selection: $app.tab) {
                ForEach(AppState.Tab.allCases, id: \.self) { tab in
                    Text(label(for: tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if let problem = store.saveError {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Group {
                switch app.tab {
                case .ideas: IdeasView()
                case .journal: JournalView()
                case .quiz: QuizView()
                case .todo: TodoView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(WindowDragArea())
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .ignoresSafeArea()
    }

    private func label(for tab: AppState.Tab) -> String {
        let due = store.dueCards().count
        return tab == .quiz && due > 0 ? "Quiz (\(due))" : tab.rawValue
    }
}

/// Sits behind the content; a mouse-down that no control claims drags the window.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

extension IdeaColor {
    var swatch: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        }
    }
}

/// Shared look for list rows and panels.
struct Panel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension View {
    func panel() -> some View { modifier(Panel()) }

    /// A bordered, fixed-height text editor.
    func editorBox(height: CGFloat) -> some View {
        self
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
    }
}

let shortDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
}()
