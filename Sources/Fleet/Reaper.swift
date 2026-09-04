import AppKit
import Darwin

/// System-wide memory pressure, as the kernel itself judges it.
///
/// Free RAM is not the signal — macOS keeps it near zero on purpose, and a machine with 50 MB
/// free can be perfectly healthy. What hurts is the compressor and the swap file: once pages
/// are being written to the SSD and read straight back, every process on the machine pays disk
/// latency for memory access. The kernel already computes that judgement for its own use and
/// publishes it, so read its answer rather than inventing a worse one out of RSS totals.
enum MemoryPressure {

    /// The values `kern.memorystatus_vm_pressure_level` reports. They are a bitfield, hence
    /// the gap: 1, 2, 4.
    enum Level: Int32 {
        case normal = 1
        case warning = 2
        case critical = 4

        var isTight: Bool { self != .normal }
    }

    static func level() -> Level {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0
        else { return .normal }
        return Level(rawValue: value) ?? .normal
    }

    /// Bytes of swap in use, and the size of the swap file backing it.
    static func swap() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    /// What the RAM is doing right now, split the way Activity Monitor splits it — which is the
    /// only split worth showing, since it is the one whose numbers you can go and check.
    struct Footprint {
        /// App memory, wired and compressed together: the part that is genuinely spoken for.
        var used: UInt64 = 0
        /// File-backed pages the kernel is keeping around and will drop the moment anything
        /// needs the space. Counted as "used" by every naive reading of free RAM, and the
        /// reason a healthy Mac always looks full.
        var cached: UInt64 = 0
        var compressed: UInt64 = 0
        var swap: UInt64 = 0
        /// The swap file macOS has actually made, which is the only ceiling of the four that
        /// exists: cached and compressed are both parts of the RAM total, with no cap of their
        /// own, while swap is a file that is grown on demand — and is absent until it is
        /// needed, hence the zero on a machine that has never had to swap.
        var swapTotal: UInt64 = 0
        var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    }

    static func footprint() -> Footprint {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let paged = swap()
        var out = Footprint(swap: paged.used, swapTotal: paged.total)
        guard ok == KERN_SUCCESS else { return out }

        let page = UInt64(vm_kernel_page_size)
        // `internal` is anonymous memory — an app's own pages. Purgeable is the part of it the
        // app has already said it can lose, so it belongs with the cache, not with the total.
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        out.compressed = UInt64(stats.compressor_page_count) * page
        out.used = (app + UInt64(stats.wire_count)) * page + out.compressed
        out.cached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page
        return out
    }
}

/// Bytes, rounded to whatever unit reads as a size rather than a number.
func byteLabel(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_048_576
    return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : "\(Int(mb)) MB"
}

/// A process big enough to be worth naming when memory is tight.
struct Hog: Identifiable {
    var id: pid_t { pid }
    var pid: pid_t
    var name: String
    var rss: UInt64
    /// Set when this one is on the reap list — the panel says so rather than offering a ✕ for
    /// something that is about to go on its own.
    var reapable: Bool = false

    var sizeLabel: String { byteLabel(rss) }
}

/// Frees memory before the machine grinds, by killing daemons that nothing is using.
///
/// The premise: by the time a Mac feels slow it has been swapping for days, and what is holding
/// the memory is usually not what you are working in — a Gradle daemon left over from a build
/// that finished this morning, an emulator nobody has looked at since Tuesday, Docker's VM
/// running no containers. macOS does eventually intervene on its own, but its rule is roughly
/// "biggest first", which is as likely to take the build you are waiting on as the daemon you
/// forgot about.
///
/// So the rule here is deliberately *not* "biggest". It is: **nothing is using this, and it
/// comes back by itself.** Both halves are required, and each candidate has a test for the
/// first half that looks at what the process is actually doing rather than at how fat it is.
/// Anything that fails either half is never touched — it is only named, in the panel, for you
/// to decide about.
@MainActor
final class Reaper: ObservableObject {

