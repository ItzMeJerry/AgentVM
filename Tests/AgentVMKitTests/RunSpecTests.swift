//
//  RunSpecTests.swift
//  What a new instance is allowed to be. The mount rules are the security
//  boundary the README promises — "only the directories you name" — so the two
//  mounts that would hand over the whole machine are tested by name.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Testing

@testable import AgentVMKit

@Suite("MountSpec")
struct MountSpecTests {

    // MARK: - Accepted

    @Test("An existing directory with an absolute target is accepted")
    func acceptsDirectoryMount() throws {
        try withTemporaryDirectory { directory in
            let mount = try MountSpec(hostPath: directory.path, guestPath: "/work").validated()
            #expect(mount.guestPath == "/work")
            #expect(!mount.readOnly)
        }
    }

    @Test("The host path comes back canonical, with symlinks resolved")
    func resolvesSymlinks() throws {
        try withTemporaryDirectory { directory in
            let real = directory.appending(path: "real", directoryHint: .isDirectory)
            let link = directory.appending(path: "link", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

            let mount = try MountSpec(hostPath: link.path, guestPath: "/work").validated()
            #expect(mount.hostPath.hasSuffix("/real"))
            #expect(!mount.hostPath.contains("/link"))
        }
    }

    // MARK: - Refused

    @Test("Mounting $HOME is refused, however it is spelled")
    func refusesHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        // Foundation hands back a directory URL's path with a trailing slash and
        // an expanded ~ without one. Every spelling has to be caught, or the
        // refusal is one string comparison away from never firing.
        for spelling in [home, home + "/", "~", "~/", String(home.dropLast())] {
            #expect(throws: (any Error).self, "mounting \(spelling) should be refused") {
                try MountSpec(hostPath: spelling, guestPath: "/home").validated()
            }
        }
    }

    @Test("Mounting / is refused with or without a trailing slash")
    func refusesRootAnySpelling() {
        for spelling in ["/", "//"] {
            #expect(throws: (any Error).self) {
                try MountSpec(hostPath: spelling, guestPath: "/host").validated()
            }
        }
    }

    @Test("A directory just inside $HOME is still allowed")
    func allowsDirectoryInsideHome() throws {
        let inside = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "agentvm-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: inside) }

        let mount = try MountSpec(hostPath: inside.path, guestPath: "/work").validated()
        #expect(mount.guestPath == "/work")
    }

    @Test("Canonicalization drops a trailing slash but never empties the path")
    func canonicalDirectoryPath() {
        #expect(MountSpec.canonicalDirectoryPath("/") == "/")
        #expect(MountSpec.canonicalDirectoryPath("//") == "/")
        #expect(MountSpec.canonicalDirectoryPath("/usr/") == "/usr")
        #expect(MountSpec.canonicalDirectoryPath("/usr") == "/usr")
        #expect(MountSpec.canonicalDirectoryPath("/usr///") == "/usr")
    }

    @Test("A relative guest path is refused — the target must be absolute")
    func refusesRelativeGuestPath() throws {
        try withTemporaryDirectory { directory in
            #expect(throws: (any Error).self) {
                try MountSpec(hostPath: directory.path, guestPath: "work").validated()
            }
        }
    }

    @Test("An empty host or guest path is refused")
    func refusesEmptyPaths() throws {
        try withTemporaryDirectory { directory in
            #expect(throws: (any Error).self) {
                try MountSpec(hostPath: "", guestPath: "/work").validated()
            }
            #expect(throws: (any Error).self) {
                try MountSpec(hostPath: directory.path, guestPath: "").validated()
            }
        }
    }

    @Test("A comma is refused — it separates the fields of the mount argument")
    func refusesComma() throws {
        try withTemporaryDirectory { directory in
            let commaDirectory = directory.appending(path: "a,b", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: commaDirectory, withIntermediateDirectories: true)
            #expect(throws: (any Error).self) {
                try MountSpec(hostPath: commaDirectory.path, guestPath: "/work").validated()
            }
            #expect(throws: (any Error).self) {
                try MountSpec(hostPath: directory.path, guestPath: "/wo,rk").validated()
            }
        }
    }

    @Test("A path that does not exist is refused")
    func refusesMissingPath() throws {
        try withTemporaryDirectory { directory in
            #expect(throws: (any Error).self) {
                try MountSpec(hostPath: directory.appending(path: "nope").path, guestPath: "/work").validated()
            }
        }
    }

    @Test("A file is refused — mounts are directories")
    func refusesFile() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appending(path: "a-file", directoryHint: .notDirectory)
            try Data().write(to: file)
            #expect(throws: (any Error).self) {
                try MountSpec(hostPath: file.path, guestPath: "/work").validated()
            }
        }
    }

    // MARK: - The argument the API takes

    @Test("The mount argument carries source, target and read-only")
    func buildsMountArgument() {
        let writable = MountSpec(hostPath: "/src", guestPath: "/work")
        #expect(writable.mountArgument == "type=bind,source=/src,target=/work")

        let readOnly = MountSpec(hostPath: "/src", guestPath: "/work", readOnly: true)
        #expect(readOnly.mountArgument == "type=bind,source=/src,target=/work,readonly")
    }
}

