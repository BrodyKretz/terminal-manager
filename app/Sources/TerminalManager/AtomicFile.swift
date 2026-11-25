import Darwin
import Foundation

/// A whole file replaced at once: written beside it, then renamed over it, so a reader (or a helper being
/// run) only ever sees the old file or the new one.
enum AtomicFile {
    static func write(_ data: Data, to path: String, mode: mode_t = 0o600) throws {
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let temporary = "\(folder)/.\(name).tm-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw posixError() }
        var isWritten = true
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count, let base = raw.baseAddress {
                let count = Darwin.write(fd, base + offset, raw.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    isWritten = false
                    return
                }
            }
        }
        // The umask may have cleared bits of `mode`.
        let isComplete = isWritten && fchmod(fd, mode) == 0 && fsync(fd) == 0
        let error = posixError()
        close(fd)
        guard isComplete, rename(temporary, path) == 0 else {
            let renameError = posixError()
            unlink(temporary)
            throw isComplete ? renameError : error
        }
    }

    /// A folder the app owns: created 0700 when missing. A symlink or a file in its place is refused.
    static func makeFolder(_ url: URL, enforcingMode: Bool = false) throws {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            guard status.st_mode & S_IFMT == S_IFDIR else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
            }
            if enforcingMode, status.st_mode & 0o777 != 0o700 { chmod(url.path, 0o700) }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