    /// What the panel draws: the pressure right now, and who is holding the memory.
    @Published private(set) var pressure: MemoryPressure.Level = .normal
    @Published private(set) var hogs: [Hog] = []
    /// Drawn whenever the panel is open and nothing is wrong — the quiet half of the strip.
    /// Read once here as well as on every tick, so the first panel of a session shows the
    /// machine rather than a row of zeroes.
    @Published private(set) var footprint = MemoryPressure.footprint()

    /// Called with a one-line summary after something was actually killed.
    var onReaped: ((String) -> Void)?

    /// Per-candidate CPU history, which is how "nothing is using this" is measured: a daemon
    /// doing work burns CPU, an abandoned one does not. Keyed by pid and pruned as pids go.
    private var lastCPU: [pid_t: (nanos: UInt64, at: Date)] = [:]
    /// Since when each candidate has been continuously below the idle floor. Continuity is the
    /// point — a single quiet sample is meaningless, two unbroken minutes are not.
    private var idleSince: [pid_t: Date] = [:]
    /// One reap at a time: the structural tests shell out, so a second tick can arrive while
    /// the first is still deciding.
    private var reaping = false
    /// Do not re-kill something that is taking its time shutting down.
    private var recentlyKilled: [pid_t: Date] = [:]

    /// Called from `AppController.tick`. Deliberately reuses the timer that is already running
    /// rather than adding a source of its own — the pressure read is one `sysctl`, and a
    /// problem that took two weeks to build up does not need sub-second reflexes.
    func tick() {
        pressure = MemoryPressure.level()
        footprint = MemoryPressure.footprint()

        let candidates = Reaper.candidates()
        sampleIdleness(candidates)

        // Everything below only matters when memory is actually tight; when it is not, the
        // samples above are all we keep doing, so that the idle streaks are already there when
        // pressure arrives instead of starting from zero at the worst moment.
        guard pressure.isTight else {
            if !hogs.isEmpty { hogs = [] }
            return
        }

        let ripe = candidates.filter { isIdle($0.pid) }
        hogs = Reaper.topHogs(reapable: Set(ripe.map(\.pid)))
        reap(ripe)
    }

    // MARK: - Idleness

    private func sampleIdleness(_ candidates: [Reapable]) {
        let now = Date()
        let live = Set(candidates.map(\.pid))
        lastCPU = lastCPU.filter { live.contains($0.key) }
        idleSince = idleSince.filter { live.contains($0.key) }
        recentlyKilled = recentlyKilled.filter { now.timeIntervalSince($0.value) < 60 }

        for candidate in candidates {
            guard let previous = lastCPU[candidate.pid] else {
                // First sight of this pid. No delta yet, so no verdict yet — and no idle
                // streak either, which is what stops a freshly launched Fleet from killing
                // anything before it has watched it for a while.
                lastCPU[candidate.pid] = (candidate.cpuNanos, now)
                continue
            }
            let seconds = now.timeIntervalSince(previous.at)
            guard seconds >= 1 else { continue }
            let percent = Double(candidate.cpuNanos &- previous.nanos) / 1e9 / seconds * 100
            lastCPU[candidate.pid] = (candidate.cpuNanos, now)

            if percent > Config.reapIdleCPUPercent {
                idleSince[candidate.pid] = nil          // busy: the streak breaks
            } else if idleSince[candidate.pid] == nil {
                idleSince[candidate.pid] = now
            }
        }
    }

    /// Whether this candidate has been below the CPU floor without a break for `window`.
    ///
    /// The window is a parameter because `--reap` sets it to zero: there, a person is asking
    /// for the clean-up now, so the streak only has to exist — it does not have to be old. The
    /// long window is what makes the *automatic* path safe, and nothing about it protects a
    /// decision somebody made deliberately.
    func isIdle(_ pid: pid_t, window: TimeInterval = Config.reapIdleWindow) -> Bool {
        guard recentlyKilled[pid] == nil, let since = idleSince[pid] else { return false }
        return Date().timeIntervalSince(since) >= window
    }

