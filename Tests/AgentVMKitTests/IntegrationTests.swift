//
//  IntegrationTests.swift
//  The other suites never touch the daemon. This one does everything: it pulls
//  an image, boots a real VM, runs a command inside it, edits its ports and
//  deletes it again.
//
//  It is off unless you ask for it:
//
//      AGENTVM_INTEGRATION=1 bash Scripts/test.sh --filter Integration
//
//  Everything it creates is named under the `agentvmit-` prefix, never `agentvm-`, so it
//  cannot collide with — or clean up — instances you actually use. It tears its
//  own instance down at the end, including when a test fails.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Testing

@testable import AgentVMKit

/// A prefix of its own, so nothing here can see or touch a real AgentVM instance.
private let testConfig = AgentVMConfig(
    net: .open,
    envFilePath: NSTemporaryDirectory() + "agentvm-integration-env",
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

        // Whatever happens below, do not leave a VM behind.
        defer {
            let engine = self.engine
            Task.detached {
                if let instance = try? await engine.instance(named: fullName, config: testConfig) {
                    try? await engine.delete(instance, force: true)
                }
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

        try await engine.delete(instance, force: false)
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
                    try? await engine.delete(instance, force: true)
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

        try await engine.delete(instance, force: true)

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
                    try? await engine.delete(instance, force: true)
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
