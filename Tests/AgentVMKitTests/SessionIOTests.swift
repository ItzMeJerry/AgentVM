//
//  SessionIOTests.swift
//  A shell session's output has to reach the terminal exactly as the guest wrote
//  it. Chunks that arrive shuffled, or an end-of-stream that overtakes the last
//  chunk, show up as garbled screens and a "session ended" line printed before
//  the output it ends. These run against the session's own pipes: no daemon.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Testing

@testable import AgentVMKit

@Suite("SessionIO")
struct SessionIOTests {

    /// Collects what the stream delivers; touched only on the delivery queue.
    private final class Received: @unchecked Sendable {
        var bytes: [UInt8] = []
        var chunks = 0
        var bytesAtEOF: Int?
        var eofCount = 0
    }

    @Test("Output arrives in the order it was written, and EOF only after the last byte")
    func orderedDelivery() async throws {
        let io = SessionIO()
        let queue = DispatchQueue(label: "agentvm.tests.session")
        let received = Received()

        // Many small writes, each tagged with its number, so a reordering can't
        // hide behind identical content.
        var expected: [UInt8] = []
        for index in 0..<4_000 {
            expected.append(contentsOf: Array("\(index);".utf8))
        }

        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            io.beginStreaming(
                on: queue,
                onOutput: { chunk in
                    received.bytes.append(contentsOf: chunk)
                    received.chunks += 1
                },
                onEOF: {
                    received.eofCount += 1
                    received.bytesAtEOF = received.bytes.count
                    done.resume()
                })

            let writer = io.stdio[1]!
            DispatchQueue.global().async {
                for index in 0..<4_000 {
                    writer.write(Data("\(index);".utf8))
                }
                try? writer.close()
            }
        }

        // EOF was delivered once, after every byte.
        queue.sync {}
        #expect(received.eofCount == 1)
        #expect(received.bytesAtEOF == expected.count)
        #expect(received.bytes == expected)
        #expect(received.chunks >= 1)
    }

    @Test("A session with no output still reports EOF exactly once")
    func eofWithoutOutput() async throws {
        let io = SessionIO()
        let queue = DispatchQueue(label: "agentvm.tests.session.empty")
        let received = Received()

        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            io.beginStreaming(
                on: queue,
                onOutput: { received.bytes.append(contentsOf: $0) },
                onEOF: {
                    received.eofCount += 1
                    done.resume()
                })
            try? io.stdio[1]!.close()
        }

        queue.sync {}
        #expect(received.bytes.isEmpty)
        #expect(received.eofCount == 1)
    }
}