    // MARK: - Reaping

    private func reap(_ candidates: [Reapable]) {
        guard !reaping, !candidates.isEmpty else { return }
        reaping = true

        Task.detached {
            // The second gate, and the expensive one: ask each candidate's own subsystem
            // whether it is in use. Off the main actor because some of these fork.
            let cleared = candidates.filter { Reaper.isUnused($0) }
            await MainActor.run { [weak self] in
                self?.finishReap(cleared)
            }
        }
    }

    private func finishReap(_ cleared: [Reapable]) {
        reaping = false
        guard !cleared.isEmpty else { return }

        var killed: [String] = []
        var freed: UInt64 = 0
        for candidate in cleared {
            guard candidate.terminate() else { continue }
            recentlyKilled[candidate.pid] = Date()
            idleSince[candidate.pid] = nil
            killed.append("\(candidate.name) (\(byteLabel(candidate.rss)))")
            freed += candidate.rss
            NSLog("Fleet: reaped \(candidate.name) pid \(candidate.pid) — \(candidate.reason)")
        }
        guard !killed.isEmpty else { return }

        onReaped?("Freed \(byteLabel(freed)): " + killed.joined(separator: ", "))
    }

    // MARK: - Candidates

    /// One pass over the process table, classifying the four things Fleet is willing to kill.
    ///
    /// Cheap enough to run on every tick: `proc_listpids` plus a `proc_pidinfo` per pid is a
    /// couple of hundred microseconds, and nothing here forks. See `ProcessScanner` for why
    /// shelling out to `ps` on a polling path is not an option.
    static func candidates() -> [Reapable] {
        var out: [Reapable] = []
        for pid in ProcessScanner.allPIDs() where pid > 0 {
            guard let kind = classify(pid) else { continue }
            guard let task = ProcessScanner.taskInfo(pid) else { continue }
            out.append(Reapable(
                pid: pid,
                kind: kind,
                rss: task.pti_resident_size + (kind == .dockerDesktop ? virtualMachineRSS() : 0),
                cpuNanos: task.pti_total_user &+ task.pti_total_system
            ))
        }
        return out
    }

    /// Docker's own helper is a rounding error; the memory is in the Virtualization.framework
    /// host process running the Linux VM, which is a system XPC service reparented to launchd
    /// with nothing in its path or arguments tying it back to Docker.
    ///
    /// So it is attributed by type, which is only right while Docker is the one VM on the
    /// machine. With Parallels or UTM also running, the figure reported for Docker would be too
    /// big. It stays a *reported* figure and never a decision — what gets killed is Docker.app,
    /// chosen by bundle id — so the worst case is a banner that overstates what it freed.
    private static func virtualMachineRSS() -> UInt64 {
        var total: UInt64 = 0
        for pid in ProcessScanner.allPIDs() where pid > 0 {
            let path = ProcessScanner.executablePath(pid)
            guard path.hasSuffix("com.apple.Virtualization.VirtualMachine"),
                  let task = ProcessScanner.taskInfo(pid) else { continue }
            total += task.pti_resident_size
        }
        return total
    }

    /// What each pid turned out to be, against the moment it started.
    ///
    /// Same reasoning as `ProcessScanner.isClaudeSession`: an executable path and a command
    /// line are fixed at exec, and looking them up for every process on the machine once a
    /// second was the single most expensive thing Fleet did — 80 ms of `proc_pidpath` on the
    /// main thread, which is ten dropped frames of whatever you were scrolling.
    ///
    /// The one thing re-checked on a hit is a session that was *not* an orphan: it becomes one
    /// when its shell dies, without the process itself changing. The reverse never happens —
    /// nothing gets its parent back — so an orphan verdict, once taken, holds.
    private nonisolated(unsafe) static var kinds: [pid_t: (started: UInt64, kind: Reapable.Kind?)] = [:]

