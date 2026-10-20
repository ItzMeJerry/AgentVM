//
//  CommandTests.swift
//  A command typed into New Instance or Main Process reaches the guest as a
//  list of arguments, so the split decides what runs. And a command shown for
//  editing must split back into exactly the arguments it came from, or
//  saving it unchanged would change it.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Testing

@testable import AgentVMKit

@Suite("Typed commands")
struct ShellWordsTests {

    @Test(
        "A command splits into the arguments a shell would give it",
        arguments: [
            ("sh -c 'make test'", ["sh", "-c", "make test"]),
            ("  ls   -la\t/etc ", ["ls", "-la", "/etc"]),
            (#"echo "a \"b\" \\ \$HOME \`x\`""#, ["echo", #"a "b" \ $HOME `x`"#]),
            (#"echo "a\nb""#, ["echo", #"a\nb"#]),
            (#"echo 'a\b "c"'"#, ["echo", #"a\b "c""#]),
            (#"printf '' x """#, ["printf", "", "x", ""]),
            (#"a'b c'"d""#, ["ab cd"]),
            (#"touch a\ b \'"#, ["touch", "a b", "'"]),
            ("echo a\\\nb", ["echo", "ab"]),
            ("python3 -m http.server 8000", ["python3", "-m", "http.server", "8000"]),
        ])
    func splits(text: String, arguments: [String]) throws {
        #expect(try ShellWords.split(text) == arguments)
    }

    @Test("Nothing is expanded: no variables, globs or home folder, because no shell runs it")
    func noExpansion() throws {
        #expect(try ShellWords.split("echo $HOME *.txt ~ a|b") == ["echo", "$HOME", "*.txt", "~", "a|b"])
    }

    @Test("Nothing typed, or only spaces, is no arguments at all")
    func empty() throws {
        #expect(try ShellWords.split("") == [])
        #expect(try ShellWords.split(" \t ") == [])
    }

    @Test(
        "A quote left open, or a lone backslash at the end, is an error rather than a guess",
        arguments: ["sh -c 'oops", #"echo "oops"#, #"echo oops\"#, #"echo "a\"#])
    func refusesUnfinished(text: String) {
        #expect(throws: AgentVMError.self) { try ShellWords.split(text) }
    }

    @Test(
        "Shown for editing, plain words stay plain and the rest is quoted",
        arguments: [
            (["ls", "-la", "/etc"], "ls -la /etc"),
            (["sh", "-c", "while :; do sleep 3600; done"], "sh -c 'while :; do sleep 3600; done'"),
            (["printf", ""], "printf ''"),
            (["echo", "it's"], #"echo 'it'\''s'"#),
            (["KEY=value", "user@host:/a,b"], "KEY=value user@host:/a,b"),
        ])
    func joins(arguments: [String], text: String) {
        #expect(ShellWords.join(arguments) == text)
    }

    @Test("Whatever the arguments, they're shown so they split back the same")
    func roundTrips() throws {
        let cases: [[String]] = [
            [], [""], ["", ""], ["a b"], ["'"], ["\""], ["\\"], ["'\\''"], ["$HOME"], ["`x`"],
            ["tab\there"], ["new\nline"], ["é", "日本", "🙂"], ["a'b\"c\\d e"], ["--flag=\"x y\""],
        ]
        for arguments in cases {
            #expect(try ShellWords.split(ShellWords.join(arguments)) == arguments, "\(arguments)")
        }

        // And a few thousand made of the characters most likely to go wrong.
        let alphabet = Array("ab ' \" \\ $`\t\n#;|&*~é🙂")
        var random = SplitMix(seed: 0x5eed)
        for _ in 0..<3_000 {
            let arguments = (0..<random.next(below: 4)).map { _ in
                String((0..<random.next(below: 7)).map { _ in alphabet[random.next(below: alphabet.count)] })
            }
            #expect(try ShellWords.split(ShellWords.join(arguments)) == arguments, "\(arguments)")
        }
    }
}

@Suite("Main process")
struct MainProcessTests {

    @Test("An instance runs the keepalive, whatever command it's given")
    func instanceRunsKeepalive() throws {
        let process = try MainProcess(mode: .instance, command: ["python3", "-m", "http.server"])
        #expect(process == .keepalive)
        #expect(process.mode == .instance)
        #expect(process.command == ["sh", "-c", "while :; do sleep 3600; done"])
    }

    @Test("A task runs its command as given: the program, then its arguments")
    func taskRunsCommand() throws {
        let process = try MainProcess(mode: .task, command: ["python3", "-m", "http.server", "8000"])
        #expect(process.mode == .task)
        #expect(process.executable == "python3")
        #expect(process.arguments == ["-m", "http.server", "8000"])
        #expect(process.command == ["python3", "-m", "http.server", "8000"])
    }

    @Test("A task needs a command, and a command needs a program", arguments: [[], [""], ["  ", "-x"]])
    func taskNeedsProgram(command: [String]) {
        #expect(throws: AgentVMError.self) { try MainProcess(mode: .task, command: command) }
    }

    @Test("The keepalive typed out as a task's command is an instance in all but name, so it is one")
    func keepaliveByHand() throws {
        let process = try MainProcess(mode: .task, command: MainProcess.keepalive.command)
        #expect(process == .keepalive)
    }

    @Test("A task's arguments may be empty strings; only the program can't be")
    func emptyArguments() throws {
        let process = try MainProcess(mode: .task, command: ["printf", ""])
        #expect(process.arguments == [""])
    }
}

/// A small seeded generator, so the round trip checks the same cases every run.
private struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(below bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Int(z % UInt64(bound))
    }
}
