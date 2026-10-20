//
//  AgentVMConfigTests.swift
//  The config file is hand-editable, so loading it must never throw: a line it
//  cannot make sense of becomes a warning and the default stands. Every test
//  here uses a temporary path, so the real ~/.config/agentvm/config is untouched.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Testing

@testable import AgentVMKit

@Suite("AgentVMConfig")
struct AgentVMConfigTests {

    /// A directory that goes away with the test, so nothing leaks into $HOME.
    @discardableResult
    private func withTemporaryConfig<T>(_ body: (URL) throws -> T) throws -> T {
        try withTemporaryDirectory { try body($0.appending(path: "config", directoryHint: .notDirectory)) }
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Defaults

    @Test("The defaults are the documented ones")
    func defaults() {
        let config = AgentVMConfig()
        #expect(config.net == .open)
        #expect(config.removeOnExit == false)
        #expect(config.cpus == nil)
        #expect(config.memory == nil)
        #expect(config.namePrefix == "agentvm-")
        #expect(config.warnings.isEmpty)
    }

    @Test("A missing file is created from the template, and loads as the defaults")
    func createsTemplateWhenAbsent() throws {
        try withTemporaryConfig { url in
            #expect(!FileManager.default.fileExists(atPath: url.path))
            let config = try AgentVMConfig.load(from: url)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(config == AgentVMConfig())

            let text = try String(contentsOf: url, encoding: .utf8)
            for key in ["NET=", "RM=", "CPUS=", "MEMORY=", "ENV_FILE=", "NAME_PREFIX="] {
                #expect(text.contains(key), "the template should mention \(key)")
            }
        }
    }

    // MARK: - Parsing

    @Test("Every key is read")
    func readsEveryKey() throws {
        try withTemporaryConfig { url in
            try write(
                """
                NET=none
                RM=yes
                CPUS=8
                MEMORY=4G
                ENV_FILE=/tmp/agentvm-env
                NAME_PREFIX=box-
                """, to: url)
            let config = try AgentVMConfig.load(from: url)
            #expect(config.net == .killswitch)
            #expect(config.removeOnExit)
            #expect(config.cpus == 8)
            #expect(config.memory == "4G")
            #expect(config.envFilePath == "/tmp/agentvm-env")
            #expect(config.namePrefix == "box-")
            #expect(config.warnings.isEmpty)
        }
    }

    @Test("Comments, blank lines and stray whitespace are ignored")
    func ignoresCommentsAndWhitespace() throws {
        try withTemporaryConfig { url in
            try write(
                """
                # a leading comment

                   NET = none     # trailing comment

                """, to: url)
            let config = try AgentVMConfig.load(from: url)
            #expect(config.net == .killswitch)
            #expect(config.warnings.isEmpty)
        }
    }

    @Test("RM accepts each documented spelling", arguments: [
        ("yes", true), ("y", true), ("1", true), ("true", true), ("YES", true),
        ("no", false), ("n", false), ("0", false), ("false", false),
    ])
    func parsesRemoveOnExit(_ text: String, _ expected: Bool) throws {
        try withTemporaryConfig { url in
            try write("RM=\(text)", to: url)
            let config = try AgentVMConfig.load(from: url)
            #expect(config.removeOnExit == expected)
            #expect(config.warnings.isEmpty)
        }
    }

    @Test("An empty CPUS or MEMORY means the daemon's default, not an error")
    func emptyValuesMeanDaemonDefault() throws {
        try withTemporaryConfig { url in
            try write("CPUS=\nMEMORY=\nENV_FILE=", to: url)
            let config = try AgentVMConfig.load(from: url)
            #expect(config.cpus == nil)
            #expect(config.memory == nil)
            #expect(config.envFilePath == AgentVMConfig.defaultEnvFilePath)
            #expect(config.warnings.isEmpty)
        }
    }

    @Test("A ~ in ENV_FILE is expanded")
    func expandsTildeInEnvFile() throws {
        try withTemporaryConfig { url in
            try write("ENV_FILE=~/somewhere/env", to: url)
            let config = try AgentVMConfig.load(from: url)
            var home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
            while home.count > 1 && home.hasSuffix("/") { home.removeLast() }
            #expect(config.envFilePath == home + "/somewhere/env")
            #expect(!config.envFilePath.hasPrefix("~"))
            #expect(!config.envFilePath.contains("//"), "the home path's trailing slash must not double up")
        }
    }

    // MARK: - Bad input becomes a warning, never a throw

    @Test("A bad value keeps the default and is reported")
    func badValuesWarn() throws {
        try withTemporaryConfig { url in
            try write(
                """
                NET=sideways
                RM=maybe
                CPUS=lots
                NAME_PREFIX=has spaces
                COLOUR=blue
                this line has no equals sign
                """, to: url)
            let config = try AgentVMConfig.load(from: url)

            // Every default survives.
            #expect(config.net == .open)
            #expect(config.removeOnExit == false)
            #expect(config.cpus == nil)
            #expect(config.namePrefix == "agentvm-")

            // And each problem is named.
            #expect(config.warnings.count == 6)
            #expect(config.warnings.contains { $0.contains("NET") })
            #expect(config.warnings.contains { $0.contains("RM") })
            #expect(config.warnings.contains { $0.contains("CPUS") })
            #expect(config.warnings.contains { $0.contains("NAME_PREFIX") })
            #expect(config.warnings.contains { $0.contains("COLOUR") })
            #expect(config.warnings.contains { $0.contains("malformed") })
        }
    }

    @Test("A prefix of the wrong shape is refused, with a warning", arguments: [
        "has spaces", "-leading-dash", "AgentVM/", "AgentVM:",
    ])
    func rejectsBadNamePrefix(_ prefix: String) throws {
        try withTemporaryConfig { url in
            try write("NAME_PREFIX=\(prefix)", to: url)
            let config = try AgentVMConfig.load(from: url)
            #expect(config.namePrefix == "agentvm-")
            #expect(config.warnings.contains { $0.contains("NAME_PREFIX") })
        }
    }

    @Test("An empty prefix means the default, which is no mistake to warn about")
    func emptyNamePrefix() throws {
        try withTemporaryConfig { url in
            try write("NAME_PREFIX=", to: url)
            let config = try AgentVMConfig.load(from: url)
            #expect(config.namePrefix == "agentvm-")
            #expect(config.warnings.isEmpty)
        }
    }

    @Test("A prefix of the right shape is accepted", arguments: [
        "agentvm-", "box_", "a", "A1.2-3_",
    ])
    func acceptsGoodNamePrefix(_ prefix: String) throws {
        try withTemporaryConfig { url in
            try write("NAME_PREFIX=\(prefix)", to: url)
            let config = try AgentVMConfig.load(from: url)
            #expect(config.namePrefix == prefix)
            #expect(config.warnings.isEmpty)
        }
    }

    // MARK: - Saving

    @Test("Saving and loading again gives back the same settings")
    func saveRoundTrips() throws {
        try withTemporaryConfig { url in
            var config = AgentVMConfig()
            config.net = .killswitch
            config.removeOnExit = true
            config.cpus = 2
            config.memory = "512M"
            config.namePrefix = "box-"
            config.envFilePath = "/tmp/agentvm-round-trip"
            try config.save(to: url)

            let loaded = try AgentVMConfig.load(from: url)
            #expect(loaded == config)
        }
    }

    @Test("Saving creates the directory it needs")
    func saveCreatesDirectory() throws {
        try withTemporaryConfig { url in
            let nested = url.deletingLastPathComponent()
                .appending(path: "a/b/c", directoryHint: .isDirectory)
                .appending(path: "config", directoryHint: .notDirectory)
            try AgentVMConfig().save(to: nested)
            #expect(FileManager.default.fileExists(atPath: nested.path))
        }
    }

    // MARK: - Names

    @Test("A full name gives its short name, and a foreign one is left alone")
    func nameConversion() {
        let config = AgentVMConfig()
        #expect(config.shortName("agentvm-coder") == "coder")
        #expect(config.shortName("other") == "other", "a foreign name is left alone")
    }

    @Test("Only prefixed names are recognized as ours")
    func recognizesOwnNames() {
        var config = AgentVMConfig()
        #expect(config.isAgentVMName("agentvm-coder"))
        #expect(!config.isAgentVMName("postgres"))

        config.namePrefix = "box-"
        #expect(config.isAgentVMName("box-coder"))
        #expect(!config.isAgentVMName("agentvm-coder"), "a renamed prefix stops claiming the old one")
    }

    @Test("A killswitch network is named after its instance, under the prefix")
    func networkNaming() {
        let config = AgentVMConfig()
        #expect(config.networkName(for: "agentvm-coder") == "agentvm-net-coder")
        #expect(config.isAgentVMNetworkName("agentvm-net-coder"))
        #expect(!config.isAgentVMNetworkName("agentvm-coder"), "an instance name is not a network name")
        #expect(!config.isAgentVMNetworkName("bridge"))
    }

    // MARK: - Postures

    @Test("Both postures survive their file spelling")
    func posturesRoundTrip() {
        #expect(NetPosture(rawValue: "open") == .open)
        #expect(NetPosture(rawValue: "none") == .killswitch)
        #expect(NetPosture(rawValue: "killswitch") == nil, "the file spells it 'none'")
        for posture in NetPosture.allCases {
            #expect(!posture.summary.isEmpty)
        }
    }

    // MARK: - Migration from sbx

    /// A fake home with the given files under it, removed afterwards.
    private func withHome(_ files: [String: String], _ body: (URL) throws -> Void) throws {
        try withTemporaryDirectory { home in
            for (path, text) in files {
                let url = home.appending(path: path, directoryHint: .notDirectory)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try write(text, to: url)
            }
            try body(home)
        }
    }

    private func read(_ path: String, in home: URL) -> String? {
        try? String(contentsOf: home.appending(path: path, directoryHint: .notDirectory), encoding: .utf8)
    }

    @Test("An sbx config and registry are carried over, with sbx's defaults switched to AgentVM's")
    func migratesFromSbx() throws {
        try withHome([
            ".config/sbx/config": "NET=none\nCPUS=6\nENV_FILE=~/.config/sbx/env\nNAME_PREFIX=sbx-\n",
            ".config/sbx/env": "API_KEY=abc\n",
        ]) { home in
            AgentVMConfig.migrateLegacy(home: home)
            let config = try #require(read(".config/agentvm/config", in: home))
            #expect(config.contains("NET=none"))
            #expect(config.contains("CPUS=6"))
            #expect(config.contains("NAME_PREFIX=agentvm-"))
            #expect(config.contains("ENV_FILE=\(home.path(percentEncoded: false)).config/agentvm/env"))
            #expect(read(".config/agentvm/env", in: home) == "API_KEY=abc\n")
            let envPath = home.appending(path: ".config/agentvm/env").path(percentEncoded: false)
            let mode = try FileManager.default.attributesOfItem(atPath: envPath)[.posixPermissions] as? Int
            #expect(mode == 0o600)
            #expect(read(".config/sbx/config", in: home) != nil, "the old files are copied, not moved")
        }
    }

    @Test("Values you set yourself survive the migration")
    func migrationKeepsCustomValues() throws {
        try withHome([".config/sbx/config": "ENV_FILE=/secrets/env\nNAME_PREFIX=box-\n"]) { home in
            AgentVMConfig.migrateLegacy(home: home)
            let config = try #require(read(".config/agentvm/config", in: home))
            #expect(config.contains("ENV_FILE=/secrets/env"))
            #expect(config.contains("NAME_PREFIX=box-"))
        }
    }

    @Test("An existing AgentVM config is never overwritten")
    func migrationRunsOnce() throws {
        try withHome([
            ".config/sbx/config": "NET=none\n",
            ".config/agentvm/config": "NET=open\n",
        ]) { home in
            AgentVMConfig.migrateLegacy(home: home)
            #expect(read(".config/agentvm/config", in: home) == "NET=open\n")
        }
    }
}