    private static func classify(_ pid: pid_t) -> Reapable.Kind? {
        guard let bsd = ProcessScanner.bsdInfo(pid) else { return nil }
        let started = UInt64(bsd.pbi_start_tvsec)
        if let known = kinds[pid], known.started == started {
            // A live session that has since lost its shell still has to be caught, so the one
            // verdict that depends on something other than the process itself is re-taken.
            guard known.kind == nil, ProcessScanner.isClaudeSession(pid) else { return known.kind }
            return bsd.pbi_ppid == 1 ? .orphanSession : nil
        }
        let kind = classifyUncached(pid, ppid: pid_t(bsd.pbi_ppid))
        kinds[pid] = (started, kind)
        if kinds.count > 2048 {
            let live = Set(ProcessScanner.allPIDs())
            kinds = kinds.filter { live.contains($0.key) }
        }
        return kind
    }

    private static func classifyUncached(_ pid: pid_t, ppid: pid_t) -> Reapable.Kind? {
        let path = ProcessScanner.executablePath(pid)
        guard !path.isEmpty else { return nil }

        // Docker Desktop's Linux VM. Identified by the helper that boots it rather than by the
        // shared Virtualization.framework host process, which any VM app would also be using.
        if path.contains("/Docker.app/") && path.hasSuffix("com.docker.virtualization") {
            return .dockerDesktop
        }

        // The Android emulator runs as a qemu binary out of the SDK, so the SDK path is what
        // separates it from any other qemu on the machine.
        if path.contains("/emulator/qemu/")
            && (path as NSString).lastPathComponent.hasPrefix("qemu-system-") {
            return .androidEmulator
        }

        if (path as NSString).lastPathComponent == "java" {
            // Every JVM on the machine looks alike from the outside; the main class is the only
            // thing that says which one this is.
            let argv = ProcessScanner.arguments(pid)
            if argv.contains("org.gradle.launcher.daemon.bootstrap.GradleDaemon") {
                return .gradleDaemon
            }
            return nil
        }

        // A Claude Code session whose shell died — a terminal window closed on it, a crash —
        // gets reparented to launchd. A live session always has its shell in between, so this
        // is a session that is talking to nobody and can never be answered.
        if ProcessScanner.isClaudeSession(pid), ppid == 1 {
            return .orphanSession
        }
        return nil
    }

    /// The second gate: is anything actually using this? Runs off the main actor; may fork.
    ///
    /// Never optimistic. Anything this cannot establish for certain reads as "in use", so an
    /// unavailable `docker` or an unreadable log leaves the process alone.
    nonisolated static func isUnused(_ candidate: Reapable) -> Bool {
        switch candidate.kind {
        case .gradleDaemon:
            // The daemon records every build it runs as a command execution, started and then
            // completed. A build that is merely waiting on the network sits between the two
            // burning no CPU at all — which is exactly the case the idle streak alone would
            // misread as abandoned — so the open execution is what protects it.
            //
            // The log's mtime cannot stand in for this: an idle daemon writes a periodic health
            // check to the same file every few seconds, so mtime is always fresh and always
            // meaningless.
            guard let log = gradleDaemonLog(pid: candidate.pid),
                  let tail = tail(of: log, bytes: Config.reapLogTailBytes) else { return false }
            guard let last = tail.range(of: "Command execution: ", options: .backwards) else {
                return true             // a daemon that has never run a build
            }
            return tail[last.upperBound...].hasPrefix("completed")

        case .dockerDesktop:
            // Containers run inside the VM and are invisible from the host, so the only
            // honest answer comes from Docker itself.
            guard let docker = dockerBinary(),
                  let listing = shell(docker, ["ps", "-q"]) else { return false }
            return listing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        case .androidEmulator:
            // An emulator with a debugger, a running app or an install in flight is burning
            // CPU, so the idle streak already covers it. Nothing cheaper to add here.
            return true

        case .orphanSession:
            // Being orphaned is the whole test, and it was established in `classify`.
            return true
        }
    }

