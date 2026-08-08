import Foundation
import Darwin

/// Finds live `claude` processes using libproc directly.
///
/// Deliberately avoids shelling out to `ps`/`lsof`: forking a process on every poll is the
/// single most expensive thing a background monitor can do. A full scan here is a couple of
/// syscalls and costs microseconds.
enum ProcessScanner {

    /// Claude Code ships as a self-extracting binary whose `proc_pidpath` lookup fails, so
    /// `proc_name` (the comm field) is the reliable identifier. Older npm installs report
    /// "claude"; the current native build reports "claude.exe".
    private static func isClaudeProcess(_ name: String) -> Bool {
        let n = name.lowercased()
        guard n.hasPrefix("claude") else { return false }
        return !n.hasPrefix("claudefleet")   // never match ourselves
    }

    /// Cheap existence check used by the dormant poll — bails at the first hit without
    /// gathering cwd, tty or CPU for anything.
    static func anyClaudeRunning() -> Bool {
        for pid in allPIDs() where pid > 0 {
            if isClaudeProcess(procName(pid)) { return true }
        }
        return false
    }

    static func scan() -> [ClaudeProcess] {
        var out: [ClaudeProcess] = []
        for pid in allPIDs() where pid > 0 {
            guard isClaudeProcess(procName(pid)) else { continue }

            var bsd = proc_bsdinfo()
            let sz = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd,
                                 Int32(MemoryLayout<proc_bsdinfo>.size))
            guard sz > 0 else { continue }

            guard let cwd = workingDirectory(pid) else { continue }

            var tty: String?
            if bsd.e_tdev != UInt32.max, let d = devname(dev_t(bsd.e_tdev), S_IFCHR) {
                tty = "/dev/" + String(cString: d)
            }

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

    // MARK: - libproc wrappers

    private static func allPIDs() -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, byteCount)
        guard written > 0 else { return [] }
        return Array(pids.prefix(Int(written) / MemoryLayout<pid_t>.size))
    }

    private static func procName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, 256) > 0 else { return "" }
        return String(cString: buf)
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

    /// Walks up the parent chain looking for a process that owns a GUI app — the terminal
    /// emulator hosting this session (Terminal.app, iTerm2, Ghostty, …).
    static func hostApplication(of pid: pid_t) -> NSRunningApplicationBox? {
        var current = pid
        for _ in 0..<8 {
            var bsd = proc_bsdinfo()
            let sz = proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &bsd,
                                  Int32(MemoryLayout<proc_bsdinfo>.size))
            guard sz > 0 else { return nil }
            let parent = pid_t(bsd.pbi_ppid)
            if parent <= 1 { return nil }
            if let app = NSRunningApplicationBox.app(forPID: parent) { return app }
            current = parent
        }
        return nil
    }
}
