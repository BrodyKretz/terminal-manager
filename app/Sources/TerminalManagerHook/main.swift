import Darwin
import Foundation
import HookWire

// terminal-manager-hook --socket PATH --server PATH EVENT, run by Claude Code for each hook of the app's
// plugin with the hook's JSON on stdin. It forwards the call to the app's socket and, for an interactive
// PermissionRequest of the main conversation only, waits for the app's answer and prints it. Every other
// outcome (no app running, a listener that is not the app, bad input, a hold released or timed out)
// prints nothing, and it always exits 0, so Claude Code behaves as it would without the app.

/// The whole of stdin, read to its end even past `limit`, so Claude Code never writes into a closed pipe.
func readStandardInput(limit: Int) -> Data? {
    var data = Data()
    var isOverLimit = false
    var buffer = [UInt8](repeating: 0, count: 64 << 10)
    while true {
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count > 0 {
            guard !isOverLimit else { continue }
            data.append(buffer, count: count)
            if data.count > limit {
                isOverLimit = true
                data = Data()
            }
        } else if count == 0 {
            return isOverLimit ? nil : data
        } else if errno != EINTR {
            return nil
        }
    }
}

/// Whether `pid` has a controlling terminal. Hooks run as direct children of the claude process.
func hasControllingTTY(_ pid: pid_t) -> Bool {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
    return info.e_tdev != UInt32.max
}

func testHasTTY() -> Bool {
    #if DEBUG
    return ProcessInfo.processInfo.environment["TERMINAL_MANAGER_HOOK_TEST_TTY"] == "1"
    #else
    return false
    #endif
}

func run() {
    let data = readStandardInput(limit: HookLine.maxInputBytes)
    guard let arguments = HookArguments.parse(CommandLine.arguments), let data,
          let read = HookLine.readInput(data, repairsLoneSurrogates: arguments.event != HookLine.permissionRequest) else { return }
    let claudePID = getppid()
    let environment = ProcessInfo.processInfo.environment
    let isInteractive = HookLine.isInteractive(entrypoint: environment[HookLine.entrypointVariable], hasTTY: testHasTTY() || hasControllingTTY(claudePID))
    let appSession = environment[HookLine.sessionVariable].flatMap { HookLine.isAppSessionID($0) ? $0 : nil }
    let message = HookMessage(
        event: arguments.event, isInteractive: isInteractive, claudePID: claudePID, appSession: appSession,
        input: HookLine.strippedInput(read.input), isAmbiguous: read.scan.isAmbiguous, hasInexactNumber: read.scan.hasInexactNumber
    )
    guard let line = HookLine.messageLine(message) else { return }

    let started = HookSocket.uptime()
    guard let socket = HookSocket.connect(to: arguments.socketPath, until: started + HookLine.connectTimeout) else { return }
    defer { close(socket) }
    let listener = HookSocket.peerPID(socket)
    guard HookLine.isExpectedListener(
        peerUID: HookSocket.peerUID(socket), ownUID: getuid(),
        peerPath: listener.flatMap(HookSocket.executablePath(of:)), serverPath: arguments.serverPath
    ) else { return }
    let isHeld = HookLine.holds(message)
    let deadline = HookSocket.uptime() + (isHeld ? HookLine.sendTimeout : HookLine.closeTimeout)
    guard HookSocket.writeAll(socket, line, until: deadline) else { return }
    guard isHeld else {
        // Stay connected until the app has asked the kernel who sent the line (it only answers while connected).
        HookSocket.waitForClose(socket, until: deadline)
        return
    }
    guard let reply = HookSocket.readLine(socket, until: started + HookLine.holdTimeout, limit: HookLine.maxLineBytes),
          let output = HookLine.output(fromReply: reply),
          let text = HookLine.printable(output) else { return }
    HookSocket.writeAll(STDOUT_FILENO, text, until: HookSocket.uptime() + HookLine.sendTimeout)
}

signal(SIGPIPE, SIG_IGN)
run()
exit(0)