    /// Where the `docker` client actually is.
    ///
    /// Not `/usr/bin/env`: Fleet is started by launchd, whose PATH is the bare
    /// `/usr/bin:/bin:/usr/sbin:/sbin` — the Homebrew and `/usr/local` directories a shell
    /// would have are simply not there, so `env` would never find it and the gate would fail
    /// closed forever. Failing closed is safe, but it is also silently useless.
    private nonisolated static func dockerBinary() -> String? {
        [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The log Gradle keeps per daemon, under `~/.gradle/daemon/<version>/daemon-<pid>.out.log`.
    private nonisolated static func gradleDaemonLog(pid: pid_t) -> String? {
        let root = (NSHomeDirectory() as NSString).appendingPathComponent(".gradle/daemon")
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return nil
        }
        for version in versions {
            let path = "\(root)/\(version)/daemon-\(pid).out.log"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// The last chunk of a file. Gradle daemon logs run to megabytes and only the end of one
    /// says anything about what it is doing now.
    private nonisolated static func tail(of path: String, bytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A short command, with a deadline. Nil when it failed or took too long — callers read
    /// that as "could not establish", never as "unused".
    private nonisolated static func shell(_ launch: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launch)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }

        // `docker` talks to a daemon that may itself be wedged, and a background app must not
        // hang on it. Deadline, then kill the client.
        let deadline = Date().addingTimeInterval(Config.reapCommandTimeout)
        while task.isRunning && Date() < deadline { usleep(50_000) }
        guard !task.isRunning else {
            task.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return task.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    // MARK: - Panel

    /// The biggest processes on the machine, for the panel to name. Purely informational —
    /// nothing here is killed automatically; size alone is never a reason.
    static func topHogs(reapable: Set<pid_t>) -> [Hog] {
        var found: [Hog] = []
        let mine = getpid()
        for pid in ProcessScanner.allPIDs() where pid > 0 && pid != mine {
            guard let task = ProcessScanner.taskInfo(pid),
                  task.pti_resident_size > Config.hogFloorBytes else { continue }
            found.append(Hog(pid: pid,
                             name: ProcessScanner.displayName(pid),
                             rss: task.pti_resident_size,
                             reapable: reapable.contains(pid)))
        }
        return Array(found.sorted { $0.rss > $1.rss }.prefix(Config.hogCount))
    }

    /// The panel's ✕. Asks a GUI app to quit so it can save what it has; anything else gets a
    /// polite signal. Never `SIGKILL` — that is the one macOS uses, and losing work is the
    /// thing this whole feature exists to avoid.
    static func dismiss(pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.terminate()
        } else {
            kill(pid, SIGTERM)
        }
    }
}

/// A process Fleet is willing to kill, once both gates agree.
struct Reapable {
    enum Kind {
        case gradleDaemon
        case androidEmulator
        case dockerDesktop
        case orphanSession
    }

    var pid: pid_t
    var kind: Kind
    var rss: UInt64
    var cpuNanos: UInt64

    var name: String {
        switch kind {
        case .gradleDaemon: return "Gradle daemon"
        case .androidEmulator: return "Android emulator"
        case .dockerDesktop: return "Docker"
        case .orphanSession: return "orphaned Claude session"
        }
    }

    var reason: String {
        switch kind {
        case .gradleDaemon: return "no build running; restarts on the next one"
        case .androidEmulator: return "idle; the AVD keeps its state"
        case .dockerDesktop: return "no containers running"
        case .orphanSession: return "its terminal is gone"
        }
    }

    /// Returns whether the request went out.
    @MainActor func terminate() -> Bool {
        switch kind {
        case .dockerDesktop:
            // Killing the VM process behind Docker Desktop's back leaves the app sitting there
            // believing it still has one. Quitting the app takes the whole stack down cleanly.
            guard let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.docker.docker").first else {
                return false
            }
            return app.terminate()
        default:
            return kill(pid, SIGTERM) == 0
        }
    }
}
