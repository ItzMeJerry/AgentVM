// swift-tools-version: 6.2
//
// AgentVM — disposable Linux VMs for running agents, on apple/container.
//
// The GUI links apple/container's own Swift client libraries and speaks XPC to
// the `container-apiserver` daemon directly: no `container` CLI, no subprocesses.
//
// AgentVM — https://github.com/ItzMeJerry/AgentVM
// Copyright 2026 Jerry Lan
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "AgentVM",
    platforms: [.macOS("26")],
    products: [
        .executable(name: "agentvm-gui", targets: ["AgentVMApp"]),
        .library(name: "AgentVMKit", targets: ["AgentVMKit"]),
    ],
    dependencies: [
        // Pinned to the version of the `container` daemon this talks to: the XPC
        // routes and payloads are versioned with the release, so client and
        // apiserver must agree.
        .package(url: "https://github.com/apple/container.git", exact: "1.3.0"),
        // Pulled in transitively by `container`; declared here so the app can name
        // its types (ContainerizationError, Terminal.Size, Platform) directly.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.41.0"),
        // Pinned below 1.12: from there on SwiftTerm ships a Metal shader, and
        // compiling it needs Xcode's Metal toolchain component — a multi-gigabyte
        // download this app has no other use for. 1.11.2 has the same view API.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.11.2"),
        // Already in the graph below `container`; named here for Logger and FilePath,
        // which its client APIs take as parameters.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.10.1"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.6.4"),
    ],
    targets: [
        .target(
            name: "AgentVMKit",
            dependencies: [
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "ContainerPersistence", package: "container"),
                // RuntimeConfiguration, for editing a stopped container's ports.
                .product(name: "ContainerRuntimeClient", package: "container"),
                .product(name: "TerminalProgress", package: "container"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AgentVMApp",
            dependencies: [
                "AgentVMKit",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Everything here runs without a daemon, a VM or a network: the tests
        // cover the pure logic — port specs, the config file, the env registry,
        // mount and name validation — against temporary directories only.
        .testTarget(
            name: "AgentVMKitTests",
            dependencies: ["AgentVMKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
