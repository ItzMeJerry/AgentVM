//
//  UTF8StreamTests.swift
//  A log is read a chunk at a time, and a chunk can end part-way through a
//  character. Decoded on its own, such a chunk is no valid text at all, and it
//  used to be dropped whole.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Testing

@testable import AgentVMKit

@Suite("UTF-8 in pieces")
struct UTF8StreamTests {

    @Test("Text cut at every byte comes out whole", arguments: ["ok ✓ done", "naïve café", "🙂 and 日本語", "plain"])
    func everyCut(text: String) {
        let bytes = Array(text.utf8)
        for cut in 0...bytes.count {
            var stream = UTF8Stream()
            let joined = stream.decode(Data(bytes[..<cut])) + stream.decode(Data(bytes[cut...]))
            #expect(joined == text, "cut at byte \(cut)")
        }
    }

    @Test("Every byte on its own still adds up to the text")
    func byteByByte() {
        let text = "🙂 ✓ é 日本 x"
        var stream = UTF8Stream()
        let joined = text.utf8.map { stream.decode(Data([$0])) }.joined()
        #expect(joined == text)
    }

    @Test("A byte that starts no character becomes a replacement, and the rest comes through")
    func malformed() {
        var stream = UTF8Stream()
        let decoded = stream.decode(Data([0x61, 0xFF, 0x62])) + stream.decode(Data("c".utf8))
        #expect(decoded == "a\u{FFFD}bc")
    }

    @Test(
        "Only the start of a character still to come is held back",
        arguments: [
            ([0x61], 1), ([0xE2, 0x9C], 0), ([0x61, 0xE2], 1), ([0xE2, 0x9C, 0x93], 3),
            ([0xF0, 0x9F, 0x99], 0), ([0xF0, 0x9F, 0x99, 0x82], 4), ([], 0),
        ] as [([UInt8], Int)])
    func wholeLength(bytes: [UInt8], whole: Int) {
        #expect(UTF8Stream.wholeLength(of: bytes) == whole)
    }
}
