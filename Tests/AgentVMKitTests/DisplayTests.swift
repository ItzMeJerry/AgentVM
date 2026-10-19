//
//  DisplayTests.swift
//  What the interface shows for an image and for the container service: the
//  short forms people recognise, never the plumbing around them.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Testing

@testable import AgentVMKit

@Suite("What the interface shows")
struct DisplayTests {

    @Test(
        "Docker Hub images read as people type them; other registries keep their host",
        arguments: [
            ("docker.io/library/alpine:3.20", "alpine:3.20"),
            ("docker.io/library/ubuntu:24.04", "ubuntu:24.04"),
            ("index.docker.io/library/debian:bookworm-slim", "debian:bookworm-slim"),
            ("docker.io/jpsim/yams:1.0", "jpsim/yams:1.0"),
            ("ghcr.io/apple/containerization/vminit:0.41.0", "ghcr.io/apple/containerization/vminit:0.41.0"),
            ("alpine:3.20", "alpine:3.20"),
            ("localhost:5000/tool:dev", "localhost:5000/tool:dev"),
        ])
    func imageNames(reference: String, shown: String) {
        #expect(AgentVMInstance.displayName(ofImage: reference) == shown)
    }

    @Test(
        "The service's version is its release number, without build kind or commit",
        arguments: [
            ("container-apiserver version 1.3.0 (build: release, commit: unspeci)", "1.3.0"),
            ("container-apiserver version 1.4 (build: debug)", "1.4"),
            ("1.3.0", "1.3.0"),
        ])
    func releaseNumber(version: String, release: String) {
        let status = AgentVMEngine.DaemonStatus(running: true, version: version, appRoot: nil, message: nil)
        #expect(status.release == release)
    }

    @Test("A version string without a number has no release")
    func noRelease() {
        #expect(AgentVMEngine.DaemonStatus(running: true, version: "dev", appRoot: nil, message: nil).release == nil)
        #expect(AgentVMEngine.DaemonStatus(running: false, version: nil, appRoot: nil, message: nil).release == nil)
    }
}
