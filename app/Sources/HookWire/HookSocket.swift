import Darwin
import Foundation

/// The few socket calls both ends need: a Unix-domain address, a connect that gives up quickly, reads
/// and writes bounded by a deadline (seconds of system uptime), and what the kernel says about the
/// process on the other end. Every failure is a nil or false, never a signal: callers ignore SIGPIPE or
/// set SO_NOSIGPIPE, which `connect` does.
public enum HookSocket {
    /// sun_path holds 104 bytes on macOS, the terminating zero included.
    public static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    public static func uptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    public static func address(for path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maxPathBytes else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return address
    }

    public static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    /// Close-on-exec and no SIGPIPE: a peer that went away makes a write fail with EPIPE instead.
    public static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// A non-blocking stream socket connected to `path`, or nil when nothing listens there (or not
    /// within the deadline).
    public static func connect(to path: String, until deadline: TimeInterval) -> Int32? {
        guard var address = address(for: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        configure(fd)
        setNonBlocking(fd)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EINTR, wait(fd, for: Int16(POLLOUT), until: deadline) else {
                close(fd)
                return nil
            }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                close(fd)
                return nil
            }
        }
        return fd
    }

    /// Whether `fd` became ready for `events` before the deadline. A hang-up or an error counts as
    /// ready: the read or write that follows finds out.
    public static func wait(_ fd: Int32, for events: Int16, until deadline: TimeInterval) -> Bool {
        while true {
            let remaining = deadline - uptime()
            guard remaining > 0 else { return false }
            var poller = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(min((remaining * 1000).rounded(.up), Double(Int32.max)))
            let result = poll(&poller, 1, milliseconds)
            if result > 0 { return true }
            if result == 0 { return false }
            if errno != EINTR { return false }
        }
    }

    /// Writes all of `data` to a blocking or non-blocking descriptor, or gives up at the deadline.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data, until deadline: TimeInterval) -> Bool {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base + offset, data.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EAGAIN || errno == EINTR {
                guard wait(fd, for: Int16(POLLOUT), until: deadline) else { return false }
                continue
            }
            return false
        }
        return true
    }

    /// Reads and drops whatever comes until the peer closes, or until the deadline; true when it closed.
    @discardableResult
    public static func waitForClose(_ fd: Int32, until deadline: TimeInterval) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return true }
            if count > 0 { continue }
            guard errno == EAGAIN || errno == EINTR else { return true }
            guard wait(fd, for: Int16(POLLIN), until: deadline) else { return false }
        }
    }

    // MARK: who is on the other end

    /// The process on the other end of a connected Unix socket, as the kernel says (LOCAL_PEERPID); nil
    /// once the peer has closed, so a server must ask while the client is still connected.
    public static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    /// The user the other end runs as, from the credentials the kernel kept at connect (LOCAL_PEERCRED).
    public static func peerUID(_ fd: Int32) -> uid_t? {
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length) == 0,
              credentials.cr_version == XUCRED_VERSION else { return nil }
        return credentials.cr_uid
    }

    /// The executable a process runs (proc_pidpath; the kernel answers for processes of this user).
    public static func executablePath(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// A process's parent, from sysctl; nil when there is no such process.
    public static func parentPID(of pid: pid_t) -> pid_t? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == pid else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Reads up to the first newline (not included). nil when the peer closes first, the line grows
    /// past `limit`, or the deadline passes.
    public static func readLine(_ fd: Int32, until deadline: TimeInterval, limit: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let start = data.count
                data.append(buffer, count: count)
                if let newline = data[start...].firstIndex(of: 0x0A) {
                    return Data(data[..<newline])
                }
                guard data.count <= limit else { return nil }
            } else if count == 0 {
                return nil
            } else if errno == EAGAIN || errno == EINTR {
                guard wait(fd, for: Int16(POLLIN), until: deadline) else { return nil }
            } else {
                return nil
            }
        }
    }
}
