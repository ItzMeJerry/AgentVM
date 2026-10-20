//
//  IntegrationTests.swift
//  The other suites never touch the daemon. This one does everything: it pulls
//  an image, boots a real VM, runs a command inside it, edits its ports and its
//  main process, and deletes it again.
//
//  It is off unless you ask for it:
//
//      AGENTVM_INTEGRATION=1 bash Scripts/test.sh --filter Integration
//
//  Everything it creates is named under the `agentvmit-` prefix, never `agentvm-`, so it
//  cannot collide with — or clean up — instances you actually use; even its Prune
//  only ever sees that prefix. Its locks go in a list of its own. It tears its own
//  instances down at the end, including when a test fails.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Testing

@testable import AgentVMKit

/// A prefix of its own, so nothing here can see or touch a real AgentVM instance,
/// and a lock list of its own, so nothing here reads or writes yours.
private let testConfig = AgentVMConfig(
    net: .open,
    envFilePath: NSTemporaryDirectory() + "agentvm-integration-env",
    lockFilePath: NSTemporaryDirectory() + "agentvm-integration-locks",
    namePrefix: "agentvmit-")

/// Small, arm64-native, and quick to pull.
private let testImage = "alpine:3.20"

private var integrationEnabled: Bool {
    ProcessInfo.processInfo.environment["AGENTVM_INTEGRATION"] == "1"
}

@Suite(
    "Integration",
    .serialized,
    .enabled(if: integrationEnabled, "set AGENTVM_INTEGRATION=1 to run against a real daemon"),
    .timeLimit(.minutes(10))
)
struct IntegrationTests {

    private let engine = AgentVMEngine()

    // MARK: - Preflight

    @Test("The daemon answers a health check")
    func daemonIsReachable() async throws {
        let status = await engine.daemonStatus()
        #expect(status.running, "start it with `container system start`: \(status.message ?? "")")
        #expect(status.appRoot != nil)
    }

    // MARK: - The whole life of an instance

    @Test("An instance boots, runs a command, changes its ports and goes away")
    func instanceLifecycle() async throws {
        let status = await engine.daemonStatus()
        try #require(status.running, "the daemon is not running")

        let name = "life-\(UInt32.random(in: 0..<0xffff_ffff))"
        let fullName = testConfig.namePrefix + name

        // Whatever happens below, do not leave a VM behind, or its backups.
        defer {
            let engine = self.engine
            Task.detached {
                if let instance = try? await engine.instance(named: fullName, config: testConfig) {
                    try? await engine.delete(instance, force: true, config: testConfig)
                }
                removeBackups(of: fullName)
            }
        }

        // --- create -------------------------------------------------------

        var spec = RunSpec(config: testConfig)
        spec.image = testImage
        spec.name = name
        spec.mode = .instance
        spec.useRegistry = false

        // The progress callback is @Sendable and arrives off this task.
        let stages = Recorded()
        let created = try await engine.create(spec: spec, config: testConfig) { stage in
            stages.append(stage)
        }
        #expect(created == fullName)
        #expect(!stages.values.isEmpty, "create should report its progress")

        // --- it is there, and running ------------------------------------

        var instance = try await engine.instance(named: fullName, config: testConfig)
        #expect(instance.isRunning, "a fresh instance should be running, not \(instance.stateLabel)")
        #expect(instance.mode == .instance)
        #expect(instance.net == .open)
        #expect(instance.shortName == name)
        #expect(instance.ports.isEmpty, "nothing was published at creation")
        #expect(instance.ipv4 != nil, "an open instance has an address")
        #expect(!instance.isOneShot && instance.canLock, "an instance stays until deleted, so it can be locked")

        let listed = try await engine.list(config: testConfig)
        #expect(listed.contains { $0.fullName == fullName })

        // --- a shell session, which is a process of its own ---------------

        let output = try await runInSession(instance, command: ["/bin/sh", "-c", "echo agentvm-ok"])
        #expect(output.contains("agentvm-ok"), "the session produced: \(output.debugDescription)")

        // The session ending must not have stopped the instance: that is the
        // whole point of the keepalive.
        instance = try await engine.instance(named: fullName, config: testConfig)
        #expect(instance.isRunning, "a finished session must never stop the instance")

        // --- logs ---------------------------------------------------------

        let handle = try await engine.logHandle(for: fullName, boot: false)
        #expect(handle.fileDescriptor >= 0)
        try? handle.close()

        // --- ports, which need it stopped ---------------------------------

        #expect(!instance.canEditPorts, "a running instance may not have its ports changed")
        await #expect(throws: (any Error).self) {
            try await self.engine.setPorts([try PortMapping.parse("18080:80")], on: instance)
        }

