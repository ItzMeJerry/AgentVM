//
//  AgentVMInstance.swift
//  A container snapshot from the daemon, read through AgentVM's labels.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import ContainerResource
import Foundation

public struct AgentVMInstance: Identifiable, Sendable, Equatable {
    public let fullName: String
    public let shortName: String
    public let state: RuntimeStatus
    public let mode: AgentVMMode
    public let net: NetPosture
    public let image: String
    public let architecture: String
    /// Only a running instance has an address; a stopped one has no VM at all.
    public let ipv4: String?
    public let cpus: Int
    public let memoryBytes: UInt64
    public let createdAt: Date
    public let startedAt: Date?
    public let mounts: [MountDisplay]
    public let envKeys: [String]
    public let command: [String]
    public let rosetta: Bool
    /// The dedicated internal network, for a killswitch instance.
    public let networkName: String?
    /// Host ports forwarded into the guest, as they apply on the next start.
    public private(set) var ports: [PortMapping]

    public var id: String { fullName }

    /// The image as people type it: `alpine:3.20`, not
    /// `docker.io/library/alpine:3.20`.
    public var imageDisplayName: String { Self.displayName(ofImage: image) }

    static func displayName(ofImage reference: String) -> String {
        // Docker Hub's own shorthand: official images drop both parts,
        // everyone else's drop only the registry.
        for prefix in ["docker.io/library/", "index.docker.io/library/", "docker.io/", "index.docker.io/"]
        where reference.hasPrefix(prefix) {
            return String(reference.dropFirst(prefix.count))
        }
        return reference
    }

    public var isRunning: Bool { state == .running }
    public var isStopped: Bool { state == .stopped }

    /// "running", "stopped", "stopping".
    public var stateLabel: String { state.rawValue }

    public struct MountDisplay: Identifiable, Sendable, Equatable {
        public let id = UUID()
        public let source: String
        public let destination: String
        public let readOnly: Bool
    }

    public init(snapshot: ContainerSnapshot, config: AgentVMConfig) {
        let configuration = snapshot.configuration
        self.fullName = configuration.id
        self.shortName = config.shortName(configuration.id)
        self.state = snapshot.status
        self.mode = AgentVMMode(rawValue: configuration.labels["agentvm.mode"] ?? "") ?? .task
        self.net = NetPosture(rawValue: configuration.labels["agentvm.net"] ?? "") ?? .open
        self.image = configuration.image.reference
        self.architecture = configuration.platform.architecture
        self.ipv4 =
            snapshot.status == .running
            ? snapshot.networks.first.map { "\($0.ipv4Address.address)" } : nil
        self.cpus = configuration.resources.cpus
        self.memoryBytes = configuration.resources.memoryInBytes
        self.createdAt = configuration.creationDate
        self.startedAt = snapshot.startedDate
        self.mounts = configuration.mounts.filter(\.isVirtiofs).map {
            MountDisplay(
                source: $0.source,
                destination: $0.destination,
                readOnly: $0.options.readonly)
        }
        self.envKeys = configuration.initProcess.environment.compactMap {
            $0.split(separator: "=", maxSplits: 1).first.map(String.init)
        }
        self.command = [configuration.initProcess.executable] + configuration.initProcess.arguments
        self.rosetta = configuration.rosetta
        self.networkName =
            NetPosture(rawValue: configuration.labels["agentvm.net"] ?? "") == .killswitch
            ? config.networkName(for: configuration.id) : nil
        // The daemon's copy, which is stale after an edit; see `withPorts`.
        self.ports = configuration.publishedPorts.map(PortMapping.init)
    }

    /// The ports read from the container's bundle, which is what the runtime
    /// uses at start — the daemon's in-memory copy only refreshes when it restarts.
    func withPorts(_ ports: [PortMapping]?) -> AgentVMInstance {
        guard let ports else { return self }
        var copy = self
        copy.ports = ports
        return copy
    }

    /// Ports can change only while no VM is running. (A one-shot never sits
    /// stopped: it is removed as it stops.)
    public var canEditPorts: Bool { state == .stopped }

    public var memoryDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
    }

    /// What this instance's lifetime depends on, in one line.
    public var lifetimeDescription: String {
        switch mode {
        case .instance:
            "Runs until you stop it — shell sessions are independent processes."
        case .task:
            "Stops when its command finishes; then persists as 'stopped' until deleted."
        }
    }
}
