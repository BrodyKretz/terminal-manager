import Darwin
import Foundation
import PtySpawn

/// One `tmux attach` client on its own pseudo-terminal: the page's xterm.js sees its output and types
/// into it. Output is read off the main thread and handed over coalesced, at most once a frame.
final class PtyClient: @unchecked Sendable {
    static let flushInterval: TimeInterval = 1.0 / 60
    static let maxChunk = 256 << 10

    let id: Int
    let sessionID: String
    let pid: pid_t
    private let fd: Int32
    private let queue = DispatchQueue(label: "terminal-manager.pty", qos: .userInteractive)
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private let lock = NSLock()
    private var pending = Data()
    private var isFlushScheduled = false
    private var isClosed = false
    /// Main thread: coalesced output, then once the client is gone.
    var onOutput: ((Data) -> Void)?
    var onExit: (() -> Void)?

    init?(id: Int, sessionID: String, arguments: [String], environment: [String: String], cols: Int, rows: Int) {
        guard let path = arguments.first else { return nil }
        self.id = id
        self.sessionID = sessionID
        var master: Int32 = -1
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        let child = tm_spawn_pty(path, argv, envp, UInt16(clamping: rows), UInt16(clamping: cols), &master)
        guard child > 0 else {
            Log.error("pty: could not start \(path): \(String(cString: strerror(errno)))")
            return nil
        }
        pid = child
        fd = master
        startReading()
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        readSource = source
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(self.pid, &status, WNOHANG)
            self.finish()
        }
        exit.resume()
        exitSource = exit
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                lock.lock()
                pending.append(buffer, count: count)
                let shouldSchedule = !isFlushScheduled
                isFlushScheduled = true
                lock.unlock()
                if shouldSchedule {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in self?.flush() }
                }
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN {
                return
            } else {
                finish()
                return
            }
        }
    }

    private func flush() {
        lock.lock()
        let chunk = pending.prefix(Self.maxChunk)
        pending.removeFirst(chunk.count)
        let hasMore = !pending.isEmpty
        isFlushScheduled = hasMore
        lock.unlock()
        if !chunk.isEmpty { onOutput?(Data(chunk)) }
        if hasMore {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in self?.flush() }
        }
    }

    private func finish() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()
        readSource?.cancel()
        exitSource?.cancel()
        Darwin.close(fd)
        DispatchQueue.main.async { [weak self] in
            self?.flush()
            self?.onExit?()
        }
    }

    func write(_ data: Data) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            var offset = 0
            let deadline = Date().addingTimeInterval(2)
            while offset < data.count, Date() < deadline {
                let written = data.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.write(self.fd, base + offset, data.count - offset)
                }
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EAGAIN || errno == EINTR {
                    usleep(2_000)
                } else {
                    return
                }
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        queue.async { [weak self] in
            guard let self, !self.isClosed, cols > 0, rows > 0 else { return }
            _ = tm_set_window_size(self.fd, UInt16(clamping: rows), UInt16(clamping: cols))
        }
    }

    /// Detaches: the client gets SIGHUP when its terminal closes; the tmux session itself goes on.
    func close() {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            kill(self.pid, SIGHUP)
        }
    }
}