        try await engine.stop(instance)
        instance = try await waitFor(fullName, state: "stopped")
        #expect(instance.canEditPorts)
        #expect(instance.ipv4 == nil, "a stopped instance has no VM, so no address")

        // launchd may still hold the runtime helper for a moment after the
        // daemon calls it stopped; setPorts refuses until it lets go.
        try await retrying(for: .seconds(30)) {
            try await self.engine.setPorts([try PortMapping.parse("18080:80")], on: instance)
        }

        instance = try await engine.instance(named: fullName, config: testConfig)
        #expect(instance.ports.count == 1)
        #expect(instance.ports.first?.hostPort == 18080)
        #expect(instance.ports.first?.containerPort == 80)
        #expect(instance.ports.first?.hostAddress == "127.0.0.1", "no address means this Mac only")

        // --- start again, with the new ports ------------------------------

        try await engine.start(instance)
        instance = try await waitFor(fullName, state: "running")
        #expect(instance.ports.first?.hostPort == 18080, "the new ports survive a boot")

        // --- and clearing them again --------------------------------------

        try await engine.stop(instance)
        instance = try await waitFor(fullName, state: "stopped")
        try await retrying(for: .seconds(30)) {
            try await self.engine.setPorts([], on: instance)
        }
        instance = try await engine.instance(named: fullName, config: testConfig)
        #expect(instance.ports.isEmpty)

        // --- delete -------------------------------------------------------

