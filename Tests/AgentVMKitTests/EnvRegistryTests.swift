//
//  EnvRegistryTests.swift
//  The registry holds secrets in a plain file, so its mode matters as much as
//  its contents: 0600 when created, and still 0600 after every write.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Testing

@testable import AgentVMKit

@Suite("EnvRegistry")
struct EnvRegistryTests {

    @discardableResult
    private func withTemporaryRegistry<T>(_ body: (EnvRegistry) throws -> T) throws -> T {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "agentvm-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(EnvRegistry(url: directory.appending(path: "env", directoryHint: .notDirectory)))
    }

    private func mode(of registry: EnvRegistry) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: registry.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Creation

    @Test("A registry that does not exist yet reports so, and loads as empty")
    func absentRegistryIsEmpty() throws {
        try withTemporaryRegistry { registry in
            #expect(!registry.exists)
            #expect(registry.load().isEmpty)
            #expect(!registry.hasEntries)
            #expect(registry.modifiedAt == nil)
        }
    }

    @Test("The file is created 0600")
    func createsFileWithOwnerOnlyPermissions() throws {
        try withTemporaryRegistry { registry in
            try registry.ensureFile()
            #expect(registry.exists)
            #expect(try mode(of: registry) == 0o600)
        }
    }

    @Test("A too-permissive file is tightened back to 0600")
    func tightensLoosePermissions() throws {
        try withTemporaryRegistry { registry in
            try registry.ensureFile()
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: registry.path)
            try registry.ensureFile()
            #expect(try mode(of: registry) == 0o600)
        }
    }

    @Test("A write leaves the mode at 0600")
    func staysOwnerOnlyAfterWriting() throws {
        try withTemporaryRegistry { registry in
            try registry.set("TOKEN", "s3cret")
            #expect(try mode(of: registry) == 0o600)
        }
    }

    // MARK: - Round trip

    @Test("Entries survive a save and load")
    func savesAndLoads() throws {
        try withTemporaryRegistry { registry in
            let entries = [
                EnvEntry(key: "API_KEY", value: "abc123"),
                EnvEntry(key: "REGION", value: "eu-west-1"),
            ]
            try registry.save(entries)
            #expect(registry.load() == entries)
            #expect(registry.hasEntries)
        }
    }

    @Test("A value may contain the characters that shells find interesting")
    func keepsAwkwardValuesIntact() throws {
        try withTemporaryRegistry { registry in
            let awkward = #"a=b spaces "quotes" $VAR 'single' \back #hash"#
            try registry.set("TRICKY", awkward)
            #expect(registry.load().first?.value == awkward)
        }
    }

    @Test("An empty value is allowed")
    func allowsEmptyValue() throws {
        try withTemporaryRegistry { registry in
            try registry.set("EMPTY", "")
            #expect(registry.load() == [EnvEntry(key: "EMPTY", value: "")])
        }
    }

    @Test("Setting a key again replaces it rather than adding a second copy")
    func setReplaces() throws {
        try withTemporaryRegistry { registry in
            try registry.set("TOKEN", "old")
            try registry.set("TOKEN", "new")
            #expect(registry.load() == [EnvEntry(key: "TOKEN", value: "new")])
        }
    }

    @Test("Unsetting removes one key and leaves the rest")
    func unsetRemovesOneKey() throws {
        try withTemporaryRegistry { registry in
            try registry.set("A", "1")
            try registry.set("B", "2")
            try registry.unset("A")
            #expect(registry.load() == [EnvEntry(key: "B", value: "2")])
        }
    }

    @Test("Unsetting something that was never there is not an error")
    func unsetMissingKeyIsHarmless() throws {
        try withTemporaryRegistry { registry in
            try registry.set("A", "1")
            try registry.unset("NOPE")
            #expect(registry.load() == [EnvEntry(key: "A", value: "1")])
        }
    }

    @Test("Saving nothing empties the file but keeps it")
    func savingEmptyClearsFile() throws {
        try withTemporaryRegistry { registry in
            try registry.set("A", "1")
            try registry.save([])
            #expect(registry.exists)
            #expect(registry.load().isEmpty)
            #expect(try mode(of: registry) == 0o600)
        }
    }

    // MARK: - Refusals

    @Test("A name that is not a shell variable name is refused", arguments: [
        "lower case", "1LEADING_DIGIT", "HAS-DASH", "HAS.DOT", "", "HAS=EQUALS",
    ])
    func rejectsInvalidKey(_ key: String) throws {
        try withTemporaryRegistry { registry in
            #expect(throws: (any Error).self) {
                try registry.save([EnvEntry(key: key, value: "x")])
            }
        }
    }

    @Test("Valid names are accepted", arguments: [
        "A", "_", "_PRIVATE", "API_KEY_2", "lowercase_is_legal",
    ])
    func acceptsValidKey(_ key: String) throws {
        try withTemporaryRegistry { registry in
            try registry.save([EnvEntry(key: key, value: "x")])
            #expect(registry.load().first?.key == key)
        }
    }

    @Test("A newline in a value is refused — one line per variable is the format")
    func rejectsNewlineInValue() throws {
        try withTemporaryRegistry { registry in
            #expect(throws: (any Error).self) {
                try registry.save([EnvEntry(key: "MULTI", value: "one\ntwo")])
            }
        }
    }

    @Test("A refused save leaves the previous contents alone")
    func refusedSaveDoesNotClobber() throws {
        try withTemporaryRegistry { registry in
            try registry.set("KEEP", "me")
            #expect(throws: (any Error).self) {
                try registry.save([EnvEntry(key: "KEEP", value: "me"), EnvEntry(key: "bad name", value: "x")])
            }
            #expect(registry.load() == [EnvEntry(key: "KEEP", value: "me")])
        }
    }

    // MARK: - Reading a hand-edited file

    @Test("Lines that are not assignments are skipped, not guessed at")
    func skipsNonAssignmentLines() throws {
        try withTemporaryRegistry { registry in
            try registry.ensureFile()
            try """
            # a comment
            export NOT_THIS=1
            2INVALID=x

            GOOD=yes
            ALSO_GOOD=a=b
            """.write(to: registry.url, atomically: false, encoding: .utf8)

            #expect(registry.load() == [
                EnvEntry(key: "GOOD", value: "yes"),
                EnvEntry(key: "ALSO_GOOD", value: "a=b"),
            ])
        }
    }

    @Test("A write updates the modification date the staleness check reads")
    func recordsModificationDate() throws {
        try withTemporaryRegistry { registry in
            try registry.set("A", "1")
            let first = try #require(registry.modifiedAt)
            #expect(first.timeIntervalSinceNow < 5)
        }
    }
}
