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
/// Two kinds live in that folder and they are not the same thing: the ones that run on a
/// trigger — a clock, a calendar, a file being written — and the ones that only keep a program
/// alive. Routines and applications. `triggered` says which, and the panel gives each its own
/// block: fourteen lines of which four were the thing you came to see is fourteen lines
/// nobody reads.
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
        /// Runs on its own — a clock, a calendar, a watched file. The other kind is an
        /// application launchd has been told to keep up. This is what `ok` is judged against,
        /// whatever block the card ends up in.
        var triggered: Bool

        /// Which block it goes in. Nearly always `!triggered`, but not always — see `guards`.
        var resident: Bool

        /// What the border says, and it does not mean the same thing for the two kinds. A
        /// routine is well when launchd knows about it and its last run did not end badly; a
        /// resident is well when it is up, and nothing else. A calendar job has no pid between
        /// runs and is perfectly alive; a server with no pid is the thing you needed to see.
        ///
        /// A resident's last exit status is history, not health: tailscaled died once when brew
        /// relinked it, KeepAlive brought it straight back, and the 78 it left behind kept its
        /// card red for the rest of the day while the daemon served traffic.
        var ok: Bool

        /// What it is for, in one sentence. Written by hand — see `notes`.
        var note: String

        /// Where it answers, when it answers anywhere: `http://localhost:8766`, or a bare
        /// `127.0.0.1:1055` for a port that is not a web server. Read off the running process
        /// rather than the plist — outline takes no port on its command line, and a job that
        /// moves to another port would otherwise keep advertising the old one.
        var address: String?

        /// Whether this agent is actually running, which the two blocks only show. Not `ok`:
        /// a routine that failed its last run is still scheduled and still the thing worth
        /// seeing, so only the ones launchd has never been told about drop out. A resident
        /// with no pid is not running, and that is the whole of it.
        var running: Bool { triggered ? enabled : ok }
    }

    /// Every agent of his, with what launchd currently says about it.
    /// `probing` is off on the main thread: see `serves`. The panel's first draw takes the
    /// answers already on disk, and the scan that follows is what learns any new one.
    static func jobs(probing: Bool = false) -> [Job] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let live = status()
        let ports = listening(live.values.compactMap(\.pid))
        return names.compactMap { file -> Job? in
            guard file.hasSuffix(".plist") else { return nil }
            let label = String(file.dropLast(6))
            guard mine.contains(where: label.hasPrefix), !hidden.contains(label) else { return nil }
            guard let data = try? Data(contentsOf: folder.appending(path: file)),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, format: nil) as? [String: Any] else { return nil }
            let state = live[label]
            let trigger = schedule(plist)
            let port = state?.pid.flatMap { ports[$0] }
            let enabled = state != nil
            let failing = (state?.exit ?? 0) > 0
            // A card in KEEP ALIVE says "always on", whatever holds the loop. mac.revive is a
            // routine on a 30-second timer standing among residents, and `every 30s` beside
            // four `always on` read as the odd one out rather than as the pair it makes with
            // mac.guard — which is the whole reason it was put there.
            let resident = trigger == nil || guards.contains(label)
            return Job(id: label,
                       name: shorten(label),
                       schedule: resident ? (trigger == nil ? resting(plist) : "always on")
                                          : trigger!,
                       enabled: enabled,
                       failing: failing,
                       triggered: trigger != nil,
                       resident: resident,
                       ok: trigger != nil ? (enabled && !failing) : state?.pid != nil,
                       note: notes[label] ?? fallbackNote(plist),
                       address: port.map { serves($0, probing: probing) ? "http://localhost:\($0)" : "127.0.0.1:\($0)" })
        }.sorted { $0.name < $1.name }
    }

    /// The label without the part that only says whose it is — except for the S14 agents, whose
    /// two prefixes (`scient.` and `io.scient.`) both mean the same job and neither of which is
    /// the word he uses. They all come back as "s14.<name>".
    /// Names he uses that the label does not carry.
    private static let names = [
        "fr.marius.mac-guard": "mac.guard",
        "fr.marius.revive": "mac.revive",
        "eu.epitech.scan": "epitech.scan",
        "fr.marius.my-setup-sync": "my-setup.sync",
        "fr.marius.m-mount": "s14.M: & F:",
        "scient.recon-mirror-check": "s14.Bas-mirror",
        "fr.marius.recon-v3": "s14.recon-v3",
        "io.scient.tailscaled-userspace": "s14.tailscale",
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
            return seconds % 86400 == 0 ? "every \(seconds / 86400 == 1 ? "day" : "\(seconds / 86400) days")"
                 : seconds % 3600 == 0 ? "every \(seconds / 3600)h"
                 : seconds >= 60 ? "every \(seconds / 60) min"
                 : "every \(seconds)s"
        }
        if let calendar = plist["StartCalendarInterval"] {
            let entries = (calendar as? [[String: Any]]) ?? [(calendar as? [String: Any]) ?? [:]]
            // Five entries that differ only by weekday are one time on five days, not five
            // times: the days go in front, and the same time is said once.
            var times: [String] = []
            for entry in entries {
                let hour = entry["Hour"] as? Int
                let minute = entry["Minute"] as? Int ?? 0
                let time = hour.map { String(format: "%d:%02d", $0, minute) } ?? "\(minute)′"
                if !times.contains(time) { times.append(time) }
            }
            let weekdays = Set(entries.compactMap { $0["Weekday"] as? Int }).sorted()
            let when = weekdays.isEmpty ? "" : weekdays == [1, 2, 3, 4, 5] ? "weekdays "
                     : weekdays.map { days[$0 % 7] }.joined(separator: " ") + " "
            return when + times.joined(separator: " \u{00B7} ")
        }
        if let paths = plist["WatchPaths"] as? [String], let first = paths.first {
            return "on \((first as NSString).lastPathComponent)"
        }
        return nil
    }

    /// Routines that belong with the residents anyway. mac-guard and mac-revive do the same
    /// job from either side — one stops what is about to freeze the Mac, the other starts back
    /// what should be running — and putting them in different blocks on the strength of who
    /// holds the loop (mac-guard sleeps inside its own process, mac-revive lets launchd count
    /// the thirty seconds) hid the pair.
    ///
    /// Their health is still read as a routine's: mac-revive exits as soon as it has looked,
    /// so it has no pid to have, and judging it the way a server is judged would leave it red
    /// for ever.
    private static let guards: Set<String> = ["fr.marius.revive"]

    /// The panel does not report on itself. If you can read this block, Fleet is running —
    /// a green card saying so is a line that can never say anything.
    private static let hidden: Set<String> = ["com.mr.fleet"]

    private static let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// What an agent with no trigger is doing there: it is a program launchd has been told to
    /// keep running, or to start once at login.
    private static func resting(_ plist: [String: Any]) -> String {
        if plist["KeepAlive"] != nil { return "always on" }
        return plist["RunAtLoad"] as? Bool == true ? "at login" : "on demand"
    }

    /// One sentence per job — what it is for, and nothing the card already says: the address
    /// it answers on is written a line above this one. Kept here rather than in the plists: several of these files are
    /// rewritten by another project's `install.sh`, and a note kept inside them would be lost
    /// the next time that project was installed.
    private static let notes: [String: String] = [
        "com.mr.fleet.reels": "Downloads and transcribes the Reels you saved, then files the notes.",
        "fr.marius.revive": "Starts back what should be running and is not.",
        "eu.epitech.scan": "Reads my.epitech, the intra and the mailbox, and files what is due.",
        "fr.marius.mac-guard": "Stops whatever is about to freeze the Mac.",
        "fr.marius.my-setup-sync": "Pushes this machine's settings and dotfiles to my-setup.",
        "fr.marius.m-mount": "Keeps M: and F: from mo-recon mounted over sshfs, and remounts them when the tunnel drops.",
        "io.scient.outline": "Syncs the S14 Outline wiki.",
        "io.scient.tailscaled-userspace": "Tailscale in userspace — the way onto the S14 boxes.",
        "scient.hermes-map": "Serves the Hermes dependency map.",
        "scient.recon-journal": "Serves the S14 recon journal.",
        "scient.recon-web": "Serves the S14 recon browser.",
        "scient.recon-mirror-check": "Checks that Bas's 18:00 S: → M: recon mirror ran, and says so on Matrix when it did not.",
    ]

    /// What an agent nobody has written a line for gets: the program it runs. Worse than a
    /// sentence and better than an empty card — a new agent still has a row that says something.
    private static func fallbackNote(_ plist: [String: Any]) -> String {
        let program = (plist["ProgramArguments"] as? [String])?.first
            ?? plist["Program"] as? String ?? ""
        return program.isEmpty ? "No note yet." : "Runs \((program as NSString).lastPathComponent)."
    }

    /// The lowest TCP port each of these processes is listening on, in one `lsof`. Lowest
    /// rather than first because the order `lsof` prints is the order of the file descriptors,
    /// which is whatever the program happened to open first; a server's own port is the one it
    /// was started for, and a second socket is nearly always something it dialled out on.
    static func listening(_ pids: [Int]) -> [Int: Int] {
        guard !pids.isEmpty else { return [:] }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pids.map(String.init).joined(separator: ",")]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return parseListening(String(decoding: data, as: UTF8.self))
    }

    /// Split out so it can be replayed against a captured `lsof` without one running — see
    /// `--selftest`.
    static func parseListening(_ output: String) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            // Not the last column: `lsof` puts `(LISTEN)` after the address. The address is
            // the last field that still parses as one, which also swallows the `[::1]:41641`
            // an IPv6 socket is printed as.
            guard columns.count >= 2, let pid = Int(columns[1]),
                  let port = columns.reversed().lazy
                      .filter({ $0.contains(":") })
                      .compactMap({ Int($0.split(separator: ":").last ?? "") })
                      .first else { continue }
            out[pid] = min(out[pid] ?? .max, port)
        }
        return out
    }

    /// Whether a port speaks HTTP, asked once and remembered for good. Nothing in the plist
    /// says so — tailscaled's 1055 is a SOCKS proxy and accepts a connection exactly like a web
    /// server does — and an `http://` that opens a browser on something that is not a page is
    /// worse than no link at all.
    ///
    /// Remembered in a file rather than in memory because the asking is slow: recon-web takes
    /// six and a half seconds to answer `/`, and a port has to be given that long before it can
    /// be called mute. Only the ten-second scan ever pays that, and it pays it once per port.
    /// A file rather than `UserDefaults` because `--render` runs as a bare binary with no
    /// bundle identifier, so it has a defaults domain of its own and would ask all over again.
    private static let cache = (Hooks.home as NSString).appendingPathComponent("http-ports.json")

    private static func known() -> [String: Bool] {
        guard let data = FileManager.default.contents(atPath: cache),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: Bool]
        else { return [:] }
        return map
    }

    private static func serves(_ port: Int, probing: Bool) -> Bool {
        var known = Self.known()
        if let answer = known["\(port)"] { return answer }
        guard probing else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        // Twenty seconds, which is absurd for a page and is what a cold one costs: recon-web
        // answered `/` in 9.3s on the first hit after a restart and in 0.17s on every one
        // after. A timeout short enough to feel reasonable filed it as "not a web server" for
        // good, and the link never came back.
        task.arguments = ["-s", "-o", "/dev/null", "-m", "20", "-w", "%{http_code}",
                          "http://127.0.0.1:\(port)/"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let answer = (Int(String(decoding: data, as: UTF8.self)) ?? 0) > 0
        known["\(port)"] = answer
        try? FileManager.default.createDirectory(atPath: Hooks.home,
                                                 withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: known).write(to: URL(fileURLWithPath: cache))
        return answer
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
    /// The routines — what runs on its own.
    @Published private(set) var crons: [Launchd.Job]
    /// The residents — programs launchd keeps up.
    @Published private(set) var alive: [Launchd.Job]

    private var lastScan = Date()
    private var scanning = false

    /// The first read is synchronous, once, at launch — the panel can open before the first
    /// tick, and a block that is empty for ten seconds looks like a block with nothing in it.
    init() {
        let scanned = Launchd.jobs().filter(\.running)
        crons = scanned.filter { !$0.resident }
        alive = scanned.filter(\.resident)
    }

    /// Called from `AppController.tick`, on the timer that is already running.
    func tick(now: Date = Date()) {
        guard !scanning, now.timeIntervalSince(lastScan) > 10 else { return }
        scanning = true
        lastScan = now
        Task.detached(priority: .utility) {
            let scanned = Launchd.jobs(probing: true).filter(\.running)
            await MainActor.run {
                self.crons = scanned.filter { !$0.resident }
                self.alive = scanned.filter(\.resident)
                self.scanning = false
            }
        }
    }
}
