import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @EnvironmentObject var sync: SyncEngine

    @AppStorage(Prefs.model) private var model = ""
    @AppStorage(Prefs.claudePath) private var claudePath = ""
    @AppStorage(Prefs.popQuizHours) private var popQuizHours = 0.0
    @AppStorage(Prefs.notifications) private var notifications = false

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var message: String?

    @AppStorage(Prefs.supabaseURL) private var syncURL = ""
    @AppStorage(Prefs.supabaseKey) private var syncKey = ""
    @AppStorage(Prefs.supabaseEmail) private var syncEmail = ""
    @State private var syncPassword = ""
    @State private var syncMessage: String?
    @State private var signingIn = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Claude") {
                    if let found = Claude.locate() {
                        Text("Using Claude Code at \(found.path).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Claude Code wasn't found. Install it, run `claude` in Terminal once to sign in with your Claude account, then press Check Again.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text("Questions and answer checks run through Claude Code, so they count against your Claude subscription's usage. When you hit the limit they pause until it resets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Model", selection: Binding(
                        get: { Claude.model },
                        set: { model = $0 }
                    )) {
                        Text("Claude Code's default").tag("")
                        Text("Haiku (uses least of your allowance)").tag("haiku")
                        Text("Sonnet").tag("sonnet")
                        Text("Opus").tag("opus")
                        // A full model id set by hand stays selectable.
                        if !["", "haiku", "sonnet", "opus"].contains(Claude.model) {
                            Text(Claude.model).tag(Claude.model)
                        }
                    }
                    TextField("Location of claude (blank = find automatically)", text: $claudePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Check Again") {
                        app.claudeReady = Claude.locate() != nil
                    }
                }

                section("Sync with phone") {
                    if sync.signedIn {
                        Text("Signed in as \(syncEmail).")
                        Text(sync.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Sync Now") {
                                Task { await sync.syncNow() }
                            }
                            Button("Sign Out") { sync.signOut() }
                        }
                    } else {
                        TextField("Project URL (https://….supabase.co)", text: $syncURL)
                            .textFieldStyle(.roundedBorder)
                        TextField("Publishable (anon) key", text: $syncKey)
                            .textFieldStyle(.roundedBorder)
                        TextField("Email", text: $syncEmail)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Password", text: $syncPassword)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(signInToSync)
                        Button(signingIn ? "Signing In…" : "Sign In", action: signInToSync)
                            .disabled(signingIn || syncURL.isEmpty || syncKey.isEmpty || syncEmail.isEmpty || syncPassword.isEmpty)
                        Text(syncMessage ?? "Uses your own Supabase project. Ideas, journal, questions and to-dos sync; nothing else does.")
                            .font(.caption)
                            .foregroundStyle(syncMessage == nil ? Color.secondary : Color.red)
                    }
                }

                section("Quizzing") {
                    Picker("Pop quizzes", selection: $popQuizHours) {
                        Text("Off").tag(0.0)
                        Text("About hourly").tag(1.0)
                        Text("About every 2 hours").tag(2.0)
                        Text("About every 4 hours").tag(4.0)
                        Text("About once a day").tag(24.0)
                    }
                    Toggle("Notify me when questions are ready", isOn: $notifications)
                        .disabled(!Notifier.available)
                        .onChange(of: notifications) { wanted in
                            guard wanted else { return }
                            Task {
                                let granted = await Notifier.requestPermission()
                                if !granted {
                                    notifications = false
                                    message = "Notifications are blocked. Allow LearnDesk in System Settings > Notifications."
                                }
                            }
                        }
                    if !Notifier.available {
                        Text("Notifications need the built app (build-app.sh), not `swift run`.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                section("App") {
                    Toggle("Open at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { wanted in
                            do {
                                if wanted {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                message = "Couldn't change the login setting: \(error.localizedDescription)"
                            }
                        }
                    Button("Show Data File in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                    }
                    Text("Window position (on desktop, normal, always on top) is in the menu bar icon.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .panel()
    }

    private func signInToSync() {
        guard !signingIn else { return }
        signingIn = true
        syncMessage = nil
        let password = syncPassword
        Task {
            do {
                try await sync.signIn(url: syncURL, key: syncKey, email: syncEmail, password: password)
                syncPassword = ""
            } catch {
                syncMessage = "Couldn't sign in: \(error.localizedDescription)"
            }
            signingIn = false
        }
    }
}
