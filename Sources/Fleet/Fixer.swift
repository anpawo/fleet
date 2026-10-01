import Foundation

/// A headless Claude sent after one line of ALERT, on a click.
///
/// The bar says what is broken and Fleet's own retry covers the run that was merely unlucky.
/// What is left is the kind that needs reading a log and changing something, which until now
/// meant opening a session and typing the alert back in.
///
/// On a click, never on its own: this is a session with every tool and nobody to ask, and an
/// alert that comes back every morning would send one out every morning.
@MainActor
final class Fixer: ObservableObject {
    /// What a Claude is out on right now, by `subject`.
    @Published private(set) var running: Set<String> = []

    /// The title and the verdict, once it is back.
    var report: (String, String) -> Void = { _, _ in }

    /// Every report in full, newest last — the banner only has room for the verdict.
    static let log = URL(fileURLWithPath: "/tmp/fleet-fix.log")

    func fixing(_ alert: String) -> Bool { running.contains(Self.subject(alert)) }

    /// For `--render --fixing <alert>`: the chip as it is while a Claude is out on it.
    func simulate(_ alert: String) { running.insert(Self.subject(alert)) }

    func fix(_ alert: String, crons: [Launchd.Job]) {
        let subject = Self.subject(alert)
        guard running.insert(subject).inserted else { return }
        Task {
            let verdict = await Self.run(alert, crons: crons)
            running.remove(subject)
            report("Fix: \(subject)", verdict)
        }
    }

    /// Sends the Claude, files what it said, and returns its first line.
    static func run(_ alert: String, crons: [Launchd.Job]) async -> String {
        var said: String
        do { said = try await Claude.unattended(prompt(alert, crons: crons)) }
        catch { said = "the fixer itself failed: \(error.localizedDescription)" }
        // His display hook colours the first and last lines, and the codes come out in `-p` too.
        said = said.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let entry = "=== \(Date().formatted(date: .abbreviated, time: .shortened)) · \(alert) ===\n\(said)\n\n"
        if let handle = try? FileHandle(forWritingTo: log) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: log, atomically: true, encoding: .utf8)
        }
        let first = said.split(separator: "\n").first.map(String.init) ?? said
        return first.hasPrefix("⟶ ") ? String(first.dropFirst(2)) : first
    }

    /// The line without its age: "recon hung 2h" is the same thing to fix an hour later, and
    /// the chip has to still read as taken.
    static func subject(_ alert: String) -> String {
        for mark in [" hung ", " deferred "] {
            if let cut = alert.range(of: mark) { return String(alert[..<cut.lowerBound]) }
        }
        return alert
    }

    /// The alert, and where to start reading — which depends on who wrote the line. See
    /// `AlertsBlock.alerts` for the four sources.
    static func prompt(_ alert: String, crons: [Launchd.Job]) -> String {
        let facts: String
        if let job = crons.first(where: { $0.name == subject(alert) }) {
            facts = """
            It is the launchd routine `\(job.id)` (\(job.note)). \
            ~/Library/LaunchAgents/\(job.id).plist names its program and its log; \
            `launchctl print gui/\(getuid())/\(job.id)` has its last exit and whether a run is \
            going now. Fleet has already started it again once, and that run failed too — or \
            it is hung or deferred, as the line says. If a run is going, wait for it rather \
            than start a second one.
            """
        } else if alert.hasPrefix("reel ") {
            facts = """
            It is a Reel that Fleet's analyser gave up on after \(Reel.maxTries) tries. The \
            analyser is `fleet --reels-run` (~/self/fleet/Sources/Fleet/Reels.swift), its log \
            /tmp/fleet-reels.log; `fleet --reels` lists them and `fleet --check-reel \
            <shortcode>` runs one.
            """
        } else if alert.hasPrefix("firestore") || alert.hasPrefix("todo") {
            facts = """
            It is Fleet's own read or write of the phone's Firestore project \
            (~/self/fleet/Sources/Fleet/Firestore.swift and Hub.swift), log /tmp/fleet.log.
            """
        } else {
            facts = """
            It is from the Epitech scan: ~/.epitech/sources.json has each reader's exit code \
            from the last run, ~/.epitech/run.log what they printed, and the readers are in \
            ~/self/epitech/scanner. Re-run only the reader that failed (scan.mjs, edsquare.mjs, \
            outlook.mjs), never run.sh as a whole and never discord.mjs: a self-bot that \
            retries is a fingerprint, and that account is his.
            """
        }
        return """
        Fleet's ALERT bar on Marius's Mac reads: "\(alert)". Find out why and fix it.

        \(facts)

        Nobody is there to answer a question. Find the root cause before changing anything. \
        If it can be fixed from this machine, fix it, then prove it: run what failed again and \
        read its exit. Delete nothing, send nothing to anyone, and never type or ask for a \
        password. If it needs Marius — a login, a decision — change nothing.

        Your first line is the verdict, in one sentence: what was wrong and what you did, or \
        what he has to do.
        """
    }
}
