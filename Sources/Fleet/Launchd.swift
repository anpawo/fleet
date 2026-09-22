import Foundation

/// The jobs this machine runs on its own — the LaunchAgents in `~/Library/LaunchAgents`.
///
/// Marius calls them crons and there is no crontab on this machine: `crontab -l` answers "no
/// crontab for mr". What actually runs the Reels analyser at 9:15 and rebuilds the journal when
/// its database changes is launchd, so that is what the block reads.
///
/// Only his own are listed. The prefixes are the giveaway — everything else in that folder is
/// Google's updater and Zoom's helper, which are not routines anybody chose.
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
        /// Loaded and holding a pid right now. A calendar job is between runs nearly always,
        /// so this is not a health check — it is only ever read next to `failing`.
        var running: Bool
        /// The last run exited on an error of its own. The one thing here worth a colour: a
        /// routine that has been failing since Tuesday looks exactly like one that works.
        ///
        /// A *negative* status is not one of those — launchctl reports a job killed by a
        /// signal as minus the signal, and `install.sh` ends Fleet with a SIGTERM on every
        /// single run. Counting those, this block's own row was red for ever.
        var failing: Bool
        /// What it is for, in one sentence. Written by hand — see `notes`.
        var note: String
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
            let state = live[label]
            return Job(id: label,
                       name: shorten(label),
                       schedule: schedule(plist),
                       running: state?.pid != nil,
                       failing: (state?.exit ?? 0) > 0,
                       note: notes[label] ?? fallbackNote(plist))
        }.sorted { $0.name < $1.name }
    }

    /// The label without the part that only says whose it is.
    private static func shorten(_ label: String) -> String {
        for prefix in mine where label.hasPrefix(prefix) {
            return String(label.dropFirst(prefix.count))
        }
        return label
    }

    /// What makes the job run, read off the plist in the order launchd itself would: an
    /// explicit trigger first, and "at login" only when there is nothing else to say.
    private static func schedule(_ plist: [String: Any]) -> String {
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
        if plist["KeepAlive"] != nil { return "always on" }
        return plist["RunAtLoad"] as? Bool == true ? "at login" : "on demand"
    }

    /// One sentence per job, written here rather than in the plists: several of these files are
    /// rewritten by another project's `install.sh`, and a note kept inside them would be lost
    /// the next time that project was installed.
    private static let notes: [String: String] = [
        "com.mr.alttab": "The window switcher that replaces ⌘-Tab.",
        "com.mr.fleet": "This panel.",
        "com.mr.fleet.reels": "Downloads and transcribes the Reels you saved, then files the notes.",
        "com.mr.handy-uielement": "Re-signs Handy after a Tauri update so it stays out of the Dock.",
        "eu.epitech.scan": "Reads my.epitech, the intra and the mailbox, and files what is due.",
        "fr.marius.agents-report": "Counts what the agents did, for the portfolio's live page.",
        "fr.marius.finance-vol-binance_1h": "Keeps the volatility model fed with Binance hourly candles.",
        "fr.marius.finance-vol-donnees_60m": "The same model on the 60-minute series.",
        "fr.marius.mac-guard": "Kills whatever storms WindowServer or eats the last of the RAM.",
        "fr.marius.my-setup-sync": "Pushes this machine's settings and dotfiles to my-setup.",
        "io.scient.outline": "Syncs the S14 Outline wiki.",
        "io.scient.tailscaled-userspace": "Tailscale in userspace — the way onto the S14 boxes.",
        "scient.hermes-map": "Serves the Hermes dependency map on :8766.",
        "scient.journal": "Serves the S14 journal on :8767.",
        "scient.journal-board": "Rebuilds the journal board whenever its database changes.",
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
