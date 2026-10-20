//
//  InstanceLocksTests.swift
//  A lock is a promise that Prune and Delete keep their hands off an instance.
//  So the list must read back exactly as written, a list that can't be read
//  must never pass for an empty one, and Prune's plan must keep every locked
//  instance — and its network — whatever else it removes.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Testing

@testable import AgentVMKit

@Suite("Locks")
struct InstanceLocksTests {

    @discardableResult
    private func withTemporaryLocks<T>(_ body: (InstanceLocks) throws -> T) throws -> T {
        try withTemporaryDirectory {
            try body(InstanceLocks(url: $0.appending(path: "locks", directoryHint: .notDirectory)))
        }
    }

    /// Which file is there: an atomic write puts a new one in place.
    private func fileNumber(of locks: InstanceLocks) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: locks.path)[.systemFileNumber] as? NSNumber)?.intValue
    }

    // MARK: - Reading and writing

    @Test("No lock list means nothing is locked, and looking creates no file")
    func absentListIsEmpty() throws {
        try withTemporaryLocks { locks throws in
            #expect(try locks.names() == [])
            #expect(try locks.isLocked("agentvm-coder") == false)
            #expect(!FileManager.default.fileExists(atPath: locks.path))
        }
    }

    @Test("A lock reads back from a fresh look at the file")
    func lockRoundTrips() throws {
        try withTemporaryLocks { locks in
            try locks.lock("agentvm-coder")
            #expect(try InstanceLocks(url: locks.url).names() == ["agentvm-coder"])
            #expect(try InstanceLocks(url: locks.url).isLocked("agentvm-coder"))
        }
    }

    @Test("Unlocking one leaves the others locked")
    func unlockIsSelective() throws {
        try withTemporaryLocks { locks in
            try locks.lock("agentvm-coder")
            try locks.lock("agentvm-web")
            try locks.unlock("agentvm-coder")
            #expect(try locks.names() == ["agentvm-web"])
        }
    }

    @Test("Locking twice, or unlocking what isn't locked, writes nothing")
    func noChangeNoWrite() throws {
        try withTemporaryLocks { locks in
            try locks.unlock("agentvm-coder")
            #expect(!FileManager.default.fileExists(atPath: locks.path), "nothing to unlock, so no file")

            try locks.lock("agentvm-coder")
            let written = try Data(contentsOf: locks.url)
            let file = try fileNumber(of: locks)
            try locks.lock("agentvm-coder")
            try locks.unlock("agentvm-web")
            #expect(try fileNumber(of: locks) == file, "the same file, not a rewrite of it")
            #expect(try Data(contentsOf: locks.url) == written)
        }
    }

    @Test("The file says what it is, then lists the names one per line, sorted")
    func fileFormat() throws {
        try withTemporaryLocks { locks in
            try locks.lock("agentvm-web")
            try locks.lock("agentvm-coder")
            let text = try String(contentsOf: locks.url, encoding: .utf8)
            #expect(text.hasPrefix("# AgentVM locks."))
            #expect(text.hasSuffix("\nagentvm-coder\nagentvm-web\n"))
        }
    }

    @Test("A list written by hand reads as written: comments, blank lines and stray spaces don't count")
    func handWrittenList() {
        let text = """
            # mine
            agentvm-coder
              agentvm-web   # the site

            #agentvm-old
            \tagentvm-api\r
            """
        #expect(InstanceLocks.parse(text) == ["agentvm-coder", "agentvm-web", "agentvm-api"])
    }

    @Test("A hand edit made in the meantime survives the next lock")
    func keepsHandEdits() throws {
        try withTemporaryLocks { locks in
            try locks.lock("agentvm-coder")
            let edited = try String(contentsOf: locks.url, encoding: .utf8) + "agentvm-web\n"
            try edited.write(to: locks.url, atomically: true, encoding: .utf8)
            try locks.lock("agentvm-api")
            #expect(try locks.names() == ["agentvm-api", "agentvm-coder", "agentvm-web"])
        }
    }

    // MARK: - Failing closed

    @Test("A list that is there but can't be read is an error, never an empty list")
    func unreadableListThrows() throws {
        try withTemporaryLocks { locks in
            // A folder where the file should be.
            try FileManager.default.createDirectory(at: locks.url, withIntermediateDirectories: true)
            #expect(throws: AgentVMError.self) { try locks.names() }
            #expect(throws: AgentVMError.self, "Delete must not take it as unlocked") {
                try locks.ensureUnlocked("agentvm-coder", shortName: "coder")
            }
        }
        try withTemporaryLocks { locks in
            // Not text.
            try Data([0xff, 0xfe, 0x00, 0xd8]).write(to: locks.url)
            #expect(throws: AgentVMError.self) { try locks.names() }
        }
        // A file you may not read stops nobody running as root.
        guard getuid() != 0 else { return }
        try withTemporaryLocks { locks in
            try locks.lock("agentvm-coder")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locks.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locks.path) }
            #expect(throws: AgentVMError.self) { try locks.names() }
            #expect(throws: AgentVMError.self, "a list that can't be read can't be rewritten either") {
                try locks.unlock("agentvm-coder")
            }
        }
    }

    @Test("Delete is refused for a locked instance, and only that one")
    func ensureUnlocked() throws {
        try withTemporaryLocks { locks in
            try locks.lock("agentvm-coder")
            #expect(throws: AgentVMError.self) { try locks.ensureUnlocked("agentvm-coder", shortName: "coder") }
            try locks.ensureUnlocked("agentvm-web", shortName: "web")
            try locks.unlock("agentvm-coder")
            try locks.ensureUnlocked("agentvm-coder", shortName: "coder")
        }
    }

    @Test(
        "A name the file couldn't hold as written is refused",
        arguments: ["", " agentvm-coder", "agentvm-coder ", "agentvm-a\nagentvm-b", "agentvm-#1"])
    func refusesNamesThatBreakTheFile(name: String) throws {
        try withTemporaryLocks { locks throws in
            #expect(throws: AgentVMError.self) { try locks.lock(name) }
            #expect(try locks.names() == [])
        }
    }

    @Test("Prune with an unreadable lock list stops before it asks the daemon for anything")
    func pruneFailsClosed() async throws {
        try await withTemporaryDirectory { directory in
            // A directory where the list should be: there, but no list.
            let lockFile = directory.appending(path: "locks", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: lockFile, withIntermediateDirectories: true)
            // A prefix nothing carries, should it ever get as far as the daemon.
            let config = AgentVMConfig(
                envFilePath: directory.appending(path: "env").path(percentEncoded: false),
                lockFilePath: lockFile.path(percentEncoded: false),
                namePrefix: "agentvmtest-\(UInt32.random(in: 0..<0xffff_ffff))-")

            do {
                _ = try await AgentVMEngine().prune(config: config)
                Issue.record("Prune went ahead without its lock list")
            } catch let error as AgentVMError {
                #expect(error.message.contains("lock list"), "\(error.message)")
            }
        }
    }

    @Test("The lock list lives beside the config file unless told otherwise")
    func defaultLocation() {
        #expect(AgentVMConfig.defaultLockFilePath.hasSuffix("/.config/agentvm/locks"))
        #expect(AgentVMConfig().lockFilePath == AgentVMConfig.defaultLockFilePath)
        #expect(AgentVMConfig(lockFilePath: "/tmp/locks").lockFileURL.path(percentEncoded: false) == "/tmp/locks")
    }
}

