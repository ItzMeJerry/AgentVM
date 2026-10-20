//
//  AgentVMEngine+Bundle.swift
//  Changing a stopped instance: its published ports, and its main process.
//
//  `container` 1.3.0 has no API for either: both are fixed at `create`. But the
//  runtime helper reads them from the container's bundle on every start
//  (RuntimeService.bootstrap → Bundle.configuration → the init process and
//  startSocketForwarders), so rewriting the bundle while the VM is down takes
//  effect on the next Start. Files in <app-root>/containers/<id>/:
//
//    config.json                 what the runtime reads; written on first start
//    runtime-configuration.json  the creation-time copy, the fallback when
//                                config.json is missing or doesn't decode
//    options.json                how it was created: whether it's one-shot.
//                                Read only, and backed up with the others
//
//  The two configurations are written with the daemon's own types and encoder,
//  and decoded again before the change counts: at boot the daemon *deletes* a
//  container whose configuration fails to decode. The originals are backed up
//  first and put back if anything fails.
//
//  The daemon keeps its own in-memory copy of every configuration from when it
//  booted, so `get` and `list` go on reporting the old ports and the old main
//  process until it restarts. What's on disk is what applies, and it is what
//  AgentVM shows.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import ContainerAPIClient
import ContainerResource
import ContainerRuntimeClient
import Darwin
import Foundation

extension AgentVMEngine {
    /// Replaces an instance's published ports. The instance must be stopped:
    /// the change applies when it next starts.
    public func setPorts(_ mappings: [PortMapping], on instance: AgentVMInstance) async throws {
        let ports = try PortMapping.validate(mappings)
        try await rewrite(instance, what: "the ports") { configuration in
            configuration.publishedPorts = ports
        } matches: { configuration in
            configuration.publishedPorts.map(PortMapping.init) == mappings
        }
    }

    /// Replaces an instance's main process, and with it the lifetime it
    /// follows: the keepalive makes it an instance, a command makes it a task.
    /// The instance must be stopped: the change applies when it next starts.
    /// Everything else about the process — its environment, working
    /// directory and user — stays as it was created.
    public func setMainProcess(_ process: MainProcess, on instance: AgentVMInstance) async throws {
        try await rewrite(instance, what: "the main process") { configuration in
            configuration.initProcess.executable = process.executable
            configuration.initProcess.arguments = process.arguments
            configuration.labels[AgentVMInstance.modeLabel] = process.mode.rawValue
        } matches: { configuration in
            configuration.initProcess.executable == process.executable
                && configuration.initProcess.arguments == process.arguments
                && configuration.labels[AgentVMInstance.modeLabel] == process.mode.rawValue
        }
    }

    /// An instance as it will next start: the daemon's snapshot, with what
    /// its bundle knows and the daemon's copy doesn't — the ports and main
    /// process that apply on the next start, and whether it's one-shot.
    /// Where the bundle can't be read, the daemon's copy stands.
    nonisolated func instance(
        from snapshot: ContainerSnapshot, config: AgentVMConfig, in containersRoot: URL?
    ) -> AgentVMInstance {
        guard let containersRoot else { return AgentVMInstance(snapshot: snapshot, config: config) }
        let files = BundleFiles(directory: containersRoot.appendingPathComponent(snapshot.id))
        return AgentVMInstance(
            snapshot: snapshot, config: config, bundle: try? files.configuration(), oneShot: files.isOneShot)
    }

    /// Changes a stopped instance's configuration in both bundle files, reads
    /// it back the way the daemon will, and puts the originals back if any of
    /// that fails. `what` names the change in errors: "the ports".
    private func rewrite(
        _ instance: AgentVMInstance,
        what: String,
        change: (inout ContainerConfiguration) -> Void,
        matches: (ContainerConfiguration) -> Bool
    ) async throws {
        let bundle = try await bundleDirectory(for: instance.fullName)
        let files = BundleFiles(directory: bundle)

        try await ensureStopped(instance.fullName, files: files)
        if files.isOneShot {
            throw AgentVMError(
                "\(instance.shortName) is one-shot",
                hint: "It is removed as it stops, so it never sits stopped for \(what) to change.")
        }

        let backup = try files.backUp(into: backupDirectory(for: instance.fullName))
        do {
            if FileManager.default.fileExists(atPath: files.config.path) {
                var configuration: ContainerConfiguration = try files.decode(files.config)
                change(&configuration)
                try files.write(configuration, to: files.config)
            }
            if FileManager.default.fileExists(atPath: files.runtime.path) {
                let runtime: RuntimeConfiguration = try files.decode(files.runtime)
                if var configuration = runtime.containerConfiguration {
                    change(&configuration)
                    try files.write(
                        RuntimeConfiguration(
                            path: runtime.path,
                            initialFilesystem: runtime.initialFilesystem,
                            kernel: runtime.kernel,
                            containerConfiguration: configuration,
                            containerRootFilesystem: runtime.containerRootFilesystem,
                            options: runtime.options,
                            runtimeData: runtime.runtimeData),
                        to: files.runtime)
                }
            }
            // Read back exactly as the daemon will.
            guard matches(try files.configuration()) else {
                throw AgentVMError("what was read back differs from what was written")
            }
            if FileManager.default.fileExists(atPath: files.runtime.path) {
                let runtime: RuntimeConfiguration = try files.decode(files.runtime)
                if let configuration = runtime.containerConfiguration, !matches(configuration) {
                    throw AgentVMError("the fallback configuration read back differs from what was written")
                }
            }
        } catch {
            do {
                try files.restore(from: backup)
            } catch let restoreError {
                throw AgentVMError(
                    "could not change \(what) of \(instance.shortName), and could not put the old files back",
                    hint: "\(error)\n\nRestore failed: \(restoreError)\nThe originals are in \(backup.path).")
            }
            throw AgentVMError(
                "could not change \(what) of \(instance.shortName); nothing was changed",
                hint: "\(error)")
        }
    }

