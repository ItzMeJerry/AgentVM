//
//  InstanceLocks.swift
//  Locks, for the instances you use every day: Prune leaves a locked instance
//  alone, and Delete refuses it until it's unlocked. Plus Prune's plan, which
//  is where a lock takes effect.
//
//  The list is a file of AgentVM's own, ~/.config/agentvm/locks, one container
//  name per line, rather than a label on the container: labels are fixed at
//  creation, and an instance you rely on is one you want to lock while it
//  runs. The flip side is that only AgentVM honours it — `container delete`
//  and `container prune` in Terminal have never heard of it.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

public struct InstanceLocks: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var path: String { url.path(percentEncoded: false) }

    /// The locked container names. No file means nothing is locked. A file
    /// that is there but can't be read throws rather than reading as empty:
    /// a lock that quietly reads as unlocked is worse than none.
    public func names() throws -> Set<String> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw AgentVMError(
                "cannot read the lock list at \(path)",
                hint: "Prune and Delete leave every instance alone until it can be read. \(error.localizedDescription)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentVMError(
                "the lock list at \(path) is not text",
                hint: "Prune and Delete leave every instance alone until it's fixed or removed.")
        }
        return Self.parse(text)
    }

    /// One name per line; blank lines and `#` comments are skipped.
    static func parse(_ text: String) -> Set<String> {
        Set(
            text.components(separatedBy: .newlines).compactMap { line in
                let name = line.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            })
    }

    func isLocked(_ fullName: String) throws -> Bool {
        try names().contains(fullName)
    }

    public func lock(_ fullName: String) throws {
        guard Self.fits(fullName) else {
            throw AgentVMError("'\(fullName)' can't be locked: it isn't a container name")
        }
        try change { _ = $0.insert(fullName) }
    }

    public func unlock(_ fullName: String) throws {
        try change { _ = $0.remove(fullName) }
    }

    /// What Delete asks before anything else.
    public func ensureUnlocked(_ fullName: String, shortName: String) throws {
        if try isLocked(fullName) {
            throw AgentVMError(
                "\(shortName) is locked",
                hint: "Unlock it first. While it's locked, Delete refuses it and Prune leaves it alone.")
        }
    }

    /// A name the file can hold as written: one line, no comment marker, and
    /// nothing that trimming would change.
    static func fits(_ name: String) -> Bool {
        !name.isEmpty
            && name.trimmingCharacters(in: .whitespacesAndNewlines) == name
            && !name.contains("#")
            && name.rangeOfCharacter(from: .newlines) == nil
    }

    /// Reads the list, changes it and writes it back, so an edit made by hand
    /// in the meantime is kept. Nothing is written when nothing changes.
    private func change(_ edit: (inout Set<String>) -> Void) throws {
        var names = try names()
        let before = names
        edit(&names)
        guard names != before else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = Self.header + names.sorted().map { "\($0)\n" }.joined()
        // Atomically: a Prune reading at the same moment sees the old list or
        // the new one, never half of one.
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    static let header = """
        # AgentVM locks. Prune leaves these instances alone, and Delete refuses them
        # until they're unlocked. One container name per line; '#' starts a comment.

        """
}

/// What Prune removes and what it keeps, decided before anything is touched:
/// AgentVM's containers that aren't locked, and AgentVM's killswitch networks
/// except a locked instance's. Names without the prefix never appear in it.
public struct PrunePlan: Sendable, Equatable {
    /// Removed.
    public let containers: [String]
    /// Removed: every AgentVM network but those of the instances kept.
    public let networks: [String]
    /// Locked, so left alone — and their networks with them.
    public let kept: [String]

    public init(containers: [String], networks: [String] = [], locked: Set<String>, config: AgentVMConfig) {
        let ours = containers.filter { config.isAgentVMName($0) }.sorted()
        self.kept = ours.filter { locked.contains($0) }
        self.containers = ours.filter { !locked.contains($0) }
        let keptNetworks = Set(kept.map { config.networkName(for: $0) })
        self.networks = networks.filter { config.isAgentVMNetworkName($0) && !keptNetworks.contains($0) }.sorted()
    }
}