@Suite("Prune")
struct PrunePlanTests {
    private let config = AgentVMConfig(namePrefix: "agentvm-")

    @Test("With nothing locked, Prune removes every AgentVM instance and network, as it always did")
    func nothingLocked() {
        let plan = PrunePlan(
            containers: ["agentvm-web", "agentvm-coder", "buildkit"],
            networks: ["agentvm-net-coder", "default"],
            locked: [], config: config)
        #expect(plan.containers == ["agentvm-coder", "agentvm-web"])
        #expect(plan.networks == ["agentvm-net-coder"])
        #expect(plan.kept.isEmpty)
    }

    @Test("Locked instances are kept; the rest of AgentVM's go")
    func keepsLocked() {
        let plan = PrunePlan(
            containers: ["agentvm-coder", "agentvm-scratch", "agentvm-web"],
            locked: ["agentvm-coder", "agentvm-web"], config: config)
        #expect(plan.containers == ["agentvm-scratch"])
        #expect(plan.kept == ["agentvm-coder", "agentvm-web"])
    }

    @Test("A locked killswitch instance keeps its network; every other AgentVM network goes")
    func keepsLockedNetworks() {
        let plan = PrunePlan(
            containers: ["agentvm-coder", "agentvm-scratch"],
            networks: ["agentvm-net-coder", "agentvm-net-scratch", "agentvm-net-orphan", "default"],
            locked: ["agentvm-coder"], config: config)
        #expect(plan.networks == ["agentvm-net-orphan", "agentvm-net-scratch"])
    }

    @Test("With everything locked, there is no instance to remove")
    func allLocked() {
        let plan = PrunePlan(
            containers: ["agentvm-a", "agentvm-b"], networks: ["agentvm-net-a"],
            locked: ["agentvm-a", "agentvm-b"], config: config)
        #expect(plan.containers.isEmpty)
        #expect(plan.networks.isEmpty)
        #expect(plan.kept == ["agentvm-a", "agentvm-b"])
    }

    @Test("Names without the prefix are never in the plan, locked or not")
    func onlyThePrefix() {
        let plan = PrunePlan(
            containers: ["buildkit", "my-db", "agentvm-coder", "agentvmtour-demo"],
            networks: ["default", "my-net", "agentvm-net-coder", "agentvmtour-net-demo"],
            locked: ["my-db"], config: config)
        #expect(plan.containers == ["agentvm-coder"])
        #expect(plan.kept.isEmpty, "a lock on another container is none of Prune's business")
        #expect(plan.networks == ["agentvm-net-coder"])
    }

    @Test("A lock follows the prefix in use: under another one, it's just a name")
    func otherPrefix() {
        let tour = AgentVMConfig(namePrefix: "agentvmtour-")
        let plan = PrunePlan(
            containers: ["agentvm-coder", "agentvmtour-demo", "agentvmtour-offline"],
            networks: ["agentvm-net-coder", "agentvmtour-net-offline"],
            locked: ["agentvm-coder", "agentvmtour-demo"], config: tour)
        #expect(plan.containers == ["agentvmtour-offline"])
        #expect(plan.kept == ["agentvmtour-demo"])
        #expect(plan.networks == ["agentvmtour-net-offline"])
    }
}
