import Darwin
import Foundation
import HookWire

/// One line a client sent, as the server read it.
struct ReceivedHook: @unchecked Sendable {
    let message: HookMessage
    /// The connection, kept open, when the line holds (the main conversation's interactive
    /// PermissionRequest, from Claude Code's own child, whose raw JSON no two parsers read differently);
    /// nil for every other line, already closed.
    let connection: HookServer.ConnectionID?
    /// The kernel says the client is a direct child of the process the line names as Claude Code's
    /// (asked at accept, while the client was connected). Without it the line is an anonymous
    /// observation: it is never held and changes nothing.
    let isFromClaude: Bool
}

/// The app's end of the hook socket: `~/.terminal-manager/run/hooks.sock`, mode 0600 in a 0700 folder,
/// and a peer must run as this user (getpeereid). One line per connection; a held PermissionRequest's
/// connection stays open until the app answers it, releases it, or the helper goes away (a terminal No
/// or Esc kills it). Connections are accepted, and the kernel asked who connected, on a queue that does
/// nothing else, so a client is named while it is still connected however long the lines before it
/// take; every other socket call runs on one utility queue, so a slow or hung client never reaches the
/// main thread. Both callbacks run on that queue, in the order the lines were read. Nothing a client
/// sends is ever taken as an answer: answers only come from `reply`.
final class HookServer: @unchecked Sendable {
    typealias ConnectionID = Int

    enum StartError: Error, Equatable, CustomStringConvertible {
        case pathTooLong(String)
        case inUse(String)
        case notASocket(String)
        case system(String, Int32)