@Suite("AgentVMNaming")
struct AgentVMNamingTests {

    @Test("A well-formed name is accepted", arguments: [
        "coder", "build-x86", "a", "A", "0", "my.box_1",
    ])
    func acceptsValidName(_ name: String) throws {
        try AgentVMNaming.validateShortName(name, posture: .open)
    }

    @Test("A malformed name is refused", arguments: [
        "", "-leading", ".leading", "_leading", "has space", "has/slash", "has:colon",
        String(repeating: "a", count: 64),
    ])
    func refusesInvalidName(_ name: String) {
        #expect(throws: (any Error).self) {
            try AgentVMNaming.validateShortName(name, posture: .open)
        }
    }

    @Test("63 characters is the limit, and it is inclusive")
    func nameLengthLimit() throws {
        try AgentVMNaming.validateShortName(String(repeating: "a", count: 63), posture: .open)
        #expect(throws: (any Error).self) {
            try AgentVMNaming.validateShortName(String(repeating: "a", count: 64), posture: .open)
        }
    }

    @Test("An uppercase name is fine on the open posture but not with the killswitch")
    func killswitchRequiresLowercase() throws {
        try AgentVMNaming.validateShortName("Coder", posture: .open)
        #expect(
            throws: (any Error).self,
            "a killswitch instance needs a network of its own, and network names are lowercase"
        ) {
            try AgentVMNaming.validateShortName("Coder", posture: .killswitch)
        }
        try AgentVMNaming.validateShortName("coder", posture: .killswitch)
    }

    @Test("A random name carries the prefix and eight hex digits")
    func randomNameShape() {
        let name = AgentVMNaming.randomName(prefix: "agentvm-")
        #expect(name.hasPrefix("agentvm-"))
        let hex = name.dropFirst("agentvm-".count)
        #expect(hex.count == 8)
        let isHex = hex.allSatisfy(\.isHexDigit)
        #expect(isHex)
        // And it is valid as a name in its own right, on either posture.
        #expect(throws: Never.self) {
            try AgentVMNaming.validateShortName(String(hex), posture: .killswitch)
        }
    }

    @Test("Random names differ")
    func randomNamesDiffer() {
        let names = Set((0..<64).map { _ in AgentVMNaming.randomName(prefix: "agentvm-") })
        #expect(names.count > 60, "8 hex digits should not collide this often")
    }
}

@Suite("RunSpec")
struct RunSpecTests {

    @Test("A fresh spec is an instance on the open network")
    func defaults() {
        let spec = RunSpec()
        #expect(spec.mode == .instance)
        #expect(spec.net == .open)
        #expect(spec.useRegistry)
        #expect(!spec.rosetta)
        #expect(!spec.removeOnExit)
        #expect(spec.command.isEmpty)
        #expect(spec.mounts.isEmpty)
    }

    @Test("A spec built from the config inherits its defaults")
    func inheritsConfigDefaults() {
        var config = AgentVMConfig()
        config.net = .killswitch
        config.cpus = 8
        config.memory = "4G"
        config.removeOnExit = true

        let spec = RunSpec(config: config)
        #expect(spec.net == .killswitch)
        #expect(spec.cpus == 8)
        #expect(spec.memory == "4G")
        #expect(spec.removeOnExit)
        #expect(spec.mode == .instance, "the config does not choose the mode")
    }

    @Test("Both modes describe themselves")
    func modesHaveSummaries() {
        for mode in AgentVMMode.allCases {
            #expect(!mode.summary.isEmpty)
            #expect(AgentVMMode(rawValue: mode.rawValue) == mode)
        }
    }
}