        try await engine.delete(instance, force: false, config: testConfig)
        await #expect(throws: (any Error).self, "it should be gone") {
            _ = try await self.engine.instance(named: fullName, config: testConfig)
        }
        let remaining = try await engine.list(config: testConfig)
        #expect(!remaining.contains { $0.fullName == fullName })
    }

    // MARK: - The killswitch

    @Test("A killswitch instance gets a host-only network of its own, and loses it on delete")
    func killswitchNetworkLifecycle() async throws {
        let status = await engine.daemonStatus()
        try #require(status.running, "the daemon is not running")

        let name = "ks-\(UInt32.random(in: 0..<0xffff_ffff))"
        let fullName = testConfig.namePrefix + name
        let networkName = testConfig.networkName(for: fullName)

        defer {
            let engine = self.engine
            Task.detached {
                if let instance = try? await engine.instance(named: fullName, config: testConfig) {
                    try? await engine.delete(instance, force: true, config: testConfig)
                }
            }
        }

        var spec = RunSpec(config: testConfig)
        spec.image = testImage
        spec.name = name
        spec.net = .killswitch
        spec.mode = .instance
        spec.useRegistry = false

        _ = try await engine.create(spec: spec, config: testConfig)

        let instance = try await engine.instance(named: fullName, config: testConfig)
        #expect(instance.net == .killswitch)
        #expect(instance.networkName == networkName)
        #expect(await engine.networkExists(networkName), "the killswitch network should exist")

        let owned = try await engine.agentVMNetworkNames(config: testConfig)
        #expect(owned.contains(networkName))

        // Off the network: no resolver, and no route off this Mac.
        let resolv = try await runInSession(
            instance, command: ["/bin/sh", "-c", "cat /etc/resolv.conf 2>/dev/null; echo END"])
        #expect(resolv.contains("END"), "the session should have run")

        try await engine.delete(instance, force: true, config: testConfig)

        // The network goes with it — though the daemon may take a moment.
        var gone = false
        for _ in 0..<20 {
            if await !engine.networkExists(networkName) {
                gone = true
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(gone, "\(networkName) should have been removed with its instance")
    }

    // MARK: - The main process

    @Test("A stopped instance's main process can change, and its next start runs the new one")
    func mainProcessChanges() async throws {
        let status = await engine.daemonStatus()
        try #require(status.running, "the daemon is not running")

        let name = "main-\(UInt32.random(in: 0..<0xffff_ffff))"
        let fullName = testConfig.namePrefix + name

        defer {
            let engine = self.engine
            Task.detached {
                if let instance = try? await engine.instance(named: fullName, config: testConfig) {
                    try? await engine.delete(instance, force: true, config: testConfig)
                }
                removeBackups(of: fullName)
            }
        }

        var spec = RunSpec(config: testConfig)
        spec.image = testImage
        spec.name = name
        spec.mode = .instance
        spec.useRegistry = false
        _ = try await engine.create(spec: spec, config: testConfig)

        var instance = try await engine.instance(named: fullName, config: testConfig)
        #expect(instance.mode == .instance)
        #expect(instance.command == MainProcess.keepalive.command)

        // The shell does the sum, so the line in the log can only come from
        // the new command having run.
        let task = try MainProcess(mode: .task, command: ["/bin/sh", "-c", "echo agentvm-main-$((6 * 7))"])

        #expect(!instance.canChangeMainProcess, "the main process is read at boot, so not while it runs")
        await #expect(throws: (any Error).self) {
            try await self.engine.setMainProcess(task, on: instance)
        }

        try await engine.stop(instance)
        instance = try await waitFor(fullName, state: "stopped")
        try await retrying(for: .seconds(30)) {
            try await self.engine.setMainProcess(task, on: instance)
        }

        instance = try await engine.instance(named: fullName, config: testConfig)
        #expect(instance.mode == .task, "a command makes it a task")
        #expect(instance.command == task.command)

        // Started, it runs the new command, which finishes, so it stops again.
        try await engine.start(instance)
        instance = try await waitFor(fullName, state: "stopped")
        var log = ""
        for _ in 0..<20 {
            let handle = try await engine.logHandle(for: fullName, boot: false)
            log = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
            try? handle.close()
            if log.contains("agentvm-main-42") { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(log.contains("agentvm-main-42"), "the instance's log holds: \(log.debugDescription)")

        // And back: the keepalive makes it an instance that runs until stopped.
        try await retrying(for: .seconds(30)) {
            try await self.engine.setMainProcess(.keepalive, on: instance)
        }
        instance = try await engine.instance(named: fullName, config: testConfig)
        #expect(instance.mode == .instance)
        #expect(instance.command == MainProcess.keepalive.command)

        try await engine.start(instance)
        _ = try await waitFor(fullName, state: "running")
        try await Task.sleep(for: .seconds(3))
        instance = try await engine.instance(named: fullName, config: testConfig)
        #expect(instance.isRunning, "the keepalive should still be running")
    }

    // MARK: - Locks

    @Test("A locked instance outlasts Prune, network and all, and Delete waits until it's unlocked")
    func locksHold() async throws {
        let status = await engine.daemonStatus()
        try #require(status.running, "the daemon is not running")

        let locks = InstanceLocks(url: testConfig.lockFileURL)
        try? FileManager.default.removeItem(at: testConfig.lockFileURL)
        let tag = UInt32.random(in: 0..<0xffff_ffff)
        let keptName = testConfig.namePrefix + "keep-\(tag)"
        let goneName = testConfig.namePrefix + "gone-\(tag)"
        let keptNetwork = testConfig.networkName(for: keptName)

        defer {
            let engine = self.engine
            Task.detached {
                try? locks.unlock(keptName)
                for name in [keptName, goneName] {
                    if let instance = try? await engine.instance(named: name, config: testConfig) {
                        try? await engine.delete(instance, force: true, config: testConfig)
                    }
                }
            }
        }

        // One to keep — on the killswitch, so it has a network to keep too —
        // and one to lose.
        var spec = RunSpec(config: testConfig)
        spec.image = testImage
        spec.mode = .instance
        spec.useRegistry = false
        spec.name = "keep-\(tag)"
        spec.net = .killswitch
        _ = try await engine.create(spec: spec, config: testConfig)
        spec.name = "gone-\(tag)"
        spec.net = .open
        _ = try await engine.create(spec: spec, config: testConfig)

        try locks.lock(keptName)
        var kept = try await engine.instance(named: keptName, config: testConfig)

        await #expect(throws: (any Error).self, "Delete should refuse a locked instance, forced or not") {
            try await self.engine.delete(kept, force: true, config: testConfig)
        }

        let result = try await engine.prune(config: testConfig)
        #expect(result.kept == [keptName])
        #expect(result.containers.contains(goneName))
        #expect(!result.containers.contains(keptName))
        #expect(!result.networks.contains(keptNetwork))

        let remaining = try await engine.list(config: testConfig).map(\.fullName)
        #expect(remaining.contains(keptName), "the locked instance should have outlasted Prune")
        #expect(!remaining.contains(goneName), "the unlocked one should be gone")
        #expect(await engine.networkExists(keptNetwork), "its killswitch network should have stayed with it")
        kept = try await engine.instance(named: keptName, config: testConfig)
        #expect(kept.isRunning, "Prune should not so much as have stopped it")

        // Unlocked, it goes like any other.
        try locks.unlock(keptName)
        try await engine.delete(kept, force: true, config: testConfig)
        await #expect(throws: (any Error).self, "it should be gone") {
            _ = try await self.engine.instance(named: keptName, config: testConfig)
        }
    }

    @Test("A new instance starts unlocked, even under a name an old lock still lists")
    func newInstanceStartsUnlocked() async throws {
        let status = await engine.daemonStatus()
        try #require(status.running, "the daemon is not running")

        let locks = InstanceLocks(url: testConfig.lockFileURL)
        let name = "reborn-\(UInt32.random(in: 0..<0xffff_ffff))"
        let fullName = testConfig.namePrefix + name

        defer {
            let engine = self.engine
            Task.detached {
                try? locks.unlock(fullName)
                if let instance = try? await engine.instance(named: fullName, config: testConfig) {
                    try? await engine.delete(instance, force: true, config: testConfig)
                }
            }
        }

        // As if a locked instance had been removed in Terminal, behind
        // AgentVM's back, leaving its lock behind.
        try locks.lock(fullName)

        var spec = RunSpec(config: testConfig)
        spec.image = testImage
        spec.name = name
        spec.mode = .instance
        spec.useRegistry = false
        _ = try await engine.create(spec: spec, config: testConfig)

        #expect(try locks.isLocked(fullName) == false, "the old lock must not carry over to a new instance")
    }

    @Test("A one-shot task is known as one, and can't be locked")
    func oneShotIsRecognised() async throws {
        let status = await engine.daemonStatus()
        try #require(status.running, "the daemon is not running")

        let name = "once-\(UInt32.random(in: 0..<0xffff_ffff))"
        let fullName = testConfig.namePrefix + name

        defer {
            let engine = self.engine
            Task.detached {
                if let instance = try? await engine.instance(named: fullName, config: testConfig) {
                    try? await engine.delete(instance, force: true, config: testConfig)
                }
            }
        }

        var spec = RunSpec(config: testConfig)
        spec.image = testImage
        spec.name = name
        spec.mode = .task
        spec.command = ["sleep", "120"]
        spec.removeOnExit = true
        spec.useRegistry = false
        _ = try await engine.create(spec: spec, config: testConfig)

        let instance = try await engine.instance(named: fullName, config: testConfig)
        #expect(instance.isOneShot, "the bundle's options say the daemon removes it as it stops")
        #expect(!instance.canLock)
    }

    // MARK: - Refusals, against the real daemon

    @Test("A name already taken is refused rather than silently reused")
    func refusesDuplicateName() async throws {
        let status = await engine.daemonStatus()
        try #require(status.running, "the daemon is not running")

        let name = "dup-\(UInt32.random(in: 0..<0xffff_ffff))"
        let fullName = testConfig.namePrefix + name

        defer {
            let engine = self.engine
            Task.detached {
                if let instance = try? await engine.instance(named: fullName, config: testConfig) {
                    try? await engine.delete(instance, force: true, config: testConfig)
                }
            }
        }

        var spec = RunSpec(config: testConfig)
        spec.image = testImage
        spec.name = name
        spec.useRegistry = false
        _ = try await engine.create(spec: spec, config: testConfig)

        await #expect(throws: (any Error).self) {
            _ = try await self.engine.create(spec: spec, config: testConfig)
        }
    }

    @Test("A task with no command is refused before anything is created")
    func refusesTaskWithoutCommand() async throws {
        var spec = RunSpec(config: testConfig)
        spec.image = testImage
        spec.mode = .task
        spec.command = []
        await #expect(throws: (any Error).self) {
            _ = try await self.engine.create(spec: spec, config: testConfig)
        }
    }

    @Test("A one-shot instance is refused — its keepalive would never exit")
    func refusesOneShotInstance() async throws {
        var spec = RunSpec(config: testConfig)
        spec.image = testImage
        spec.mode = .instance
        spec.removeOnExit = true
        await #expect(throws: (any Error).self) {
            _ = try await self.engine.create(spec: spec, config: testConfig)
        }
    }

    // MARK: - Helpers

    /// Runs one command in a session and returns everything it printed.
    private func runInSession(_ instance: AgentVMInstance, command: [String]) async throws -> String {
        let session = try await engine.openSession(
            in: instance, command: command, workingDirectory: nil, environment: [])
        let collected = Collected()
        try await session.start(
            on: DispatchQueue(label: "agentvmit.session"),
            onOutput: { collected.append($0) },
            onEOF: { collected.finish() })
        _ = await session.wait()
        // The reader thread may still be draining when wait() returns.
        for _ in 0..<40 where !collected.isFinished {
            try await Task.sleep(for: .milliseconds(100))
        }
        session.terminate()
        return collected.text
    }

    /// Polls until the instance reports the state, or gives up.
    private func waitFor(_ fullName: String, state: String) async throws -> AgentVMInstance {
        for _ in 0..<120 {
            let instance = try await engine.instance(named: fullName, config: testConfig)
            if instance.stateLabel == state { return instance }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw AgentVMError("\(fullName) never reached '\(state)'")
    }

    /// Retries while the daemon is still letting go of something.
    private func retrying(for duration: Duration, _ body: () async throws -> Void) async throws {
        let deadline = ContinuousClock.now + duration
        while true {
            do {
                try await body()
                return
            } catch {
                if ContinuousClock.now >= deadline { throw error }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}

/// Changing ports or the main process backs up the bundle under the real
/// ~/.config/agentvm/backups. A test's own backups go with its instance.
private func removeBackups(of fullName: String) {
    let backups = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/agentvm/backups", isDirectory: true)
        .appendingPathComponent(fullName, isDirectory: true)
    try? FileManager.default.removeItem(at: backups)
}

/// Progress lines arriving from whichever task the daemon client is on.
private final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

/// Output arriving on the session's reader thread.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false

    func append(_ chunk: [UInt8]) {
        lock.lock()
        data.append(contentsOf: chunk)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
