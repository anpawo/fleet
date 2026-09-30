import Foundation
import Network
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
/// alive. Routines and applications. `triggered` says which, and it is what a card's health is
/// judged against — see `Job.ok`. One block for both: they are drawn by family, and mac.guard
/// next to mac.revive says more than a resident block next to a routine block did.
enum Launchd {
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/LaunchAgents")

    /// Whose agents are worth a line. Not a blocklist of the others: a new vendor dropping an
    /// updater in there must not silently appear in the panel.
    private static let mine = ["app.", "mac.", "s14.", "epitech.", "reels.", "my-setup."]

    struct Job: Identifiable {
        /// The launchd label, which is also the plist's file name.
        var id: String
        /// The label itself — the labels are named the way the panel says them (26-09-2026).
        var name: String
        /// When it runs, in the fewest words that say it.
        var schedule: String
        /// Loaded in launchd. Not "has a pid": a job that runs at 9:15 has none for the other
        /// twenty-three hours and is perfectly alive. A plist sitting in the folder that
        /// launchd has never been told about is the one that is off, and that is what shows.
        var enabled: Bool
        /// The last run did not exit 0, nor 75 — see `deferred`. The one thing here worth a
        /// colour: a routine that has been failing since Tuesday looks exactly like one that
        /// works.
        ///
        /// A kill counts too — launchctl reports one as minus the signal, and a watchdog that
        /// had to kill a routine is a routine that failed. The one job killed on purpose,
        /// Fleet's own on every `install.sh`, is an app, judged on being up rather than on this.
        var failing: Bool
        /// Runs on its own — a clock, a calendar, a watched file. The other kind is an
        /// application launchd has been told to keep up. This is what `ok` is judged against,
        /// whatever block the card ends up in.
        var triggered: Bool

        /// What the border says, and it does not mean the same thing for the two kinds. A
        /// routine is well when launchd knows about it and its last run did not end badly; a
        /// resident — an application launchd keeps up — is well when it is up, and nothing
        /// else. A calendar job has no pid between runs and is perfectly alive; a server with
        /// no pid is the thing you needed to see.
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

