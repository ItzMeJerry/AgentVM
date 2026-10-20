//
//  UTF8Stream.swift
//  Text that arrives in pieces — a log read a chunk at a time — decoded
//  without losing a character that a piece boundary cuts in two.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

public struct UTF8Stream: Sendable {
    /// The first bytes of a character the last piece ended part-way through.
    private var pending: [UInt8] = []

    public init() {}

    /// The text these bytes complete. The start of a character they cut
    /// short waits for the next piece; a byte that starts no character at all
    /// becomes a replacement character, and the rest still comes through.
    public mutating func decode(_ data: Data) -> String {
        var bytes = pending
        bytes.append(contentsOf: data)
        let whole = Self.wholeLength(of: bytes)
        pending = Array(bytes[whole...])
        return String(decoding: bytes[..<whole], as: UTF8.self)
    }

    /// How many of the bytes make whole characters: all of them, unless the
    /// last few begin one that's still to come.
    static func wholeLength(of bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }
        // A character is at most four bytes, so only the last three can be
        // the start of one cut short.
        for back in 1...min(3, bytes.count) {
            let byte = bytes[bytes.count - back]
            // A continuation byte: its character starts further back.
            if byte & 0b1100_0000 == 0b1000_0000 { continue }
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return length > back ? bytes.count - back : bytes.count
        }
        return bytes.count
    }
}
