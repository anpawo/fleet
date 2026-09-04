import AppKit
import Darwin

/// Finds live `claude` processes using libproc directly.
///
/// Deliberately avoids shelling out to `ps`/`lsof`: forking a process on every poll is the
/// single most expensive thing a background monitor can do. A full scan here is a couple of
/// syscalls and costs microseconds.
enum ProcessScanner {

    /// `proc_name` (the comm field) is NOT a usable identifier.
    ///
    /// It is wrong in both directions. The native installer execs through a version symlink
    /// (`~/.local/bin/claude` -> `~/.local/share/claude/versions/2.1.226`) and the kernel takes
    /// comm from the resolved target, so a real session reports "2.1.226". Meanwhile the Claude
    /// *desktop* app reports "Claude" and its Electron helpers "Claude Helper", so any prefix
    /// match on "claude" sweeps in eight GUI processes that are not sessions at all.
    ///
    /// The executable path is stable across both install layouts, so identify on that.
    private static func isClaudeCodePath(_ path: String) -> Bool {
        // The desktop app is never a session, whatever its binaries are called.
        if path.contains("/Claude.app/") { return false }

        if path.contains("/.local/share/claude/versions/") { return true }  // native install
        if path.contains("/@anthropic-ai/claude-code/") { return true }     // npm install

        let base = (path as NSString).lastPathComponent
        return base == "claude" || base == "claude.exe"
    }

    /// What a pid was found to be, and when that pid started.
    ///
    /// The answer cannot change under a running process — a path and an argv[0] are fixed at
    /// exec — so it is worth exactly one lookup per process per boot. The start time is the
    /// guard against pid reuse: the kernel hands the same number out again within the hour on
    /// a busy machine, and a recycled pid must not inherit the last tenant's verdict.
    private nonisolated(unsafe) static var claudeVerdicts: [pid_t: (started: UInt64, is: Bool)] = [:]

    /// True when this pid is a Claude Code session.
    ///
    /// Ordered cheapest-first: the TTY check is a single syscall and eliminates every GUI and
    /// daemon process, leaving only shells and CLI tools to pay for a path lookup — and the
    /// cache above means each of those pays it once rather than once a second.
    static func isClaudeSession(_ pid: pid_t) -> Bool {
        guard let bsd = bsdInfo(pid), bsd.e_tdev != UInt32.max else { return false }
        let started = UInt64(bsd.pbi_start_tvsec)
        if let known = claudeVerdicts[pid], known.started == started { return known.is }

        let path = executablePath(pid)
        var verdict = isClaudeCodePath(path)
        if !verdict {
            // Last resort: argv[0] keeps the name "claude" even when the exec path is a version
            // file, covering install layouts we do not know about yet.
            let base = (arguments(pid).first as NSString?)?.lastPathComponent
            verdict = base == "claude" || base == "claude.exe"
        }
        claudeVerdicts[pid] = (started, verdict)
        // Bounded by the process table: a machine that has churned through thousands of shells
        // would otherwise keep a row for every one of them.
        if claudeVerdicts.count > 2048 {
            let live = Set(allPIDs())
            claudeVerdicts = claudeVerdicts.filter { live.contains($0.key) }
        }
        return verdict
    }

