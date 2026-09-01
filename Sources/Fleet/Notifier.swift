import AppKit
import UserNotifications

/// Tells you when a session starts waiting on you.
///
/// The panel only appears when you go idle or when you ask for it, which means a session that
/// asks a question while you are working in another window says nothing at all until you happen
/// to look. That is the one state where waiting costs you: the session is stopped, and it is
/// stopped on you. A banner is the smallest thing that closes that gap, and clicking it goes
/// straight to the terminal that asked.
///
/// Deliberately only for `awaitingAnswer`. Notifying on "finished" would fire constantly — every
/// turn of every session ends — and would train you to ignore the ones that matter.
@MainActor
final class Notifier: NSObject {

    /// Clicking a banner hands back the pid it named.
    var onSelect: ((pid_t) -> Void)?

    /// Sessions already announced, so a question that sits unanswered for ten minutes produces
    /// one banner rather than one per refresh. Cleared when the session stops waiting.
    private var announced: Set<pid_t> = []
    private var authorized = false

    /// `UNUserNotificationCenter` reads the running process's bundle, and a bare binary — `swift
    /// run`, `--render`, `--scan` — has none, which is a crash rather than a failure. Everything
    /// here is a no-op unless we are running from the .app.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func start() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error { NSLog("Fleet: notifications unavailable — \(error)") }
            // This answer arrives on whatever queue the notification centre feels like, which
            // is not the main one — asserting the isolation here rather than hopping to it
            // traps, and takes the app down at launch.
            Task { @MainActor in self?.authorized = granted }
        }
    }

    /// Called on every refresh with the current fleet.
    ///
    /// `panelVisible` suppresses the banner without suppressing the bookkeeping: if the panel is
    /// already on screen the question is right in front of you, and a banner on top of it is
    /// noise — but it still counts as announced, so dismissing the panel does not then produce a
    /// notification for something you have already seen.
    func update(sessions: [Session], panelVisible: Bool) {
        guard available else { return }

        let waiting = sessions.filter { $0.state == .awaitingAnswer }
        // Forget sessions that moved on — answered, or exited — so the next question they ask
        // gets its own banner.
        announced = announced.intersection(waiting.map(\.id))

        guard authorized else { return }
        for session in waiting where !announced.contains(session.id) {
            announced.insert(session.id)
            guard !panelVisible else { continue }
            post(for: session)
        }
    }

    /// A one-off banner that is not about a session — currently only the reaper reporting what
    /// it killed. Bypasses `announced`, which exists to stop a *standing* condition repeating
    /// itself; this is an event, and it happens once.
    func announce(title: String, body: String) {
        guard available, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "fleet.notice.\(UUID().uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Fleet: could not post notification — \(error)") }
        }
    }

    private func post(for session: Session) {
        let content = UNMutableNotificationContent()
        content.title = "\(session.dirName) needs you"
        // What it last said is usually the question, or the sentence leading into it.
        content.body = session.lastSaid.map { String($0.prefix(160)) } ?? "Waiting on an answer."
        content.sound = .default
        content.userInfo = ["pid": Int(session.proc.pid)]

        let request = UNNotificationRequest(
            identifier: "fleet.awaiting.\(session.proc.pid)",
            content: content,
            trigger: nil            // deliver now
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Fleet: could not post notification — \(error)") }
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {

    /// macOS suppresses a banner while its own app is frontmost. Fleet is frontmost exactly
    /// when its panel is up, and that case is already handled above, so ask for the banner
    /// anyway rather than losing it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let pid = info["pid"] as? Int else { return }
        await MainActor.run { self.onSelect?(pid_t(pid)) }
    }
}