        /// Has a process right now — for a routine, a run in progress.
        var busy = false
        /// Fleet has started it again after a failed run and that run has not ended yet: ALERT
        /// waits for its answer — see `LaunchdStore.repair`.
        var repairing = false
        /// The last run exited 75, EX_TEMPFAIL: `online` gave up waiting for the network and
        /// put the run off to the next slot. Not a failure — nothing is wrong with the routine,
        /// and running it again while the wifi is still out would only defer it again.
        var deferred = false
        /// How long the run in progress has been going, when that is longer than its schedule
        /// allows — see `allowance`. launchd starts no new run while one is going and
        /// `launchctl list` keeps the previous exit, so a run stuck for hours on a dead sshfs
        /// read otherwise looks exactly like a healthy routine between two runs.
        var hung: TimeInterval?
        /// How long a run may go before it is hung — see `Launchd.allowance`.
        var allowance: TimeInterval = 0
        /// How long it has been deferred run after run, once that is past what a wifi outage
        /// explains — see `LaunchdStore.repair`. A VPN that blocks captive.apple.com defers
        /// every run, and mcp-renew stayed amber for a day while its token ran out.
        var deferredFor: TimeInterval?

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
        let now = Date(), wake = wakeTime()
        let ages = elapsed(live.filter { mine.contains(where: $0.key.hasPrefix) }.values.compactMap(\.pid))
            .mapValues { awake($0, now: now, wake: wake) }
        return names.compactMap { file -> Job? in
            guard file.hasSuffix(".plist") else { return nil }
            let label = String(file.dropLast(6))
            guard mine.contains(where: label.hasPrefix) else { return nil }
            guard let data = try? Data(contentsOf: folder.appending(path: file)),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, format: nil) as? [String: Any] else { return nil }
            let state = live[label]
            var job = judge(label, plist, state, age: state?.pid.flatMap { ages[$0] })
            job.address = state?.pid.flatMap { ports[$0] }
                .map { serves($0, probing: probing) ? "http://localhost:\($0)" : "127.0.0.1:\($0)" }
            return job
        }.sorted { $0.name < $1.name }
    }

    /// What launchd's word on one agent means — the plist, and `launchctl list`'s pid and last
    /// exit (nil when it does not list the agent) — with nothing spawned, so `--selftest` can
    /// replay it. The address is left to `jobs`, which has to ask the port.
    static func judge(_ label: String, _ plist: [String: Any], _ state: (pid: Int?, exit: Int)?,
                      age: TimeInterval?) -> Job {
        let trigger = schedule(plist)
        let enabled = state != nil
        let exit = state?.exit ?? 0
        let failing = exit != 0 && exit != tempfail
        let hung = trigger == nil ? nil : Launchd.hung(age, plist)
        return Job(id: label,
                   name: shorten(label),
                   schedule: trigger ?? resting(plist),
                   enabled: enabled,
                   failing: failing,
                   triggered: trigger != nil,
                   ok: trigger != nil ? (enabled && !failing && hung == nil) : state?.pid != nil,
                   note: notes[label] ?? fallbackNote(plist),
                   busy: state?.pid != nil,
                   // A resident's last exit is history — see `ok`.
                   deferred: trigger != nil && exit == tempfail,
                   hung: hung,
                   allowance: allowance(plist))
    }

    /// The label of every plist in the folder, whether or not it parses.
    static func labels() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".plist") }.map { String($0.dropLast(6)) })
    }

    /// The labels carry the names he uses since 26-09-2026 (`mac.guard`, `s14.recon-v3`…), so a
    /// card says its label. One reads better as two drive letters than as a word.
    private static let names = [
        "s14.mounts": "s14.M: & F:",
    ]

    private static func shorten(_ label: String) -> String {
        names[label] ?? label
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
        "reels.scan": "Downloads and transcribes the Reels you saved, then files the notes.",
        "mac.revive": "Starts back what should be running and is not.",
        "epitech.scan": "Reads my.epitech, the intra and the mailbox, and files what is due.",
        "mac.guard": "Stops whatever is about to freeze the Mac.",
        "my-setup.sync": "Pushes this machine's settings and dotfiles to my-setup.",
        "s14.mounts": "Keeps M: and F: from mo-recon mounted over sshfs, and remounts them when the tunnel drops.",
        "s14.outline": "Syncs the S14 Outline wiki.",
        "s14.tailscale": "Tailscale in userspace — the way onto the S14 boxes.",
        "s14.hermes-map": "Serves the Hermes dependency map.",
        "s14.recon-journal": "Serves the S14 recon journal.",
        "s14.recon-v1": "Runs Bas's V1 recon in a sandbox on mo-recon, hourly, on the latest trade date.",
        "s14.recon-v3": "Runs V3 on both books every 4 hours, and opens the two reports in Excel.",
        "s14.recon-web": "Serves the S14 recon browser.",
        "s14.mcp-renew": "Renews the scient MCP token before its 24 h run out.",
        "s14.mirror-check": "Checks that Bas's 18:00 S: → M: recon mirror ran, and says so on Matrix when it did not.",
        "app.fleet": "This panel.",
        "app.screenshot": "Screenshots and screen recordings, on ⌘⇧5.",
        "config.gc": "Lists what has gone stale in ~/.claude, on Sundays.",
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

    /// EX_TEMPFAIL, what `online` exits with when it gave up waiting for the network. launchctl
    /// reports it as a plain 75 — a signal would be negative (measured 28-09-2026 with a
    /// throwaway `launchctl submit` of `exit 75`).
    static let tempfail = 75

    /// Five minutes: under that a run is slow, not stuck — `online` alone sleeps 90 s between
    /// two looks at the network, and s14.mounts, every minute, would go red on its first wait.
    static let floor: TimeInterval = 5 * 60
    /// Six hours: the longest run on record here is the Epitech scan's 95 minutes (22-09), and
    /// `online` may run a job three times with up to 21.5 minutes of waiting before each — 5h50
    /// for that one. Kept at six even though three 100-minute scans would pass it: the scan
    /// runs every six hours, so a run that long has missed its next slot, which is what hung
    /// means here. And a daily job stuck since morning must not wait for tomorrow to be called hung.
    static let ceiling: TimeInterval = 6 * 3600

    /// How long a run may go before it is hung: until its next run was due, which it has then
    /// missed — launchd does not start one while it is still going. For a calendar job that is
    /// the shortest gap between two of its times in a week; a watched path has no next run,
    /// and gets the ceiling. `Day` and `Month` are ignored, which only shortens the gap, and
    /// the ceiling is shorter than any gap they would make.
    static func allowance(_ plist: [String: Any]) -> TimeInterval {
        var period = ceiling
        if let seconds = plist["StartInterval"] as? Int {
            period = TimeInterval(seconds)
        } else if let calendar = plist["StartCalendarInterval"] {
            let entries = (calendar as? [[String: Any]]) ?? [(calendar as? [String: Any]) ?? [:]]
            var fires = Set<Int>()
            for entry in entries {
                let days = (entry["Weekday"] as? Int).map { [$0 % 7] } ?? Array(0..<7)
                let hours = (entry["Hour"] as? Int).map { [$0] } ?? Array(0..<24)
                let minutes = (entry["Minute"] as? Int).map { [$0] } ?? Array(0..<60)
                for d in days { for h in hours { for m in minutes { fires.insert((d * 24 + h) * 60 + m) } } }
            }
            let sorted = fires.sorted()
            if let first = sorted.first, let last = sorted.last {
                let gaps = zip(sorted, sorted.dropFirst()).map { $1 - $0 } + [first + 7 * 1440 - last]
                period = TimeInterval(gaps.min()! * 60)
            }
        }
        return min(max(period, floor) + waits(plist), ceiling)
    }

    /// What `~/.local/bin/online` may spend waiting on top of the run: up to three passes, each
    /// after a wait of up to ONLINE_WAIT (its default, 1200 s) that its 90 s sleep and 5 s probe
    /// can overrun. Without it an hourly routine that waited 20 minutes and then ran 45 was hung.
    static func waits(_ plist: [String: Any]) -> TimeInterval {
        // Second when `catchup` goes first.
        guard let args = plist["ProgramArguments"] as? [String],
              args.prefix(2).contains(where: { $0.hasSuffix("/online") }) else { return 0 }
        let wait = ((plist["EnvironmentVariables"] as? [String: String])?["ONLINE_WAIT"])
            .flatMap(TimeInterval.init) ?? 1200
        return 3 * (wait + 95)
    }

    /// How long the run has been going, when that is past its allowance.
    static func hung(_ age: TimeInterval?, _ plist: [String: Any]) -> TimeInterval? {
        guard let age, age > allowance(plist) else { return nil }
        return age
    }

    /// How long each of these processes has been running, in one `ps`. A pid that has gone
    /// meanwhile is left out of the answer, not an error.
    static func elapsed(_ pids: [Int]) -> [Int: TimeInterval] {
        guard !pids.isEmpty else { return [:] }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "pid=,etime=", "-p", pids.map(String.init).joined(separator: ",")]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        var out: [Int: TimeInterval] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let columns = line.split(separator: " ")
            guard columns.count == 2, let pid = Int(columns[0]),
                  let age = parseElapsed(columns[1]) else { continue }
            out[pid] = age
        }
        return out
    }

    /// A run's age counted from the last wake at most. etime keeps counting while the lid is
    /// shut, so a routine asleep mid-run all night woke up "hung" — and a run that really was
    /// stuck before the sleep is only called so one allowance after the wake.
    static func awake(_ etime: TimeInterval, now: Date, wake: Date?) -> TimeInterval {
        guard let wake else { return etime }
        return min(etime, now.timeIntervalSince(wake))
    }

    /// `kern.waketime`, or nil when the Mac has not slept since boot (it reads 0 then).
    static func wakeTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.waketime", &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1e6)
    }

    /// `ps`'s etime, `[[dd-]hh:]mm:ss`, in seconds.
    static func parseElapsed(_ text: Substring) -> TimeInterval? {
        let parts = text.split(separator: "-")
        guard (1...2).contains(parts.count), let days = parts.count == 2 ? Int(parts[0]) : 0 else { return nil }
        let clock = parts[parts.count - 1].split(separator: ":").map { Int($0) }
        guard (2...3).contains(clock.count), !clock.contains(nil) else { return nil }
        return TimeInterval(days * 86400 + clock.reduce(0) { $0 * 60 + $1! })
    }

    /// "40 min", "2h", "3d" — how long, in the fewest characters ALERT has room for.
    static func span(_ seconds: TimeInterval) -> String {
        seconds < 3600 ? "\(Int(seconds) / 60) min" : seconds < 2 * 86400 ? "\(Int(seconds) / 3600)h" : "\(Int(seconds) / 86400)d"
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
    /// Every agent, routine or resident, in one list: the block draws them by family, not by kind.
    @Published private(set) var jobs: [Launchd.Job]

    private var lastScan = Date()
    private var scanning = false

    /// On in the resident app only: a `--render` must not start anybody's routine.
    var repairs = false

    /// The first read is synchronous, once, at launch — the panel can open before the first
    /// tick, and a block that is empty for ten seconds looks like a block with nothing in it.
    /// Through `repair`, with `repairs` still off: a routine Fleet was retrying when it was
    /// restarted is still `repairing`, not in ALERT until the first scan.
    init() {
        jobs = []
        jobs = repair(Launchd.jobs(), now: Date()).filter(\.running)
        // @Sendable: the monitor calls it on its own queue, not on the main actor.
        path.pathUpdateHandler = { @Sendable [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.network(up) }
        }
        path.start(queue: .global(qos: .utility))
    }

    /// A run `online` put off waits for the next slot unless something starts it again, and a
    /// daily job would wait a day. The network coming back is that something: every deferred
    /// routine is started once, on the next scan. Only on a return, not on a network that was
    /// up all along: a VPN that blocks captive.apple.com defers every run, and starting them
    /// again on each scan would be a run every ten seconds.
    private let path = NWPathMonitor()
    private var online: Bool?
    private var networkBack = false

    func network(_ up: Bool) {
        if up, online == false {
            networkBack = true
            lastScan = .distantPast
        }
        online = up
    }

    /// Routines that are not started again. mirror-check says on a shared Matrix room that
    /// the mirror did not run, and a second run is a second message; the mounts run every
    /// minute and are their own retry. The Epitech scan is a Claude run of up to 95 minutes and
    /// reads Discord again, which its own `run.sh` refuses to retry; it catches up at its next
    /// run of the day. my-setup.sync's failures repeat — the vet refused the diff, or the
    /// allowlist refused every Bash call — and a retry is another 5–7 min headless Claude
    /// session for the same answer.
    static let noRetry: Set<String> = ["s14.mirror-check", "s14.mounts", "epitech.scan", "my-setup.sync"]

    /// When each failing routine was started again, by label. One retry per failure: a run
    /// that fails twice is broken, not unlucky, and a retry loop would hide it. Kept across
    /// launches, or every `install.sh` would re-run every broken routine — the Epitech scan is
    /// a 95-minute Claude run.
    private static let retriesKey = "cronRetries"
    /// When each routine's first run in a row to exit 75 was seen, by label.
    private static let deferredKey = "cronDeferred"

    /// Starts a routine now. A property so `--selftest` can count the kicks instead of sending them.
    var kick: (String) -> Bool = { label in
        let kick = Process()
        kick.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        // No -k: a run that started meanwhile is left alone.
        kick.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
        return (try? kick.run()) != nil
    }

    /// Most failures are the run, not the routine: the network gone at the hour, two runs on
    /// one lock (recon-v3, 28-09 at 09:38), a request that hung. Started again once, a routine
    /// is only named in ALERT when that run failed too.
    func repair(_ jobs: [Launchd.Job], now: Date, files: Set<String> = Launchd.labels()) -> [Launchd.Job] {
        var retried = UserDefaults.standard.dictionary(forKey: Self.retriesKey) as? [String: Double] ?? [:]
        var deferred = UserDefaults.standard.dictionary(forKey: Self.deferredKey) as? [String: Double] ?? [:]
        let back = networkBack
        networkBack = false
        let out = jobs.map { job -> Launchd.Job in
            var job = job
            guard job.triggered else { return job }
            // Not held back by `noRetry`: a deferred run never ran the command, so there is no
            // second message or second Discord read to fear.
            if job.deferred, back, repairs, !job.busy, kick(job.id) {
                NSLog("Fleet: \(job.id) was put off for want of network, started again now it is back")
            }
            if job.deferred {
                let since = deferred[job.id] ?? now.timeIntervalSince1970
                deferred[job.id] = since
                let length = now.timeIntervalSince1970 - since
                if length > max(Launchd.ceiling, 3 * job.allowance) { job.deferredFor = length }
            } else if job.enabled {
                deferred[job.id] = nil
            }
            // A hung run spends the retry, a minute old so ALERT does not wait on it: killed by
            // hand it ends on -15, and a retry would put it straight back on the dead mount it
            // was stuck on.
            if job.hung != nil, retried[job.id] == nil { retried[job.id] = now.timeIntervalSince1970 - 60 }
            guard job.failing else {
                // Only on launchd's word. A job it does not list — booted out for a reinstall,
                // or every job when `launchctl list` itself failed — has not passed, and
                // forgetting its retry would start it a second time once it is back.
                if job.enabled && job.hung == nil { retried[job.id] = nil }
                return job
            }
            if let at = retried[job.id] {
                // Kicked a moment ago and not yet picked up, or still running — but a retry
                // that hangs is not one ALERT can wait for.
                job.repairing = job.hung == nil && (job.busy || now.timeIntervalSince1970 - at < 60)
                return job
            }
            guard repairs, !job.busy, !Self.noRetry.contains(job.id), kick(job.id) else { return job }
            NSLog("Fleet: \(job.id) failed its last run, started again")
            retried[job.id] = now.timeIntervalSince1970
            job.repairing = true
            return job
        }
        // Every plist in the folder, loaded or not, parsed or not: only a routine that is gone —
        // removed, or renamed to a new label — loses its entry. One an install is halfway
        // through writing has no job this scan, and must not lose its retry for it.
        let labels = Set(jobs.map(\.id)).union(files)
        for (key, entries) in [(Self.retriesKey, retried), (Self.deferredKey, deferred)] {
            let kept = entries.filter { labels.contains($0.key) }
            // Only on a change: this runs every ten seconds.
            if kept != UserDefaults.standard.dictionary(forKey: key) as? [String: Double] {
                UserDefaults.standard.set(kept, forKey: key)
            }
        }
        return out
    }

    /// For `--render --hung <label>` and `--deferred <label>`: that routine in the state
    /// nothing on this machine can be made to produce on demand.
    func simulate(_ label: String, hung: Bool) {
        guard let i = jobs.firstIndex(where: { $0.id == label }) else { return }
        if hung {
            jobs[i].hung = 2 * 3600 + 600
            jobs[i].ok = false
        } else {
            jobs[i].deferred = true
        }
    }

    /// Called from `AppController.tick`, on the timer that is already running.
    func tick(now: Date = Date()) {
        guard !scanning, now.timeIntervalSince(lastScan) > 10 else { return }
        scanning = true
        lastScan = now
        Task.detached(priority: .utility) {
            let scanned = Launchd.jobs(probing: true)
            await MainActor.run {
                self.jobs = self.repair(scanned, now: Date()).filter(\.running)
                self.scanning = false
            }
        }
    }
}
