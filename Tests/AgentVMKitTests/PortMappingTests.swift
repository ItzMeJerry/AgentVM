//
//  PortMappingTests.swift
//  Port specs are parsed by the same code `container run -p` uses, and are
//  validated before anything reaches a container bundle on disk. A set the
//  daemon would refuse must never be written, so the refusals are tested as
//  carefully as the acceptances.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Testing

@testable import AgentVMKit

@Suite("PortMapping")
struct PortMappingTests {

    // MARK: - Parsing

    @Test("A bare host:guest pair publishes on loopback only")
    func bareSpecDefaultsToLoopback() throws {
        let mapping = try PortMapping.parse("8080:80")
        #expect(mapping.hostAddress == "127.0.0.1")
        #expect(mapping.hostPort == 8080)
        #expect(mapping.containerPort == 80)
        #expect(mapping.proto == "tcp")
        #expect(mapping.count == 1)
        #expect(mapping.isLoopback)
        #expect(!mapping.isIPv6)
    }

    @Test("A named IPv4 address is kept as given")
    func explicitIPv4Address() throws {
        let mapping = try PortMapping.parse("0.0.0.0:8080:80")
        #expect(mapping.hostAddress == "0.0.0.0")
        #expect(mapping.hostPort == 8080)
        #expect(mapping.containerPort == 80)
        #expect(!mapping.isLoopback)
    }

    @Test("A bracketed IPv6 address parses, and reports itself as IPv6")
    func bracketedIPv6Address() throws {
        let mapping = try PortMapping.parse("[::1]:8080:80")
        #expect(mapping.hostAddress == "::1")
        #expect(mapping.isIPv6)
        #expect(mapping.isLoopback)
        #expect(mapping.spec == "[::1]:8080:80/tcp")
    }

    @Test("UDP is carried through")
    func udpProtocol() throws {
        let mapping = try PortMapping.parse("5353:53/udp")
        #expect(mapping.proto == "udp")
        #expect(mapping.spec == "127.0.0.1:5353:53/udp")
    }

    @Test("A range keeps its width")
    func portRange() throws {
        let mapping = try PortMapping.parse("8080-8082:80-82")
        #expect(mapping.hostPort == 8080)
        #expect(mapping.containerPort == 80)
        #expect(mapping.count == 3)
        #expect(mapping.spec == "127.0.0.1:8080-8082:80-82/tcp")
    }

    @Test("Surrounding whitespace is ignored")
    func trimsWhitespace() throws {
        #expect(try PortMapping.parse("  8080:80  ").hostPort == 8080)
    }

    @Test("A spec parses back to the same mapping", arguments: [
        "8080:80",
        "0.0.0.0:8080:80",
        "[::1]:8080:80",
        "5353:53/udp",
        "8080-8082:80-82",
    ])
    func specRoundTrips(_ text: String) throws {
        let mapping = try PortMapping.parse(text)
        #expect(try PortMapping.parse(mapping.spec) == mapping)
    }

    @Test("Nonsense is refused", arguments: [
        "",
        "not-a-port",
        "70000:80",
        "8080:70000",
        "-1:80",
        "8080",
        "8080:80/sctp",
    ])
    func rejectsInvalidSpecs(_ text: String) {
        #expect(throws: (any Error).self) { try PortMapping.parse(text) }
    }

    // MARK: - Validation

    @Test("A set with no conflicts passes")
    func validatesDisjointSet() throws {
        let mappings = [
            try PortMapping.parse("8080:80"),
            try PortMapping.parse("8081:81"),
            try PortMapping.parse("5353:53/udp"),
        ]
        try PortMapping.validate(mappings)
    }

    @Test("The same host port twice is refused")
    func rejectsDuplicateHostPort() throws {
        let mappings = [
            try PortMapping.parse("8080:80"),
            try PortMapping.parse("8080:8080"),
        ]
        #expect(throws: (any Error).self) { try PortMapping.validate(mappings) }
    }

    @Test("A different address does not make a host port free again")
    func rejectsDuplicateAcrossAddresses() throws {
        let mappings = [
            try PortMapping.parse("127.0.0.1:8080:80"),
            try PortMapping.parse("0.0.0.0:8080:80"),
        ]
        #expect(throws: (any Error).self) { try PortMapping.validate(mappings) }
    }

    @Test("The same host port on TCP and UDP is allowed")
    func allowsSamePortDifferentProtocol() throws {
        try PortMapping.validate([
            try PortMapping.parse("8080:80/tcp"),
            try PortMapping.parse("8080:80/udp"),
        ])
    }

    @Test("Overlapping ranges are refused")
    func rejectsOverlappingRanges() throws {
        let mappings = [
            try PortMapping.parse("8080-8085:80-85"),
            try PortMapping.parse("8083:90"),
        ]
        #expect(throws: (any Error).self) { try PortMapping.validate(mappings) }
    }

    @Test("Adjacent ranges that do not touch are allowed")
    func allowsAdjacentRanges() throws {
        try PortMapping.validate([
            try PortMapping.parse("8080-8082:80-82"),
            try PortMapping.parse("8083-8085:83-85"),
        ])
    }

    @Test("At most 64 mappings, the daemon's own limit")
    func enforcesMappingLimit() throws {
        #expect(PortMapping.limit == 64)
        let atLimit = try (0..<64).map { try PortMapping.parse("\(9000 + $0):80") }
        try PortMapping.validate(atLimit)

        let overLimit = try (0..<65).map { try PortMapping.parse("\(9000 + $0):80") }
        #expect(throws: (any Error).self) { try PortMapping.validate(overLimit) }
    }

    @Test("An empty set is valid — it means no published ports")
    func allowsEmptySet() throws {
        try PortMapping.validate([])
    }

    // MARK: - Conversion

    @Test("A mapping converts to the daemon's own PublishPort and back")
    func convertsToPublishPort() throws {
        let mapping = try PortMapping.parse("0.0.0.0:8080-8082:80-82/udp")
        let round = PortMapping(try mapping.publishPort())
        #expect(round == mapping)
    }

    @Test("Identity is the host port and protocol — what the daemon keys on")
    func identityIsHostPortAndProtocol() throws {
        #expect(try PortMapping.parse("8080:80").id == "8080/tcp")
        #expect(try PortMapping.parse("8080:80/udp").id == "8080/udp")
    }
}
