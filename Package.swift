// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

var products: [Product] = [
    .executable(name: "ainotch-hook", targets: ["AINotchHook"]),
]

var targets: [Target] = [
    // Platform-independent logic: transcript parsing, pricing, session state,
    // hook IPC and settings.json editing. Builds and tests on Linux too.
    .target(name: "AINotchCore", path: "Sources/AINotchCore"),
    // Tiny CLI that Claude Code runs as a hook; forwards events to the app.
    .executableTarget(name: "AINotchHook", dependencies: ["AINotchCore"], path: "Sources/AINotchHook"),
    .testTarget(name: "AINotchCoreTests", dependencies: ["AINotchCore"], path: "Tests/AINotchCoreTests"),
]

#if os(macOS)
products.append(.executable(name: "AINotch", targets: ["AINotch"]))
targets.append(.executableTarget(name: "AINotch", dependencies: ["AINotchCore"], path: "Sources/AINotch"))
#endif

let package = Package(
    name: "AINotch",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
