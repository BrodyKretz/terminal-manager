// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "terminal-manager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "terminal-manager", targets: ["TerminalManager"]),
        .executable(name: "terminal-manager-hook", targets: ["TerminalManagerHook"]),
    ],
    targets: [
        // The line protocol between the hook helper and the app, shared so the two can never disagree.
        .target(name: "HookWire", path: "Sources/HookWire"),
        // forkpty and exec in C: nothing may run between fork and exec in a multithreaded process.
        .target(name: "PtySpawn", path: "Sources/PtySpawn"),
        .executableTarget(name: "TerminalManager", dependencies: ["HookWire", "PtySpawn"], path: "Sources/TerminalManager"),
        .executableTarget(name: "TerminalManagerHook", dependencies: ["HookWire"], path: "Sources/TerminalManagerHook"),
        .testTarget(name: "TerminalManagerTests", dependencies: ["TerminalManager", "HookWire"], path: "Tests/TerminalManagerTests"),
    ],
    swiftLanguageVersions: [.v5]
)
