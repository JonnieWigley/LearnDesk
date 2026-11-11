import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    enum Tab: String, CaseIterable {
        case ideas = "Ideas"
        case journal = "Learning Journal"
        case quiz = "Quiz"
        case todo = "To Do"
    }

    @Published var tab: Tab = .ideas
    @Published var claudeReady = Claude.locate() != nil
}

/// UserDefaults keys.
enum Prefs {
    static let model = "claudeCodeModel"
    static let claudePath = "claudeCodePath"
    static let popQuizHours = "popQuizHours"
    static let notifications = "notificationsEnabled"
    static let pinMode = "pinMode"
    static let supabaseURL = "supabaseURL"
    static let supabaseKey = "supabaseKey"
    static let supabaseEmail = "supabaseEmail"
}

enum PinMode: String, CaseIterable {
    case desktop, normal, floating

    var label: String {
        switch self {
        case .desktop: return "Sit on Desktop"
        case .normal: return "Normal Window"
        case .floating: return "Always on Top"
        }
    }

    static var current: PinMode {
        get { PinMode(rawValue: UserDefaults.standard.string(forKey: Prefs.pinMode) ?? "") ?? .desktop }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Prefs.pinMode) }
    }
}
