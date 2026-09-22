import Foundation
import SwiftUI

/// The jobs this machine runs on its own — the LaunchAgents in `~/Library/LaunchAgents`.
///
/// Marius calls them crons and there is no crontab on this machine: `crontab -l` answers "no
/// crontab for mr". What actually runs the Reels analyser at 9:15 and rebuilds the journal when
/// its database changes is launchd, so that is what the block reads.
///
/// Only his own are listed. The prefixes are the giveaway — everything else in that folder is
/// Google's updater and Zoom's helper, which are not routines anybody chose.
///
/// And only the ones that actually run on a trigger: a clock, a calendar, a file being written.
/// The same folder holds the agents that only keep a program alive — Fleet itself, the S14
/// servers, the window switcher — and those are applications, not routines. They were in the
/// block and made it unreadable: fourteen lines of which four were the thing you came to see.
enum Launchd {
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/LaunchAgents")

    /// Whose agents are worth a line. Not a blocklist of the others: a new vendor dropping an
    /// updater in there must not silently appear in the panel.
    private static let mine = ["com.mr.", "fr.marius.", "eu.epitech.", "scient.", "io.scient."]

    struct Job: Identifiable {
        /// The launchd label, which is also the plist's file name.
        var id: String
        /// The label without its prefix — "fleet.reels" rather than "com.mr.fleet.reels".
        var name: String
        /// When it runs, in the fewest words that say it.
        var schedule: String
        /// Loaded in launchd. Not "has a pid": a job that runs at 9:15 has none for the other
        /// twenty-three hours and is perfectly alive. A plist sitting in the folder that
        /// launchd has never been told about is the one that is off, and that is what shows.
        var enabled: Bool
        /// The last run exited on an error of its own. The one thing here worth a colour: a
        /// routine that has been failing since Tuesday looks exactly like one that works.
        ///
        /// A *negative* status is not one of those — launchctl reports a job killed by a
        /// signal as minus the signal, and `install.sh` ends Fleet with a SIGTERM on every
        /// single run. Counting those, this block's own row was red for ever.
        var failing: Bool
        /// What it is for, in one sentence. Written by hand — see `notes`.
        var note: String

        /// On, and its last run did not end badly. The whole of what the border says.
        var ok: Bool { enabled && !failing }
    }

