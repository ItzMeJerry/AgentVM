//
//  TestSupport.swift
//  What several suites share: a directory of the test's own, which goes away
//  with it, so nothing a test writes reaches ~/.config.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// Runs `body` with a new, empty directory, removed afterwards whatever happens.
@discardableResult
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

/// The same, for a test that awaits.
@discardableResult
func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = URL(filePath: NSTemporaryDirectory())
        .appending(path: "agentvm-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
