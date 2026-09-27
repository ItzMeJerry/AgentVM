//
//  AgentVMEngine+Ports.swift
//  Changing the published ports of a stopped instance.
//
//  `container` 1.3.0 has no API for this: ports are fixed at `create`. But the
//  runtime helper reads them from the container's bundle on every start
//  (RuntimeService.bootstrap → Bundle.configuration → startSocketForwarders),
//  so rewriting the bundle while the VM is down takes effect on the next
//  Start. Files in <app-root>/containers/<id>/:
//
//    config.json                 what the runtime reads; written on first start
//    runtime-configuration.json  the creation-time copy, the fallback when
//                                config.json is missing or doesn't decode
//
//  Both are written with the daemon's own types and encoder, and decoded again
//  before the change counts: at boot the daemon *deletes* a container whose
//  configuration fails to decode. The originals are backed up first and put
//  back if anything fails.
//
//  The daemon keeps its own in-memory copy of every configuration from when it
//  booted, so `get` and `list` go on reporting the old ports until it
//  restarts. The ports on disk are the ones that apply, and they are what
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
        try PortMapping.validate(mappings)
        let ports = try mappings.map { try $0.publishPort() }
        let bundle = try await bundleDirectory(for: instance.fullName)
        let files = BundleFiles(directory: bundle)

        try await ensureStopped(instance.fullName, files: files)
        if let options: ContainerCreateOptions = try? files.decode(files.options), options.autoRemove {
            throw AgentVMError(
                "\(instance.shortName) is one-shot",
                hint: "It is removed when it stops, so there is nothing to start with new ports.")
        }

        let backup = try files.backUp(into: backupDirectory(for: instance.fullName))
        do {
            if FileManager.default.fileExists(atPath: files.config.path) {
                var configuration: ContainerConfiguration = try files.decode(files.config)
                configuration.publishedPorts = ports
                try files.write(configuration, to: files.config)
            }
            if FileManager.default.fileExists(atPath: files.runtime.path) {
                let runtime: RuntimeConfiguration = try files.decode(files.runtime)
                if var configuration = runtime.containerConfiguration {
                    configuration.publishedPorts = ports
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
            guard try files.ports() == mappings else {
                throw AgentVMError("the ports read back differ from the ports written")
            }
            if FileManager.default.fileExists(atPath: files.runtime.path) {
                let runtime: RuntimeConfiguration = try files.decode(files.runtime)
                if let configuration = runtime.containerConfiguration,
                    configuration.publishedPorts.map(PortMapping.init) != mappings
                {
                    throw AgentVMError("the fallback configuration read back differs from what was written")
                }
            }
        } catch {
            do {
                try files.restore(from: backup)
            } catch let restoreError {
                throw AgentVMError(
                    "could not change the ports of \(instance.shortName), and could not put the old files back",
                    hint: "\(error)\n\nRestore failed: \(restoreError)\nThe originals are in \(backup.path).")
            }
            throw AgentVMError(
                "could not change the ports of \(instance.shortName); nothing was changed",
                hint: "\(error)")
        }
    }

    /// The ports that apply on the next start, read from the bundle. Nil when
    /// the bundle can't be read, so the caller keeps the daemon's copy.
    nonisolated func diskPorts(for fullName: String, in containersRoot: URL?) -> [PortMapping]? {
        guard let containersRoot else { return nil }
        return try? BundleFiles(directory: containersRoot.appendingPathComponent(fullName)).ports()
    }

    // MARK: - Safety

    /// Stopped means: the daemon says so, *and* launchd no longer holds the
    /// runtime helper — the process that owns the VM and the port forwarders.
    private func ensureStopped(_ fullName: String, files: BundleFiles) async throws {
        let snapshot = try await containers.get(id: fullName)
        guard snapshot.status == .stopped else {
            throw AgentVMError(
                "\(fullName) is \(snapshot.status.rawValue)",
                hint: "Stop it first. Ports are read when the VM boots.")
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
        guard let root = await containersRoot() else {
            throw AgentVMError("cannot reach the container system service", hint: "Start it with `container system start`.")
        }
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

    func ports() throws -> [PortMapping] {
        try configuration().publishedPorts.map(PortMapping.init)
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
