import Foundation
import Darwin

/// Enumerating processes via sysctl instead of forking `ps`. The Codex watcher runs on a
/// timer, so a fork every couple of seconds would show up in Activity Monitor; this doesn't.
func listProcesses() -> [(pid: Int32, comm: String)] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
    let count = size / MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
    guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

    let actual = size / MemoryLayout<kinfo_proc>.stride
    var out: [(Int32, String)] = []
    for i in 0..<min(actual, procs.count) {
        var p = procs[i]
        let pid = p.kp_proc.p_pid
        guard pid > 0 else { continue }
        let comm = withUnsafePointer(to: &p.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        out.append((pid, comm))
    }
    return out
}

/// Working directory of a process without shelling out to `lsof`.
func processCWD(_ pid: Int32) -> String? {
    var info = proc_vnodepathinfo()
    let size = MemoryLayout<proc_vnodepathinfo>.size
    let result = withUnsafeMutablePointer(to: &info) {
        proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, UnsafeMutableRawPointer($0), Int32(size))
    }
    guard result == Int32(size) else { return nil }
    return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
}

/// Parent pid, used to walk from a background session up to the tty that owns it.
func parentPID(_ pid: Int32) -> Int32? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let ppid = info.kp_eproc.e_ppid
    return ppid > 0 ? ppid : nil
}

/// Controlling terminal of a process as a `/dev/ttysNNN` path, or nil if it has none
/// (background sessions run on a pty owned by the daemon, not a Terminal tab).
func processTTY(_ pid: Int32) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let dev = info.kp_eproc.e_tdev
    guard dev != -1, dev != 0 else { return nil }
    guard let name = devname(dev, S_IFCHR) else { return nil }
    return "/dev/" + String(cString: name)
}
