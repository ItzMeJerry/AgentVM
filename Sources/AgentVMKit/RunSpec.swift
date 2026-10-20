//
//  RunSpec.swift
//  What the "New instance" sheet collects, and the validation every field
//  goes through before any of it reaches the daemon.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// A bind mount. The guest sees exactly the directories named here and nothing
/// else: `apple/container` grants no ambient host access.
public struct MountSpec: Identifiable, Sendable, Equatable, Hashable {
    public var id = UUID()
    public var hostPath: String
    public var guestPath: String
    public var readOnly: Bool

    public init(hostPath: String = "", guestPath: String = "", readOnly: Bool = false) {
        self.hostPath = hostPath
        self.guestPath = guestPath
        self.readOnly = readOnly
    }

    /// Resolves the host path and refuses the two mounts that would hand over
    /// the whole machine.
    public func validated() throws -> MountSpec {
        let host = (hostPath as NSString).expandingTildeInPath
        guard !host.isEmpty, !guestPath.isEmpty else {
            throw AgentVMError("a mount needs both a host directory and a guest path")
        }
        guard guestPath.hasPrefix("/") else {
            throw AgentVMError("mount target '\(guestPath)' must be absolute (start with /)")
        }
        guard !host.contains(","), !guestPath.contains(",") else {
            throw AgentVMError("mount paths must not contain ','")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: host, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw AgentVMError("mount source '\(host)' is not an existing directory")
        }
        // Both sides are trimmed before they are compared: Foundation hands back
        // a directory URL's path with a trailing slash, and an expanded ~ without
        // one, so comparing them as they come never matches.
        let canonical = Self.canonicalDirectoryPath(host)
        let home = Self.canonicalDirectoryPath(
            FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false))
        if canonical == "/" {
            throw AgentVMError("refusing to mount / (the entire host)")
        }
        if canonical == home {
            throw AgentVMError("refusing to mount $HOME (\(canonical))")
        }
        var resolved = self
        resolved.hostPath = canonical
        return resolved
    }

    /// Symlinks resolved and any trailing slash removed, so two spellings of the
    /// same directory compare equal. "/" keeps its slash — it is the whole path.
    static func canonicalDirectoryPath(_ path: String) -> String {
        let resolved = URL(filePath: path).resolvingSymlinksInPath().path(percentEncoded: false)
        guard resolved.count > 1, resolved.hasSuffix("/") else { return resolved }
        return String(resolved.reversed().drop(while: { $0 == "/" }).reversed())
    }

    /// The `type=bind,...` form the container API takes.
    public var mountArgument: String {
        var spec = "type=bind,source=\(hostPath),target=\(guestPath)"
        if readOnly { spec += ",readonly" }
        return spec
    }
}

/// Which lifetime rules an instance follows. Recorded as the `agentvm.mode` label.
public enum AgentVMMode: String, Sendable, CaseIterable {
    /// No command: the main process is a keepalive loop that never exits, so the
    /// container runs until you stop it. Shell sessions are independent.
    case instance
    /// A command: the command *is* the main process, and the container stops
    /// when it finishes.
    case task

    public var summary: String {
        switch self {
        case .instance:
            "Long-lived. The main process is a keepalive loop, so the instance runs until you stop it — closing a shell session never stops it."
        case .task:
            "The command is the main process. When it exits the container stops and stays in 'stopped' until you delete it."
        }
    }
}

public struct RunSpec: Sendable {
    public var image: String = ""
    /// Short name; empty means a random `agentvm-<8 hex>`.
    public var name: String = ""
    public var net: NetPosture = .open
    public var mode: AgentVMMode = .instance
    /// The task's command. Ignored in `.instance` mode.
    public var command: [String] = []
    public var mounts: [MountSpec] = []
    /// Per-instance variables; these override the shared registry.
    public var env: [EnvEntry] = []
    public var useRegistry: Bool = true
    public var cpus: Int?
    public var memory: String?
    public var rosetta: Bool = false
    /// One-shot: remove the instance when its command exits (tasks only).
    public var removeOnExit: Bool = false

    public init() {}

    public init(config: AgentVMConfig) {
        self.net = config.net
        self.cpus = config.cpus
        self.memory = config.memory
        self.removeOnExit = config.removeOnExit
    }

    /// The keepalive that makes an instance outlive every shell session.
    static let keepaliveEntrypoint = "sh"
    static let keepaliveArguments = ["-c", "while :; do sleep 3600; done"]
}

/// What an instance runs as its main process, and with it the lifetime it
/// follows: the keepalive for an instance, a command for a task. What
/// Main Process writes into a stopped instance's bundle.
public struct MainProcess: Sendable, Equatable {
    public let mode: AgentVMMode
    public let executable: String
    public let arguments: [String]

    /// Runs until the instance is stopped.
    public static let keepalive = MainProcess(
        mode: .instance, executable: RunSpec.keepaliveEntrypoint, arguments: RunSpec.keepaliveArguments)

    private init(mode: AgentVMMode, executable: String, arguments: [String]) {
        self.mode = mode
        self.executable = executable
        self.arguments = arguments
    }

    /// An instance runs the keepalive, whatever `command` says. A task runs
    /// its command exactly as given — first the program, then its arguments,
    /// and no image entrypoint in front — and stops when it finishes.
    public init(mode: AgentVMMode, command: [String]) throws {
        guard mode == .task else {
            self = .keepalive
            return
        }
        guard let program = command.first else {
            throw AgentVMError("a task needs a command — the command is its main process")
        }
        guard !program.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentVMError("a command starts with the program to run, not a blank")
        }
        // The keepalive by hand is an instance in all but name.
        if command == Self.keepalive.command {
            self = .keepalive
            return
        }
        self.init(mode: .task, executable: program, arguments: Array(command.dropFirst()))
    }

    public var command: [String] { [executable] + arguments }
}

public enum AgentVMNaming {
    /// The charset a container (and, under the same name, its network) may use.
    public static func validateShortName(_ name: String, posture: NetPosture) throws {
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$"#, options: .regularExpression) != nil
        else {
            throw AgentVMError(
                "invalid name '\(name)'",
                hint: "Use letters, digits, '.', '_' and '-', starting with a letter or digit (max 63 characters).")
        }
        // A killswitch instance also needs a network of its own, and network
        // names are lowercase-only.
        if posture == .killswitch,
            name.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) == nil
        {
            throw AgentVMError(
                "'\(name)' cannot be used with the killswitch",
                hint: "A killswitch instance needs a dedicated network, and network names must be lowercase.")
        }
    }

    public static func randomName(prefix: String) -> String {
        let hex = (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        return prefix + hex
    }
}