        var description: String {
            switch self {
            case .pathTooLong(let path): return "the socket path is longer than \(HookSocket.maxPathBytes) bytes: \(path)"
            case .inUse(let path): return "another process already listens on \(path)"
            case .notASocket(let path): return "\(path) exists and is not a socket; it was left alone"
            case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    static let maxConnections = 64
    /// A burst of hooks (parallel tool calls, several sessions) waits in the kernel's queue, not refused.
    static let backlog = SOMAXCONN
    /// A client that has not sent its whole line by then is dropped.
    static let lineTimeout: TimeInterval = 10
    static let replyTimeout: TimeInterval = 2

    let socketPath: String
    let lineTimeout: TimeInterval
    /// The only user a client may run as: this process's own.
    let ownUID: uid_t
    private let queue = DispatchQueue(label: "terminal-manager.hooks", qos: .utility)
    /// accept() and the kernel's answers about the peer, nothing more: the helper leaves a line it is
    /// not waiting on after HookLine.closeTimeout, and LOCAL_PEERPID only answers while it is connected.
    private let acceptQueue = DispatchQueue(label: "terminal-manager.hooks.accept", qos: .userInitiated)
    private let onMessage: @Sendable (ReceivedHook) -> Void
    private let onDropped: @Sendable (ConnectionID) -> Void

    /// Connections accepted and not closed yet (registered or on their way to `queue`), so the cap holds
    /// where connections are accepted, however far behind `queue` is.
    private let slotLock = NSLock()
    private var openSlots = 0

    // Touched on `queue` only.
    private var acceptSource: DispatchSourceRead?
    private var connections: [ConnectionID: Connection] = [:]
    private var nextID: ConnectionID = 1
    private var boundInode: ino_t?

    private final class Connection {
        let fd: Int32
        let source: DispatchSourceRead
        /// The client's parent process, read at accept: Claude Code's pid when the client is its hook.
        let peerParentPID: pid_t?
        var buffer = Data()
        var isHeld = false
        var lineDeadline: DispatchWorkItem?

        init(fd: Int32, source: DispatchSourceRead, peerParentPID: pid_t?) {
            self.fd = fd
            self.source = source
            self.peerParentPID = peerParentPID
        }
    }

    /// `onMessage` gets every line; `onDropped` hears that a held connection's helper went away. Both are
    /// called on the server's queue (hop to the main queue there).
    init(
        socketPath: String,
        lineTimeout: TimeInterval = HookServer.lineTimeout,
        ownUID: uid_t = getuid(),
        onMessage: @escaping @Sendable (ReceivedHook) -> Void,
        onDropped: @escaping @Sendable (ConnectionID) -> Void
    ) {
        self.socketPath = socketPath
        self.lineTimeout = lineTimeout
        self.ownUID = ownUID
        self.onMessage = onMessage
        self.onDropped = onDropped
    }

    /// A stale socket (nothing listening) is removed first; a live one, or anything that is not a
    /// socket, is left alone and the server does not start.
    func start() throws {
        try queue.sync { try startListening() }
    }

    /// Closes every connection (a held helper then prints nothing) and removes the socket if it is still ours.
    func stop() {
        queue.sync { stopListening() }
    }

    /// Writes the answer to the held connection, then closes it. `completion` (on the main queue) hears
    /// whether the whole answer reached the helper: false when it was gone already (a terminal Esc).
    func reply(_ id: ConnectionID, with line: Data, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [weak self] in
            var isDelivered = false
            if let self, let connection = self.connections[id], connection.isHeld {
                isDelivered = HookSocket.writeAll(connection.fd, line, until: HookSocket.uptime() + Self.replyTimeout)
                self.closeConnection(id)
            }
            DispatchQueue.main.async { completion(isDelivered) }
        }
    }

    /// Closes a held connection without a word: the helper prints nothing and the terminal's dialog decides.
    func release(_ id: ConnectionID) {
        queue.async { [weak self] in self?.closeConnection(id) }
    }

    var connectionCount: Int {
        queue.sync { connections.count }
    }

    // MARK: on the queue

    private func startListening() throws {
        guard acceptSource == nil else { return }
        guard var address = HookSocket.address(for: socketPath) else { throw StartError.pathTooLong(socketPath) }
        try removeStaleSocket()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.system("socket", errno) }
        HookSocket.configure(fd)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw StartError.system("bind", code)
        }
        var status = stat()
        guard chmod(socketPath, 0o600) == 0, listen(fd, Self.backlog) == 0, lstat(socketPath, &status) == 0 else {
            let code = errno
            close(fd)
            unlink(socketPath)
            throw StartError.system("listen", code)
        }
        boundInode = status.st_ino
        HookSocket.setNonBlocking(fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(listener: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    private func removeStaleSocket() throws {
        var status = stat()
        guard lstat(socketPath, &status) == 0 else { return }
        guard status.st_mode & S_IFMT == S_IFSOCK else { throw StartError.notASocket(socketPath) }
        if let probe = HookSocket.connect(to: socketPath, until: HookSocket.uptime() + HookLine.connectTimeout) {
            close(probe)
            throw StartError.inUse(socketPath)
        }
        unlink(socketPath)
    }

    private func stopListening() {
        acceptSource?.cancel()
        acceptSource = nil
        for id in Array(connections.keys) { closeConnection(id) }
        var status = stat()
        if let boundInode, lstat(socketPath, &status) == 0, status.st_ino == boundInode { unlink(socketPath) }
        boundInode = nil
    }

    /// On `acceptQueue`: the peer is named right away, then handed to `queue`.
    private func acceptPending(listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            HookSocket.configure(fd)
            HookSocket.setNonBlocking(fd)
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == ownUID, takeSlot() else {
                close(fd)
                continue
            }
            let peerParentPID = HookSocket.peerPID(fd).flatMap(HookSocket.parentPID(of:))
            queue.async { [weak self] in
                guard let self else {
                    close(fd)
                    return
                }
                self.register(fd, peerParentPID: peerParentPID)
            }
        }
    }

    /// One of the 64 places, or false when all are taken (the connection is closed at once).
    private func takeSlot() -> Bool {
        slotLock.lock()
        defer { slotLock.unlock() }
        guard openSlots < Self.maxConnections else { return false }
        openSlots += 1
        return true
    }

    private func freeSlot() {
        slotLock.lock()
        openSlots -= 1
        slotLock.unlock()
    }

    /// On `queue`: a connection accepted (and named) on `acceptQueue`, unless the server stopped
    /// meanwhile. A line its helper sent before leaving is still in the socket, and still counts as that
    /// helper's.
    private func register(_ fd: Int32, peerParentPID: pid_t?) {
        guard acceptSource != nil else {
            close(fd)
            freeSlot()
            return
        }
        let id = nextID
        nextID += 1
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let connection = Connection(fd: fd, source: source, peerParentPID: peerParentPID)
        source.setEventHandler { [weak self] in self?.readable(id) }
        source.setCancelHandler { close(fd) }
        let deadline = DispatchWorkItem { [weak self] in self?.lineTimedOut(id) }
        connection.lineDeadline = deadline
        connections[id] = connection
        queue.asyncAfter(deadline: .now() + lineTimeout, execute: deadline)
        source.resume()
    }

    private func readable(_ id: ConnectionID) {
        guard let connection = connections[id] else { return }
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = read(connection.fd, &chunk, chunk.count)
            if count > 0, connection.isHeld {
                // The helper sends nothing after its line; a client that does is dropped like one that left.
                drop(id)
                return
            } else if count > 0 {
                let start = connection.buffer.count
                connection.buffer.append(chunk, count: count)
                if let newline = connection.buffer[start...].firstIndex(of: 0x0A) {
                    let line = Data(connection.buffer[..<newline])
                    connection.buffer = Data()
                    lineArrived(line, on: id, connection)
                    guard connections[id] != nil else { return }
                } else if connection.buffer.count > HookLine.maxLineBytes {
                    closeConnection(id)
                    return
                }
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN {
                return
            } else {
                if connection.isHeld { drop(id) } else { closeConnection(id) }
                return
            }
        }
    }

    /// A held connection gone (or broken): closed here, and the app hears it.
    private func drop(_ id: ConnectionID) {
        closeConnection(id)
        onDropped(id)
    }

    private func lineArrived(_ line: Data, on id: ConnectionID, _ connection: Connection) {
        connection.lineDeadline?.cancel()
        connection.lineDeadline = nil
        guard let message = HookLine.parseMessage(line) else {
            closeConnection(id)
            return
        }
        let isFromClaude = message.claudePID > 1 && connection.peerParentPID == message.claudePID
        let isHeld = isFromClaude && HookLine.holds(message)
        if isHeld {
            connection.isHeld = true
        } else {
            closeConnection(id)
        }
        onMessage(ReceivedHook(message: message, connection: isHeld ? id : nil, isFromClaude: isFromClaude))
    }

    private func lineTimedOut(_ id: ConnectionID) {
        guard let connection = connections[id], !connection.isHeld else { return }
        closeConnection(id)
    }

    private func closeConnection(_ id: ConnectionID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.lineDeadline?.cancel()
        connection.source.cancel()
        freeSlot()
    }
}
