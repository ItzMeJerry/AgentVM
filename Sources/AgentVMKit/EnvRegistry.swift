//
//  EnvRegistry.swift
//  The shared environment registry: a mode-0600 K=V file injected into every
//  new instance. Edited once, picked up by every instance created afterwards;
//  a running instance keeps the environment baked in at creation.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

public struct EnvEntry: Identifiable, Sendable, Equatable {
    public var key: String
    public var value: String
    public var id: String { key }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct EnvRegistry: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var path: String { url.path(percentEncoded: false) }

    public var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// The file's modification date, used to flag instances whose baked-in
    /// environment predates the current registry.
    public var modifiedAt: Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    public func ensureFile() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !exists {
            guard FileManager.default.createFile(atPath: path, contents: Data()) else {
                throw AgentVMError("cannot create the env registry at \(path)")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    public func load() -> [EnvEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            guard line.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil,
                let eq = line.firstIndex(of: "=")
            else { return nil }
            return EnvEntry(
                key: String(line[line.startIndex..<eq]),
                value: String(line[line.index(after: eq)...]))
        }
    }

    public func save(_ entries: [EnvEntry]) throws {
        for entry in entries {
            guard entry.key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
            else {
                throw AgentVMError("'\(entry.key)' is not a valid variable name")
            }
            guard !entry.value.contains("\n") else {
                throw AgentVMError("\(entry.key): values may not contain newlines")
            }
        }
        try ensureFile()
        let body = entries.map { "\($0.key)=\($0.value)\n" }.joined()
        // Write in place rather than via a replacement file, so the 0600 mode and
        // the inode (which nothing else holds open) stay as they are.
        try body.write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    public func set(_ key: String, _ value: String) throws {
        var entries = load().filter { $0.key != key }
        entries.append(EnvEntry(key: key, value: value))
        try save(entries)
    }

    public func unset(_ key: String) throws {
        try save(load().filter { $0.key != key })
    }

    public var hasEntries: Bool { !load().isEmpty }
}