    /// One `proc_pidinfo`, shared by everything that needs the tty, the parent or the start
    /// time — which is most of a scan.
    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var bsd = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd,
                                Int32(MemoryLayout<proc_bsdinfo>.size))
        return size > 0 ? bsd : nil
    }

    /// A Claude Code session is always attached to a terminal. Electron helpers never are,
    /// so this is the discriminator that survives whatever the binary is called next. It also
    /// excludes headless background workers, which have no tab for a tile to raise.
    private static func controllingTTY(_ pid: pid_t) -> String? {
        var bsd = proc_bsdinfo()
        let sz = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd,
                             Int32(MemoryLayout<proc_bsdinfo>.size))
        guard sz > 0, bsd.e_tdev != UInt32.max,
              let d = devname(dev_t(bsd.e_tdev), S_IFCHR) else { return nil }
        return "/dev/" + String(cString: d)
    }

    static func executablePath(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(cString: buf)
    }

    /// Cheap existence check used by the dormant poll — bails at the first hit without
    /// gathering cwd or CPU for anything.
    static func anyClaudeRunning() -> Bool {
        for pid in allPIDs() where pid > 0 {
            if isClaudeSession(pid) { return true }
        }
        return false
    }

    static func scan() -> [ClaudeProcess] {
        var out: [ClaudeProcess] = []
        for pid in allPIDs() where pid > 0 {
            guard isClaudeSession(pid) else { continue }

            var bsd = proc_bsdinfo()
            let sz = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd,
                                 Int32(MemoryLayout<proc_bsdinfo>.size))
            guard sz > 0 else { continue }

            guard let cwd = workingDirectory(pid) else { continue }

            // Required, not decorative: no terminal means this is not a session we can show
            // or raise. See `controllingTTY`.
            guard bsd.e_tdev != UInt32.max,
                  let d = devname(dev_t(bsd.e_tdev), S_IFCHR) else { continue }
            let tty = "/dev/" + String(cString: d)

            out.append(ClaudeProcess(
                pid: pid,
                ppid: pid_t(bsd.pbi_ppid),
                cwd: cwd,
                tty: tty,
                startedAt: Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)),
                cpuNanos: cpuNanos(pid)
            ))
        }
        return out
    }


    /// Resident size and cumulative CPU for any pid, in one syscall. Used by `Reaper`, which
    /// needs both for every process on the machine and cannot afford a call each.
    static func taskInfo(_ pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info,
                                Int32(MemoryLayout<proc_taskinfo>.size))
        return size > 0 ? info : nil
    }

    /// This pid's parent, or 0 when it cannot be read. Single process, unlike `parentMap`.
    static func parent(_ pid: pid_t) -> pid_t {
        var bsd = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd,
                               Int32(MemoryLayout<proc_bsdinfo>.size))
        return size > 0 ? pid_t(bsd.pbi_ppid) : 0
    }

    /// A name to show a human. Prefers the bundle name of a GUI app — "Firefox" reads better
    /// than "plugin-container" — and falls back to the executable's own name.
    static func displayName(_ pid: pid_t) -> String {
        if let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName {
            return name
        }
        let path = executablePath(pid)
        let base = (path as NSString).lastPathComponent
        // A session's executable is a version file — "2.1.241" — because of the symlink layout
        // described above, which names nothing a human recognises. The project it is working in
        // does.
        if isClaudeSession(pid), let cwd = workingDirectory(pid) {
            return "claude · " + ((cwd as NSString).lastPathComponent)
        }
        return base.isEmpty ? "pid \(pid)" : base
    }

    // MARK: - libproc wrappers

    static func allPIDs() -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, byteCount)
        guard written > 0 else { return [] }
        return Array(pids.prefix(Int(written) / MemoryLayout<pid_t>.size))
    }

    private static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info,
                                Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard size > 0 else { return nil }
        let path = withUnsafePointer(to: info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        return path.isEmpty ? nil : path
    }

    /// Cumulative CPU time in nanoseconds. Differencing two samples gives us CPU% without
    /// ever spawning `ps`.
    private static func cpuNanos(_ pid: pid_t) -> UInt64 {
        var info = rusage_info_v4()
        var result: UInt64 = 0
        withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rp in
                if proc_pid_rusage(pid, RUSAGE_INFO_V4, rp) == 0 {
                    result = p.pointee.ri_user_time &+ p.pointee.ri_system_time
                }
            }
        }
        return result
    }

    /// Full argv via `sysctl(KERN_PROCARGS2)`. Used to read `--resume <sessionId>`, which
    /// binds a resumed session to its transcript exactly.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        var buf = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return []
        }

        // Layout: [argc: Int32][exec path\0][padding \0s][argv[0]\0][argv[1]\0]...
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { dst in
            buf.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(4)))
            }
        }
        guard argc > 0 else { return [] }

        var args: [String] = []
        var index = MemoryLayout<Int32>.size

        // Skip the exec path, then any NUL padding before argv[0].
        while index < size, buf[index] != 0 { index += 1 }
        while index < size, buf[index] == 0 { index += 1 }

        var current = [CChar]()
        while index < size, args.count < Int(argc) {
            let c = buf[index]
            if c == 0 {
                current.append(0)
                args.append(String(cString: current))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(c)
            }
            index += 1
        }
        return args
    }

    /// pid -> ppid for every process on the machine.
    ///
    /// `proc_pidinfo` cannot be used to walk a terminal session's ancestry. The chain runs
    /// `claude -> shell -> login -> Terminal`, and `login` is setuid root, so reading it that
    /// way returns nothing for an unprivileged caller — the walk died one step short of the
    /// terminal every single time, which is why clicking a tile did nothing. sysctl reports
    /// the whole process table regardless of owner.
    private static func parentMap() -> [pid_t: pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }

        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [:] }

        var map: [pid_t: pid_t] = [:]
        // The table can shrink between sizing and reading, so trust the returned size.
        for proc in procs.prefix(size / stride) {
            map[proc.kp_proc.p_pid] = proc.kp_eproc.e_ppid
        }
        return map
    }

    /// Walks up the parent chain looking for a process that owns a GUI app — the terminal
    /// emulator hosting this session (Terminal.app, iTerm2, Ghostty, …).
    ///
    /// Only ever called on a click, so reading the full process table here is free; it is not
    /// on any polling path.
    static func hostApplication(of pid: pid_t) -> NSRunningApplicationBox? {
        let parents = parentMap()
        var current = pid
        for _ in 0..<12 {
            guard let parent = parents[current], parent > 1 else { return nil }
            if let app = NSRunningApplicationBox.app(forPID: parent) { return app }
            current = parent
        }
        return nil
    }
}
