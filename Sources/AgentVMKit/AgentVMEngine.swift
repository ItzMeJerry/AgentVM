//
//  AgentVMEngine.swift
//  Every AgentVM operation, spoken directly to the `container` daemon over XPC via
//  apple/container's own Swift client. No CLI, no subprocesses, no output parsing.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOS
import Foundation
import Logging
import SystemPackage
import TerminalProgress

public actor AgentVMEngine {
    public static let shared = AgentVMEngine()

    let containers = ContainerClient()
    private let networks = NetworkClient()
    private let log = Logger(label: "io.github.itzmejerry.agentvm")

    /// The daemon-reported system configuration (registry defaults, init image,
    /// DNS domain). Cached: it costs an XPC round trip plus TOML parsing.
    private var systemConfig: ContainerPersistence.ContainerSystemConfig?
    /// Where the daemon keeps its state; container bundles live under it.
    private var appRoot: URL?

    public init() {}

    // MARK: - Preflight

    public struct DaemonStatus: Sendable {
        public let running: Bool
        public let version: String?
        public let appRoot: String?
        public let message: String?
        /// The service's build kind, such as `release`.
        public var build: String? = nil
        /// Where the service itself is installed.
        public var installRoot: String? = nil

        /// What `daemonStatus()` reports when the service doesn't answer.
        public static let notRunning = DaemonStatus(
            running: false, version: nil, appRoot: nil,
            message: "The container system service is not running. Start it with `container system start`.")

        /// The release number — `1.3.0` — out of the API server's full version
        /// string, which also carries its build kind and commit.
        public var release: String? {
            guard let version,
                let range = version.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression)
            else { return nil }
            return String(version[range])
        }
    }

    /// Whether the control plane is up. Replaces `container system status`.
    public func daemonStatus() async -> DaemonStatus {
        do {
            let health = try await ClientHealthCheck.ping(timeout: .seconds(5))
            return DaemonStatus(
                running: true,
                version: health.apiServerVersion,
                appRoot: health.appRoot.path(percentEncoded: false),
                message: nil,
                build: health.apiServerBuild,
                installRoot: health.installRoot.path(percentEncoded: false))
        } catch {
            return .notRunning
        }
    }

    private func loadSystemConfig() async throws -> ContainerPersistence.ContainerSystemConfig {
        if let systemConfig { return systemConfig }
        let health: SystemHealth
        do {
            health = try await ClientHealthCheck.ping(timeout: .seconds(10))
        } catch {
            throw AgentVMError(
                "cannot reach the container system service",
                hint: "Start it with `container system start`, then try again.")
        }
        let appRoot = FilePath(health.appRoot.path(percentEncoded: false))
        let installRoot = FilePath(health.installRoot.path(percentEncoded: false))
        let loaded = try await ConfigurationLoader.load(
            configurationFiles: [
                ConfigurationLoader.configurationFile(in: appRoot, of: .appRoot),
                ConfigurationLoader.configurationFile(in: installRoot, of: .installRoot),
            ]
        )
        systemConfig = loaded
        return loaded
    }

    // MARK: - Listing

    /// Every container carrying the configured name prefix. Nothing else is ever
    /// listed, so your other containers stay out of AgentVM's way.
    public func list(config: AgentVMConfig) async throws -> [AgentVMInstance] {
        let snapshots = try await containers.list()
        let root = await containersRoot()
        return
            snapshots
            .filter { config.isAgentVMName($0.id) }
            .map { AgentVMInstance(snapshot: $0, config: config).withPorts(diskPorts(for: $0.id, in: root)) }
            .sorted { $0.fullName < $1.fullName }
    }

    public func instance(named fullName: String, config: AgentVMConfig) async throws -> AgentVMInstance {
        let snapshot = try await containers.get(id: fullName)
        let root = await containersRoot()
        return AgentVMInstance(snapshot: snapshot, config: config).withPorts(diskPorts(for: fullName, in: root))
    }

    /// `<app-root>/containers`, where each container's bundle lives.
    func containersRoot() async -> URL? {
        if appRoot == nil {
            appRoot = try? await ClientHealthCheck.ping(timeout: .seconds(5)).appRoot
        }
        return appRoot?.appendingPathComponent("containers", isDirectory: true)
    }

    /// The killswitch networks AgentVM owns, by name.
    public func agentVMNetworkNames(config: AgentVMConfig) async throws -> Set<String> {
        let all = try await networks.list()
        return Set(all.map(\.id).filter(config.isAgentVMNetworkName))
    }

    // MARK: - Create

    /// Creates the container and starts its main process detached. Every field
    /// goes through the API, so no shell quoting is ever involved.
    @discardableResult
    public func create(
        spec: RunSpec,
        config: AgentVMConfig,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        let systemConfig = try await loadSystemConfig()

        guard !spec.image.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AgentVMError("choose an image to boot (for example ubuntu:24.04)")
        }
        if spec.mode == .task && spec.command.isEmpty {
            throw AgentVMError("a task needs a command — the command is its main process")
        }
        if spec.mode == .instance && spec.removeOnExit {
            throw AgentVMError(
                "one-shot needs a command that can finish",
                hint: "An instance's keepalive never exits. Delete it when you are done instead.")
        }

        // Identity.
        let fullName: String
        if spec.name.trimmingCharacters(in: .whitespaces).isEmpty {
            fullName = AgentVMNaming.randomName(prefix: config.namePrefix)
        } else {
            let short = config.shortName(spec.name.trimmingCharacters(in: .whitespaces))
            try AgentVMNaming.validateShortName(short, posture: spec.net)
            fullName = config.namePrefix + short
        }
        guard ManagedContainer.nameValid(fullName) else {
            throw AgentVMError("'\(fullName)' is not a valid container name")
        }
        if let existing = try? await containers.get(id: fullName) {
            let state = existing.status.rawValue
            throw AgentVMError(
                "\(fullName) already exists (\(state))",
                hint: state == "running"
                    ? "Stop it first, or pick another name."
                    : "Start it again to reuse it, or delete it to free the name.")
        }

        // The killswitch: a dedicated host-only network per instance, created
        // before the container and recorded on it as a label.
        let networkName = config.networkName(for: fullName)
        if spec.net == .killswitch {
            progress("Creating the killswitch network")
            try await ensureInternalNetwork(named: networkName)
        }

        // Every field is passed explicitly: these are ArgumentParser types, and a
        // property that was neither parsed nor assigned faults when read.
        let management = Flags.Management(
            arch: spec.arch.flatMap { $0.isEmpty ? nil : $0 } ?? Arch.hostArchitecture().rawValue,
            capAdd: [],
            capDrop: [],
            cidfile: "",
            detach: true,
            dns: Flags.DNS(domain: nil, nameservers: [], options: [], searchDomains: []),
            dnsDisabled: spec.net == .killswitch,
            // The keepalive goes in as the entrypoint, so the image's own
            // entrypoint is bypassed the way `--entrypoint sh` did.
            entrypoint: spec.mode == .instance ? RunSpec.keepaliveEntrypoint : nil,
            initImage: nil,
            kernel: nil,
            kernelArgs: [],
            labels: ["agentvm.net=\(spec.net.rawValue)", "agentvm.mode=\(spec.mode.rawValue)"],
            maskedPaths: [],
            mounts: try spec.mounts.map { try $0.validated().mountArgument },
            name: fullName,
            networks: spec.net == .killswitch ? [networkName] : [],
            os: "linux",
            platform: nil,
            publishPorts: [],
            publishSockets: [],
            readOnly: false,
            readonlyPaths: [],
            remove: spec.removeOnExit && spec.mode == .task,
            rosetta: spec.rosetta,
            runtime: nil,
            ssh: false,
            shmSize: nil,
            tmpFs: [],
            useInit: false,
            virtualization: false,
            volumes: []
        )

        let registry = EnvRegistry(url: config.envFileURL)
        let process = Flags.Process(
            cwd: nil,
            // Per-instance variables are appended after the registry file, so
            // they win.
            env: spec.env.map { "\($0.key)=\($0.value)" },
            envFile: spec.useRegistry && registry.hasEntries ? [registry.path] : [],
            gid: nil,
            interactive: false,
            // The main process runs detached: its output goes to the container's
            // log. Shell sessions are separate exec processes with their own pty.
            tty: false,
            uid: nil,
            ulimits: [],
            user: nil
        )

        let resources = Flags.Resource(cpus: spec.cpus.map(Int64.init), memory: spec.memory)

        let arguments = spec.mode == .instance ? RunSpec.keepaliveArguments : spec.command

        progress("Fetching image")
        let built: (ContainerConfiguration, Kernel, String?)
        do {
            built = try await Utility.containerConfigFromFlags(
                id: fullName,
                image: spec.image,
                arguments: arguments,
                process: process,
                management: management,
                resource: resources,
                registry: Flags.Registry(scheme: "https"),
                imageFetch: Flags.ImageFetch(maxConcurrentDownloads: 3),
                containerSystemConfig: systemConfig,
                progressUpdate: { events in
                    for event in events {
                        if case .setDescription(let description) = event {
                            progress(description)
                        }
                    }
                },
                log: log
            )
        } catch {
            if spec.net == .killswitch { try? await networks.delete(id: networkName) }
            throw error
        }

        progress("Creating the instance")
        do {
            try await containers.create(
                configuration: built.0,
                options: ContainerCreateOptions(autoRemove: management.remove),
                kernel: built.1,
                initImage: built.2)
        } catch {
            if spec.net == .killswitch { try? await networks.delete(id: networkName) }
            throw error
        }

        progress("Booting")
        do {
            try await bootDetached(id: fullName)
        } catch {
            try? await containers.delete(id: fullName, force: true)
            if spec.net == .killswitch { try? await networks.delete(id: networkName) }
            throw error
        }
        return fullName
    }

    // MARK: - Lifecycle

    /// Starts a stopped instance in its exact creation-time posture. If its
    /// killswitch network went missing it is recreated — always `--internal`,
    /// never more.
    public func start(_ instance: AgentVMInstance) async throws {
        if instance.state == .running { return }
        if let networkName = instance.networkName {
            try await ensureInternalNetwork(named: networkName)
        }
        for mount in instance.mounts where !FileManager.default.fileExists(atPath: mount.source) {
            throw AgentVMError(
                "mount source '\(mount.source)' no longer exists",
                hint: "Restore the directory, or delete this instance and create a new one.")
        }
        try await bootDetached(id: instance.fullName)
    }

    /// Bootstraps the init process with no stdio attached and starts it: the
    /// container runs in the background and its output lands in its log file.
    private func bootDetached(id: String) async throws {
        let process = try await containers.bootstrap(id: id, stdio: [nil, nil, nil])
        try await process.start()
    }

    /// The only thing that stops an instance. The VM is torn down: no IP, no
    /// route, no resolver until it is started again.
    public func stop(_ instance: AgentVMInstance) async throws {
        guard instance.state == .running else { return }
        try await containers.stop(id: instance.fullName)
    }

    /// Removes the instance and, with it, its killswitch network.
    public func delete(_ instance: AgentVMInstance, force: Bool) async throws {
        if instance.state == .running && !force {
            throw AgentVMError(
                "\(instance.fullName) is running",
                hint: "Stop it first, or force the delete.")
        }
        try await containers.delete(id: instance.fullName, force: force)
        if let networkName = instance.networkName {
            // The segment cannot go away while the container still references it,
            // so a failure here is expected noise; prune is the backstop.
            try? await networks.delete(id: networkName)
        }
    }

    public struct PruneResult: Sendable {
        public let containers: [String]
        public let networks: [String]
        public let failures: [String]
    }

    /// Removes every AgentVM container and every AgentVM killswitch network — and only
    /// those: names without the prefix are never touched.
    public func prune(config: AgentVMConfig) async throws -> PruneResult {
        var removedContainers: [String] = []
        var removedNetworks: [String] = []
        var failures: [String] = []

        for snapshot in try await containers.list() where config.isAgentVMName(snapshot.id) {
            do {
                try await containers.delete(id: snapshot.id, force: true)
                removedContainers.append(snapshot.id)
            } catch {
                failures.append("\(snapshot.id): \(error)")
            }
        }
        // Containers first: a network cannot be deleted while a container still
        // references it.
        for network in try await networks.list() where config.isAgentVMNetworkName(network.id) {
            do {
                try await networks.delete(id: network.id)
                removedNetworks.append(network.id)
            } catch {
                failures.append("\(network.id): \(error)")
            }
        }
        return PruneResult(
            containers: removedContainers, networks: removedNetworks, failures: failures)
    }

    // MARK: - Networks

    private func ensureInternalNetwork(named name: String) async throws {
        if (try? await networks.get(id: name)) != nil { return }
        guard NetworkResource.nameValid(name) else {
            throw AgentVMError("'\(name)' is not a valid network name")
        }
        let configuration = try NetworkConfiguration(
            name: name,
            mode: .hostOnly,
            plugin: "container-network-vmnet")
        do {
            _ = try await networks.create(configuration: configuration)
        } catch {
            throw AgentVMError(
                "could not create the killswitch network \(name)",
                hint:
                    "A host-only network needs macOS 26 or newer. Underlying error: \(error)")
        }
    }

    public func networkExists(_ name: String) async -> Bool {
        (try? await networks.get(id: name)) != nil
    }

    // MARK: - Logs

    /// Opens the container's log file. `boot` selects the VM boot log instead of
    /// the instance's stdio.
    public func logHandle(for fullName: String, boot: Bool) async throws -> FileHandle {
        let handles = try await containers.logs(id: fullName)
        guard handles.count > (boot ? 1 : 0) else {
            throw AgentVMError("no logs available for \(fullName)")
        }
        return boot ? handles[1] : handles[0]
    }

    // MARK: - Sessions

    /// Opens a shell session: an independent exec process inside a running
    /// instance. Ending it never stops the container.
    public func openSession(
        in instance: AgentVMInstance,
        command: [String],
        workingDirectory: String?,
        environment: [String]
    ) async throws -> AgentVMShellSession {
        let snapshot = try await containers.get(id: instance.fullName)
        guard snapshot.status == .running else {
            throw AgentVMError("\(instance.fullName) is \(snapshot.status.rawValue), not running")
        }
        guard let executable = command.first else {
            throw AgentVMError("a session needs a command")
        }
        var configuration = snapshot.configuration.initProcess
        configuration.executable = executable
        configuration.arguments = Array(command.dropFirst())
        configuration.terminal = true
        configuration.environment.append(contentsOf: environment)
        if let workingDirectory, !workingDirectory.isEmpty {
            configuration.workingDirectory = workingDirectory
        }
        let io = SessionIO()
        let process = try await containers.createProcess(
            containerId: instance.fullName,
            processId: UUID().uuidString.lowercased(),
            configuration: configuration,
            stdio: io.stdio)
        return AgentVMShellSession(process: process, io: io)
    }
}
