import AppKit
import SwiftUI
import UserNotifications

@main
enum LearnDeskApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        app.run()
    }
}

/// A chromeless window that can still take keyboard focus.
final class DeskWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private let store = Store()
    private let appState = AppState()
    private lazy var session = QuizSession(store: store)
    private lazy var syncEngine = SyncEngine(store: store)

    private var window: DeskWindow!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var lastDueCount = 0
    private var nextPopQuiz: Date?
    private var popQuizHoursScheduled = 0.0

    /// Spacing kept from screen edges and neighbouring widgets, and how close counts as "near".
    private static let widgetGap: CGFloat = 20
    private static let snapDistance: CGFloat = 28
    private var snapTask: Task<Void, Never>?
    private var isSnapping = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildWindow()
        buildStatusItem()

        if Notifier.available {
            UNUserNotificationCenter.current().delegate = self
        }

        store.onLocalChange = { [weak self] in
            self?.syncEngine.schedule()
        }

        lastDueCount = store.dueCards().count
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Window

    private func buildWindow() {
        window = DeskWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 540),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 360, height: 380)
        window.delegate = self

        let root = RootView()
            .environmentObject(store)
            .environmentObject(appState)
            .environmentObject(session)
        window.contentView = NSHostingView(rootView: root)

        // Restore the last position, or start in the top-right corner.
        if !window.setFrameUsingName("LearnDeskMain"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.maxX - 380 - 24, y: visible.maxY - 540 - 24))
        }
        window.setFrameAutosaveName("LearnDeskMain")

        applyPinMode()
        window.orderFrontRegardless()
    }

    private func applyPinMode() {
        switch PinMode.current {
        case .desktop:
            // Just below ordinary windows: other apps cover it, the desktop doesn't.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        case .normal:
            window.level = .normal
            window.collectionBehavior = []
        case .floating:
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces]
        }
    }

    /// Bring the widget in front of everything until the user clicks away.
    private func showWindow(tab: AppState.Tab? = nil) {
        if let tab { appState.tab = tab }
        if PinMode.current == .desktop {
            window.level = .floating
        }
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
    }

    func windowDidResignKey(_ notification: Notification) {
        applyPinMode()
    }

    // MARK: Snapping

    /// Once a drag ends, line the widget up with nearby system widgets and screen edges.
    func windowDidMove(_ notification: Notification) {
        guard !isSnapping else { return }
        snapTask?.cancel()
        snapTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return }
                if NSEvent.pressedMouseButtons == 0 { break }
            }
            self?.snapIntoPlace()
        }
    }

    private func snapIntoPlace() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let frame = window.frame
        var bestDX: CGFloat?
        var bestDY: CGFloat?

        func consider(_ delta: CGFloat, _ best: inout CGFloat?) {
            if abs(delta) <= Self.snapDistance, abs(delta) < abs(best ?? .infinity) {
                best = delta
            }
        }

        // Screen edges, with the same margin widgets keep between each other.
        let area = screen.visibleFrame.insetBy(dx: Self.widgetGap, dy: Self.widgetGap)
        consider(area.minX - frame.minX, &bestDX)
        consider(area.maxX - frame.maxX, &bestDX)
        consider(area.minY - frame.minY, &bestDY)
        consider(area.maxY - frame.maxY, &bestDY)

        // System widgets: share an edge with one, or sit beside it one gap away.
        let reach = Self.widgetGap + Self.snapDistance
        for widget in systemWidgetFrames() where widget.insetBy(dx: -reach, dy: -reach).intersects(frame) {
            consider(widget.minX - frame.minX, &bestDX)
            consider(widget.maxX - frame.maxX, &bestDX)
            consider(widget.maxX + Self.widgetGap - frame.minX, &bestDX)
            consider(widget.minX - Self.widgetGap - frame.maxX, &bestDX)
            consider(widget.minY - frame.minY, &bestDY)
            consider(widget.maxY - frame.maxY, &bestDY)
            consider(widget.maxY + Self.widgetGap - frame.minY, &bestDY)
            consider(widget.minY - Self.widgetGap - frame.maxY, &bestDY)
        }

        let dx = bestDX ?? 0
        let dy = bestDY ?? 0
        guard dx != 0 || dy != 0 else { return }
        isSnapping = true
        window.setFrame(frame.offsetBy(dx: dx, dy: dy), display: true, animate: true)
        isSnapping = false
    }

    /// Frames of the desktop widgets macOS is showing, in AppKit screen coordinates.
    private func systemWidgetFrames() -> [CGRect] {
        guard let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var frames: [CGRect] = []
        for info in windows {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.notificationcenterui",
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            // Skip anything that isn't widget-sized (e.g. a full-screen backing window).
            guard bounds.width >= 100, bounds.height >= 100,
                  bounds.width < primary.frame.width * 0.8
            else { continue }
            // Core Graphics measures from the top-left of the primary screen; AppKit from the bottom-left.
            frames.append(CGRect(x: bounds.minX, y: primary.frame.height - bounds.maxY,
                                 width: bounds.width, height: bounds.height))
        }
        return frames
    }

    // MARK: Menus

    /// An invisible main menu, so Cmd-C/V/X/A/Z work in text fields.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit LearnDesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "graduationcap", accessibilityDescription: "LearnDesk")
            button.imagePosition = .imageLeading
        }
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        menu.addItem(item("Show LearnDesk", #selector(showFromMenu)))
        menu.addItem(item("Hide LearnDesk", #selector(hideFromMenu)))
        menu.addItem(.separator())
        let due = store.dueCards().count
        menu.addItem(item(due > 0 ? "Quiz Me on \(due) Due" : "No Questions Due", #selector(quizDue), enabled: due > 0))
        menu.addItem(item("Quiz Me at Random", #selector(quizRandom), enabled: !store.data.cards.isEmpty))
        menu.addItem(.separator())
        for mode in PinMode.allCases {
            let entry = item(mode.label, #selector(choosePinMode(_:)))
            entry.representedObject = mode.rawValue
            entry.state = PinMode.current == mode ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        if syncEngine.signedIn {
            menu.addItem(item(syncEngine.statusText, #selector(syncFromMenu)))
        }
        let settings = item("Settings…", #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(withTitle: "Quit LearnDesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let panel = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "LearnDesk Settings"
            panel.isReleasedWhenClosed = false
            let root = SettingsView()
                .padding(.top, 12)
                .frame(width: 400, height: 600)
                .environmentObject(store)
                .environmentObject(appState)
                .environmentObject(syncEngine)
            panel.contentView = NSHostingView(rootView: root)
            panel.center()
            settingsWindow = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func syncFromMenu() {
        Task { await syncEngine.syncNow() }
    }

    @objc private func showFromMenu() { showWindow() }
    @objc private func hideFromMenu() { window.orderOut(nil) }

    @objc private func quizDue() {
        session.startDue()
        showWindow(tab: .quiz)
    }

    @objc private func quizRandom() {
        session.startRandom(count: 5)
        showWindow(tab: .quiz)
    }

    @objc private func choosePinMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = PinMode(rawValue: raw) else { return }
        PinMode.current = mode
        applyPinMode()
        rebuildStatusMenu()
    }

    // MARK: Reminders

    private func tick() {
        let due = store.dueCards().count
        statusItem.button?.title = due > 0 ? " \(due)" : ""
        rebuildStatusMenu()

        if due > 0 && lastDueCount == 0 {
            Notifier.send(
                title: "Questions ready",
                body: due == 1 ? "1 question is due for review." : "\(due) questions are due for review."
            )
        }
        lastDueCount = due

        runPopQuizIfDue()
        Task {
            await syncEngine.syncNow()
            await store.generatePending()
        }
    }

    private func runPopQuizIfDue() {
        let hours = UserDefaults.standard.double(forKey: Prefs.popQuizHours)
        guard hours > 0 else {
            nextPopQuiz = nil
            return
        }
        if nextPopQuiz == nil || hours != popQuizHoursScheduled {
            scheduleNextPopQuiz(hours: hours)
            return
        }
        guard let next = nextPopQuiz, Date() >= next else { return }
        scheduleNextPopQuiz(hours: hours)

        guard !store.data.cards.isEmpty, !session.isActive else { return }
        session.startRandom(count: 1)
        appState.tab = .quiz
        Notifier.send(title: "Pop quiz", body: session.current?.question ?? "A question is waiting.")
    }

    /// Somewhere between half and one-and-a-half times the chosen interval.
    private func scheduleNextPopQuiz(hours: Double) {
        popQuizHoursScheduled = hours
        nextPopQuiz = Date().addingTimeInterval(hours * 3600 * Double.random(in: 0.5...1.5))
    }

    // MARK: Notifications

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            if !self.session.isActive {
                self.session.startDue()
            }
            self.showWindow(tab: .quiz)
        }
        completionHandler()
    }
}
