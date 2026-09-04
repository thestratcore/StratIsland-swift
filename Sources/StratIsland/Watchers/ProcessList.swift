import Foundation
import Darwin

/// Enumerating processes via sysctl instead of forking `ps`. The Codex watcher runs on a
/// timer, so a fork every couple of seconds would show up in Activity Monitor; this doesn't.
enum ProcessListError: Error {
    case querySize(Int32)
    case read(Int32)
}

func listProcesses() -> Result<[(pid: Int32, comm: String)], ProcessListError> {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else {
        return .failure(.querySize(errno))
    }
    let count = size / MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
    guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else {
        return .failure(.read(errno))
    }

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
    return .success(out)
}

/// Kernel-recorded process start time, used to bind a Codex process to the rollout created
/// for that invocation instead of whichever rollout in the same directory changed last.
func processStartDate(_ pid: Int32) -> Date? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    let result = withUnsafeMutablePointer(to: &info) {
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, UnsafeMutableRawPointer($0), Int32(size))
    }
    guard result == Int32(size) else { return nil }
    let seconds = TimeInterval(info.pbi_start_tvsec)
    let microseconds = TimeInterval(info.pbi_start_tvusec) / 1_000_000
    return Date(timeIntervalSince1970: seconds + microseconds)
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
