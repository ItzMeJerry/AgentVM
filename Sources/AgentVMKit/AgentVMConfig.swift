//
//  AgentVMConfig.swift
//  ~/.config/agentvm/config — the same plain KEY=VALUE file the shell version read,
//  re-read on demand and writable from the Settings window.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// Network posture, fixed at creation and recorded on the container as the
/// `agentvm.net` label.
public enum NetPosture: String, Sendable, CaseIterable, Identifiable, Codable {
    /// The daemon's built-in bridge network: direct IP both ways, internet via NAT.
    case open = "open"
    /// The killswitch: a dedicated host-only network, no DNS, no egress.
    case killswitch = "none"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .open: "open"
        case .killswitch: "none"
        }
    }

    public var summary: String {
        switch self {
        case .open: "Direct IP both ways (host ↔ instance) plus internet egress via NAT."
        case .killswitch: "Dedicated host-only network, no DNS, no route off the host."
        }
    }
}

public struct AgentVMConfig: Sendable, Equatable {
    public var net: NetPosture
    /// `RM` — one-shot: remove the instance when its command exits.
    public var removeOnExit: Bool
    /// Empty = the daemon's own default (4).
    public var cpus: Int?
    /// Empty = the daemon's own default (1 GiB). Suffixes: K M G T P.
    public var memory: String?
    public var envFilePath: String
    public var namePrefix: String

    /// Lines the file had that we did not recognize, surfaced in Settings.
    public var warnings: [String]

    public static let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/agentvm/config", directoryHint: .notDirectory)

    public static let defaultEnvFilePath = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/agentvm/env", directoryHint: .notDirectory).path(percentEncoded: false)

    public init(
        net: NetPosture = .open,
        removeOnExit: Bool = false,
        cpus: Int? = nil,
        memory: String? = nil,
        envFilePath: String = AgentVMConfig.defaultEnvFilePath,
        namePrefix: String = "agentvm-",
        warnings: [String] = []
    ) {
        self.net = net
        self.removeOnExit = removeOnExit
        self.cpus = cpus
        self.memory = memory
        self.envFilePath = envFilePath
        self.namePrefix = namePrefix
        self.warnings = warnings
    }

    public var envFileURL: URL { URL(filePath: envFilePath) }

    // MARK: - Names

    /// `coder` → `agentvm-coder`; an already-prefixed name passes through.
    public func fullName(_ name: String) -> String {
        name.hasPrefix(namePrefix) ? name : namePrefix + name
    }

    /// `agentvm-coder` → `coder`.
    public func shortName(_ name: String) -> String {
        name.hasPrefix(namePrefix) ? String(name.dropFirst(namePrefix.count)) : name
    }

    public func isAgentVMName(_ name: String) -> Bool { name.hasPrefix(namePrefix) }

    /// The dedicated internal network for a killswitch instance.
    public func networkName(for fullName: String) -> String {
        "\(namePrefix)net-\(shortName(fullName))"
    }

    public func isAgentVMNetworkName(_ name: String) -> Bool { name.hasPrefix("\(namePrefix)net-") }

    // MARK: - Loading

