import Darwin
import Foundation

/// Asks the kernel for a process's real working directory via libproc.
///
/// The shell's OSC 7 reports depend on the user's shell configuration; the
/// kernel's answer does not. Used to skip the follow-`cd` when the shell is
/// already where the browser is going.
enum ProcessWorkingDirectory {
    static func path(for pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
