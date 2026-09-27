//
//  PortMapping.swift
//  A published port — host address and port forwarded to a guest port — in a
//  form the UI can hold, parsed by the same code `container run -p` uses.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import Foundation

public struct PortMapping: Identifiable, Sendable, Equatable, Hashable {
    public var hostAddress: String
    public var hostPort: UInt16
    public var containerPort: UInt16
    /// "tcp" or "udp".
    public var proto: String
    /// How many consecutive ports, for a range.
    public var count: UInt16

    public var id: String { "\(hostPort)/\(proto)" }

    /// Where an address-less spec listens. The CLI's default is 0.0.0.0 — every
    /// interface, the LAN included; AgentVM publishes to this Mac only unless you
    /// name an address.
    public static let defaultHostAddress = "127.0.0.1"

    /// The `container` daemon refuses more than this many descriptors.
    public static let limit = 64

    public var isIPv6: Bool { hostAddress.contains(":") }
    public var isLoopback: Bool { hostAddress == "127.0.0.1" || hostAddress == "::1" }

    /// `127.0.0.1:8080-8081:80-81/tcp`, the CLI's `-p` form.
    public var spec: String {
        let address = isIPv6 ? "[\(hostAddress)]" : hostAddress
        return "\(address):\(Self.range(hostPort, count)):\(Self.range(containerPort, count))/\(proto)"
    }

    /// `8080 → 80`, for places without room for the address and protocol.
    public var shortDescription: String {
        "\(Self.range(hostPort, count)) → \(Self.range(containerPort, count))" + (proto == "udp" ? "/udp" : "")
    }

    private static func range(_ start: UInt16, _ count: UInt16) -> String {
        count > 1 ? "\(start)-\(Int(start) + Int(count) - 1)" : "\(start)"
    }

    /// Parses `[host-ip:]host-port:container-port[/tcp|udp]`, ranges allowed.
    /// With no address, the port is published on loopback only.
    public static func parse(_ text: String) throws -> PortMapping {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let hasAddress = trimmed.hasPrefix("[") || trimmed.split(separator: "/").first.map { $0.filter { $0 == ":" }.count >= 2 } == true
        let spec = hasAddress ? trimmed : "\(defaultHostAddress):\(trimmed)"
        do {
            return PortMapping(try Parser.publishPort(spec))
        } catch {
            throw AgentVMError("'\(trimmed)' is not a valid port mapping", hint: "\(error)")
        }
    }

    init(_ port: PublishPort) {
        self.hostAddress = port.hostAddress.description
        self.hostPort = port.hostPort
        self.containerPort = port.containerPort
        self.proto = port.proto.rawValue
        self.count = port.count
    }

    func publishPort() throws -> PublishPort {
        guard let proto = PublishProtocol(proto) else {
            throw AgentVMError("unknown protocol '\(proto)' for \(spec)")
        }
        return try PublishPort(
            hostAddress: try IPAddress(hostAddress),
            hostPort: hostPort,
            containerPort: containerPort,
            proto: proto,
            count: count)
    }

    /// The checks the daemon applies at start, applied before anything is
    /// written: a set it would refuse must never reach the disk.
    public static func validate(_ mappings: [PortMapping]) throws {
        guard mappings.count <= limit else {
            throw AgentVMError("at most \(limit) port mappings are allowed")
        }
        let ports = try mappings.map { try $0.publishPort() }
        var taken: [String: PortMapping] = [:]
        for mapping in mappings {
            for offset in 0..<Int(mapping.count) {
                let key = "\(Int(mapping.hostPort) + offset)/\(mapping.proto)"
                if let other = taken[key] {
                    throw AgentVMError(
                        "host port \(key) is used twice (\(other.spec) and \(mapping.spec))",
                        hint: "Each host port can forward to one guest port. The address doesn't separate them.")
                }
                taken[key] = mapping
            }
        }
        // The daemon's own check, in case its rules ever drift from the above.
        guard !ports.hasOverlaps() else {
            throw AgentVMError("host ports may not overlap")
        }
    }
}