    // MARK: - Safety

    /// Stopped means: the daemon says so, *and* launchd no longer holds the
    /// runtime helper — the process that owns the VM and the port forwarders.
    private func ensureStopped(_ fullName: String, files: BundleFiles) async throws {
        let snapshot = try await containers.get(id: fullName)
        guard snapshot.status == .stopped else {
            throw AgentVMError(
                "\(fullName) is \(snapshot.status.rawValue)",
                hint: "Stop it first. Ports and the main process are read when the VM boots.")
        }
        let handler = (try? files.configuration().runtimeHandler) ?? snapshot.configuration.runtimeHandler
        let service = RuntimeClient.machServiceLabel(runtime: handler, id: fullName)
        if MachLookup.isRegistered(service) {
            throw AgentVMError(
                "\(fullName)'s runtime helper is still registered with launchd",
                hint: "It is still shutting down. Wait a moment and try again.")
        }
    }

    // MARK: - Locations

    private func bundleDirectory(for fullName: String) async throws -> URL {
        guard let root = await containersRoot() else { throw AgentVMError.serviceUnreachable }
        let directory = root.appendingPathComponent(fullName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw AgentVMError("no container bundle for \(fullName) at \(directory.path)")
        }
        return directory
    }

    private func backupDirectory(for fullName: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agentvm/backups", isDirectory: true)
            .appendingPathComponent(fullName, isDirectory: true)
    }
}

/// The three files of a container bundle this touches, read and written the
/// way the daemon does it.
private struct BundleFiles {
    let directory: URL
    var config: URL { directory.appendingPathComponent("config.json") }
    var runtime: URL { directory.appendingPathComponent("runtime-configuration.json") }
    var options: URL { directory.appendingPathComponent("options.json") }

    /// Keeps the newest few sets per instance.
    static let backupsKept = 10

    func decode<T: Decodable>(_ url: URL) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    /// Whether the daemon removes the container as it stops: from the
    /// options it was created with.
    var isOneShot: Bool {
        let created: ContainerCreateOptions? = try? decode(options)
        return created?.autoRemove ?? false
    }

    /// config.json when there is one, else the creation-time copy — the order
    /// the daemon and the runtime read them in.
    func configuration() throws -> ContainerConfiguration {
        if let configuration: ContainerConfiguration = try? decode(config) {
            return configuration
        }
        let runtime: RuntimeConfiguration = try decode(self.runtime)
        guard let configuration = runtime.containerConfiguration else {
            throw AgentVMError("runtime-configuration.json has no container configuration")
        }
        return configuration
    }

    /// Atomic, and in the bundle's own encoding: `JSONEncoder` with default
    /// settings, as `Bundle.write` and `writeRuntimeConfiguration` use.
    func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }

    func backUp(into root: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let destination = root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in [config, runtime, options] where fileManager.fileExists(atPath: file.path) {
            try fileManager.copyItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
        }
        // Timestamped names sort chronologically.
        if let sets = try? fileManager.contentsOfDirectory(atPath: root.path).sorted(),
            sets.count > Self.backupsKept
        {
            for name in sets.prefix(sets.count - Self.backupsKept) {
                try? fileManager.removeItem(at: root.appendingPathComponent(name))
            }
        }
        return destination
    }

    func restore(from backup: URL) throws {
        for file in [config, runtime, options] {
            let saved = backup.appendingPathComponent(file.lastPathComponent)
            guard FileManager.default.fileExists(atPath: saved.path) else { continue }
            try Data(contentsOf: saved).write(to: file, options: .atomic)
        }
    }
}

/// `bootstrap_look_up` from <servers/bootstrap.h>, which Swift doesn't import.
@_silgen_name("bootstrap_look_up")
private func bootstrapLookUp(
    _ bootstrapPort: mach_port_t,
    _ serviceName: UnsafePointer<CChar>,
    _ servicePort: UnsafeMutablePointer<mach_port_t>
) -> kern_return_t

/// Whether launchd holds a Mach service by that name — i.e. whether the job
/// that provides it is loaded — without launching it and without `launchctl`.
private enum MachLookup {
    static func isRegistered(_ name: String) -> Bool {
        var bootstrap: mach_port_t = 0
        guard task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bootstrap) == KERN_SUCCESS else {
            return false
        }
        defer { mach_port_deallocate(mach_task_self_, bootstrap) }
        var port: mach_port_t = 0
        guard bootstrapLookUp(bootstrap, name, &port) == KERN_SUCCESS else { return false }
        mach_port_deallocate(mach_task_self_, port)
        return true
    }
}