    /// Reads the config file, creating it from the template when absent. Never
    /// throws on a malformed line: unknown or unparsable lines land in `warnings`.
    public static func load(from url: URL = AgentVMConfig.defaultPath) throws -> AgentVMConfig {
        migrateLegacyConfig(to: url)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try writeTemplate(to: url)
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var config = AgentVMConfig()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.prefix(while: { $0 != "#" }).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let eq = line.firstIndex(of: "="),
                line[line.startIndex].isLetter || line[line.startIndex] == "_"
            else {
                config.warnings.append("ignoring malformed line: \(line)")
                continue
            }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "NET":
                guard let posture = NetPosture(rawValue: value) else {
                    config.warnings.append("NET must be 'open' or 'none' (got '\(value)') — using open")
                    continue
                }
                config.net = posture
            case "RM":
                switch value.lowercased() {
                case "yes", "y", "1", "true": config.removeOnExit = true
                case "no", "n", "0", "false": config.removeOnExit = false
                default: config.warnings.append("RM must be yes or no (got '\(value)') — using no")
                }
            case "CPUS":
                config.cpus = value.isEmpty ? nil : Int(value)
                if !value.isEmpty && config.cpus == nil {
                    config.warnings.append("CPUS must be a number (got '\(value)') — using the daemon default")
                }
            case "MEMORY":
                config.memory = value.isEmpty ? nil : value
            case "ENV_FILE":
                config.envFilePath = value.isEmpty ? defaultEnvFilePath : expandTilde(value)
            case "NAME_PREFIX":
                if value.isEmpty {
                    config.namePrefix = "agentvm-"
                } else if value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$"#, options: .regularExpression) != nil {
                    config.namePrefix = value
                } else {
                    config.warnings.append("NAME_PREFIX must be letters/digits/._- (got '\(value)') — using agentvm-")
                }
            default:
                config.warnings.append("unknown key '\(key)' (ignored)")
            }
        }
        return config
    }

    /// Rewrites the file from the template, carrying the current values.
    public func save(to url: URL = AgentVMConfig.defaultPath) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.template(for: self).write(to: url, atomically: true, encoding: .utf8)
    }

    public static func writeTemplate(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try template(for: AgentVMConfig()).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func template(for config: AgentVMConfig) -> String {
        """
        # AgentVM configuration — defaults for a new instance. Re-read on every launch.
        # Syntax: KEY=VALUE, one per line. '#' starts a comment.

        NET=\(config.net.rawValue)
        #   Default network posture. open = on the daemon's default bridge net: direct IP
        #                  both ways (host <-> instance) + internet egress via NAT
        #                  none = killswitch: dedicated host-only network, no DNS, no egress
        RM=\(config.removeOnExit ? "yes" : "no")
        #   no  (default) = persist: when the command exits, the instance stays in
        #   state 'stopped' (VM torn down, connection cut). Start it again, or delete it.
        #   yes = one-shot: remove the instance when its command exits.
        CPUS=\(config.cpus.map(String.init) ?? "")
        #   Default CPU allocation (empty = daemon default, 4).
        MEMORY=\(config.memory ?? "")
        #   Default memory allocation (empty = daemon default, 1GiB). Suffixes: K M G T P.
        ENV_FILE=\(config.envFilePath)
        #   Shared env registry (mode 0600), injected into every new instance.
        NAME_PREFIX=\(config.namePrefix)
        #   Prefix for container and network names. AgentVM only ever lists, deletes or
        #   prunes names carrying this prefix.

        """
    }

    private static func migrateLegacyConfig(to url: URL) {
        guard url == defaultPath else { return }
        migrateLegacy(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Brings an earlier install's settings forward, once, when there is no
    /// ~/.config/agentvm/config yet. Before the rename the app was called sbx and
    /// kept ~/.config/sbx/{config,env}; those are copied, not moved, because other
    /// tools keep files in that folder too. Values still at sbx's defaults — its env
    /// path and its `sbx-` prefix — are switched to AgentVM's; anything you set
    /// yourself is kept. Older still, a pre-1.3 config at ~/.sbx is moved in.
    static func migrateLegacy(home: URL) {
        let fileManager = FileManager.default
        let folder = home.appending(path: ".config/agentvm", directoryHint: .isDirectory)
        let config = folder.appending(path: "config", directoryHint: .notDirectory)
        let env = folder.appending(path: "env", directoryHint: .notDirectory)
        guard !fileManager.fileExists(atPath: config.path(percentEncoded: false)) else { return }

        let previous = home.appending(path: ".config/sbx", directoryHint: .isDirectory)
        let previousConfig = previous.appending(path: "config", directoryHint: .notDirectory)
        let previousEnv = previous.appending(path: "env", directoryHint: .notDirectory)
        let dotSbx = home.appending(path: ".sbx", directoryHint: .notDirectory)

        if let text = try? String(contentsOf: previousConfig, encoding: .utf8) {
            let oldEnvPaths = [previousEnv.path(percentEncoded: false), "~/.config/sbx/env"]
            let migrated = text.components(separatedBy: "\n").map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "NAME_PREFIX=sbx-" { return "NAME_PREFIX=agentvm-" }
                if trimmed.hasPrefix("ENV_FILE="),
                    oldEnvPaths.contains(String(trimmed.dropFirst("ENV_FILE=".count)))
                {
                    return "ENV_FILE=\(env.path(percentEncoded: false))"
                }
                return line
            }.joined(separator: "\n")
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? migrated.write(to: config, atomically: true, encoding: .utf8)
        } else if fileManager.fileExists(atPath: dotSbx.path(percentEncoded: false)) {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fileManager.moveItem(at: dotSbx, to: config)
        }

        if fileManager.fileExists(atPath: previousEnv.path(percentEncoded: false)),
            !fileManager.fileExists(atPath: env.path(percentEncoded: false))
        {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fileManager.copyItem(at: previousEnv, to: env)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.path(percentEncoded: false))
        }
    }

    private static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        // Foundation's home URL is a directory URL, so its path ends in a slash;
        // joining it to "/rest" naively would give "/Users/you//rest".
        var home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        while home.count > 1 && home.hasSuffix("/") { home.removeLast() }
        return home + path.dropFirst()
    }
}