    /// Every agent of his, with what launchd currently says about it.
    static func jobs() -> [Job] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let live = status()
        return names.compactMap { file -> Job? in
            guard file.hasSuffix(".plist") else { return nil }
            let label = String(file.dropLast(6))
            guard mine.contains(where: label.hasPrefix) else { return nil }
            guard let data = try? Data(contentsOf: folder.appending(path: file)),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, format: nil) as? [String: Any] else { return nil }
            // No trigger, no line. This is what keeps the resident apps out.
            guard let schedule = schedule(plist) else { return nil }
            let state = live[label]
            return Job(id: label,
                       name: shorten(label),
                       schedule: schedule,
                       enabled: state != nil,
                       failing: (state?.exit ?? 0) > 0,
                       note: notes[label] ?? fallbackNote(plist))
        }.sorted { $0.name < $1.name }
    }

    /// The label without the part that only says whose it is — except for the S14 agents, whose
    /// two prefixes (`scient.` and `io.scient.`) both mean the same job and neither of which is
    /// the word he uses. They all come back as "s14.<name>".
    /// Names he uses that the label does not carry.
    private static let names = [
        "fr.marius.mac-guard": "mac.guard",
        "eu.epitech.scan": "epitech.scan",
        "fr.marius.my-setup-sync": "my-setup.sync",
    ]

    private static func shorten(_ label: String) -> String {
        if let name = names[label] { return name }
        for prefix in ["io.scient.", "scient."] where label.hasPrefix(prefix) {
            return "s14." + label.dropFirst(prefix.count)
        }
        for prefix in mine where label.hasPrefix(prefix) {
            return String(label.dropFirst(prefix.count))
        }
        return label
    }

    /// What makes the job run, read off the plist in the order launchd itself would — or
    /// nothing at all, for an agent that has no trigger and only exists to keep a program
    /// running. `KeepAlive` and `RunAtLoad` are not schedules; that is an app being started.
    private static func schedule(_ plist: [String: Any]) -> String? {
        if let seconds = plist["StartInterval"] as? Int {
            return seconds % 3600 == 0 ? "every \(seconds / 3600)h"
                 : seconds >= 60 ? "every \(seconds / 60) min"
                 : "every \(seconds)s"
        }
        if let calendar = plist["StartCalendarInterval"] {
            let entries = (calendar as? [[String: Any]]) ?? [(calendar as? [String: Any]) ?? [:]]
            let times = entries.map { entry -> String in
                let hour = entry["Hour"] as? Int
                let minute = entry["Minute"] as? Int ?? 0
                return hour.map { String(format: "%d:%02d", $0, minute) } ?? "\(minute)′"
            }
            return times.joined(separator: " \u{00B7} ")
        }
        if let paths = plist["WatchPaths"] as? [String], let first = paths.first {
            return "on \((first as NSString).lastPathComponent)"
        }
        return nil
    }

    /// One sentence per job, written here rather than in the plists: several of these files are
    /// rewritten by another project's `install.sh`, and a note kept inside them would be lost
    /// the next time that project was installed.
    private static let notes: [String: String] = [
        "com.mr.fleet": "This panel.",
        "com.mr.fleet.reels": "Downloads and transcribes the Reels you saved, then files the notes.",
        "fr.marius.revive": "Restarts what must always be running — alt-tab, and whatever else is in its list.",
        "eu.epitech.scan": "Reads my.epitech, the intra and the mailbox, and files what is due.",
        "fr.marius.agents-report": "Counts what the agents did, for the portfolio's live page.",
        "fr.marius.finance-vol-binance_1h": "Keeps the volatility model fed with Binance hourly candles.",
        "fr.marius.finance-vol-donnees_60m": "The same model on the 60-minute series.",
        "fr.marius.mac-guard": "Kills whatever storms WindowServer or eats the last of the RAM.",
        "fr.marius.my-setup-sync": "Pushes this machine's settings and dotfiles to my-setup.",
        "io.scient.outline": "Syncs the S14 Outline wiki.",
        "io.scient.tailscaled-userspace": "Tailscale in userspace — the way onto the S14 boxes.",
        "scient.hermes-map": "Serves the Hermes dependency map on :8766.",
        "scient.recon-journal": "Serves the S14 recon journal on :8767.",
    ]

    /// What an agent nobody has written a line for gets: the program it runs. Worse than a
    /// sentence and better than an empty card — a new agent still has a row that says something.
    private static func fallbackNote(_ plist: [String: Any]) -> String {
        let program = (plist["ProgramArguments"] as? [String])?.first
            ?? plist["Program"] as? String ?? ""
        return program.isEmpty ? "No note yet." : "Runs \((program as NSString).lastPathComponent)."
    }

    /// `launchctl list`: pid, last exit status, label — one line each, tab separated, with a
    /// header. A dash in either of the first two columns means launchd has nothing to say.
    private static func status() -> [String: (pid: Int?, exit: Int)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["list"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        var out: [String: (Int?, Int)] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3 else { continue }
            out[String(columns[2])] = (Int(columns[0]), Int(columns[1]) ?? 0)
        }
        return out
    }
}

/// What the panel reads. Not the enum above straight from `body`: `launchctl list` is a
/// process spawn and a pipe, and reading it on every redraw put 30 ms of main thread between
/// the panel and every hover — the day it shipped the columns drew themselves in pieces.
///
/// Scanned off the main thread, at most once every ten seconds. A routine that runs hourly
/// does not need better, and nothing here changes unless an agent is installed or dies.
@MainActor
final class LaunchdStore: ObservableObject {
    @Published private(set) var jobs: [Launchd.Job]

    private var lastScan = Date()
    private var scanning = false

    /// The first read is synchronous, once, at launch — the panel can open before the first
    /// tick, and a block that is empty for ten seconds looks like a block with nothing in it.
    init() { jobs = Launchd.jobs() }

    /// Called from `AppController.tick`, on the timer that is already running.
    func tick(now: Date = Date()) {
        guard !scanning, now.timeIntervalSince(lastScan) > 10 else { return }
        scanning = true
        lastScan = now
        Task.detached(priority: .utility) {
            let scanned = Launchd.jobs()
            await MainActor.run {
                self.jobs = scanned
                self.scanning = false
            }
        }
    }
}
