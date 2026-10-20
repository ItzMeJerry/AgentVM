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
    /// The labels AgentVM records its choices in on every container it makes.
    static let netLabel = "agentvm.net"
    static let modeLabel = "agentvm.mode"

    public let fullName: String
    public let shortName: String
    public let state: RuntimeStatus
    /// As it applies on the next start: it changes with the main process.
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
    /// The main process, program first, as it runs on the next start.
    public let command: [String]
    public let rosetta: Bool
    /// The dedicated internal network, for a killswitch instance.
    public let networkName: String?
    /// Host ports forwarded into the guest, as they apply on the next start.
    public let ports: [PortMapping]
    /// Removed by the daemon as it stops: a task created one-shot.
    public let isOneShot: Bool

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

    /// No identity of its own: a fresh one each poll made every poll's list
    /// differ from the last, and the same path can be mounted twice.
    public struct MountDisplay: Sendable, Equatable {
        public let source: String
        public let destination: String
        public let readOnly: Bool
    }

    /// What can change while an instance is stopped — its ports, and its main
    /// process and with it its mode — comes from `bundle`, the configuration
    /// in the container's bundle, when it can be read: that's what the
    /// runtime uses at start, while the daemon's in-memory copy refreshes
    /// only when the daemon restarts. `oneShot` is from the bundle's options,
    /// which the daemon keeps apart from the configuration it reports.
    public init(
        snapshot: ContainerSnapshot, config: AgentVMConfig, bundle: ContainerConfiguration? = nil,
        oneShot: Bool = false
    ) {
        let configuration = snapshot.configuration
        let nextStart = bundle ?? configuration
        let net = NetPosture(rawValue: configuration.labels[Self.netLabel] ?? "") ?? .open
        self.fullName = configuration.id
        self.shortName = config.shortName(configuration.id)
        self.state = snapshot.status
        self.mode = AgentVMMode(rawValue: nextStart.labels[Self.modeLabel] ?? "") ?? .task
        self.net = net
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
        self.command = [nextStart.initProcess.executable] + nextStart.initProcess.arguments
        self.rosetta = configuration.rosetta
        self.networkName = net == .killswitch ? config.networkName(for: configuration.id) : nil
        self.ports = nextStart.publishedPorts.map(PortMapping.init)
        self.isOneShot = oneShot
    }

    /// Ports can change only while no VM is running. (A one-shot never sits
    /// stopped: it is removed as it stops.)
    public var canEditPorts: Bool { state == .stopped }

    /// The main process, likewise: it's read when the VM boots.
    public var canChangeMainProcess: Bool { state == .stopped }

    /// A lock keeps an instance until it's unlocked. A one-shot task removes
    /// itself as its command finishes, which no lock of AgentVM's can stop.
    public var canLock: Bool { !isOneShot }

    public var memoryDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
    }

    /// What this instance's lifetime depends on, in one line.
    public var lifetimeDescription: String {
        switch mode {
        case .instance:
            "Runs until you stop it — shell sessions are independent processes."
        case .task:
            isOneShot
                ? "One-shot: removed as soon as its command finishes."
                : "Stops when its command finishes; then persists as 'stopped' until deleted."
        }
    }
}
