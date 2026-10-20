//
//  ShellWords.swift
//  A command as typed, split into the arguments a program receives — and
//  quoted back, so it splits into the same arguments again. The rules are the
//  shell's for words and quotes and nothing more: no variables, no globs, no
//  pipes, because nothing runs through a shell. `sh -c '…'` is there for that.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

public enum ShellWords {
    /// `sh -c 'make test'` → `["sh", "-c", "make test"]`. Single quotes keep
    /// everything as written. Inside double quotes a backslash escapes only
    /// `"`, `\`, `$` and a backquote; outside quotes it escapes any character.
    /// A quote left open, or a lone backslash at the end, is an error rather
    /// than a guess.
    public static func split(_ text: String) throws -> [String] {
        var words: [String] = []
        var word = ""
        // Whether a word has begun: `''` is an argument, just an empty one.
        var inWord = false
        var quote: Character?
        var characters = text.makeIterator()

        while let character = characters.next() {
            switch quote {
            case "'":
                if character == "'" { quote = nil } else { word.append(character) }
            case "\"":
                if character == "\"" {
                    quote = nil
                } else if character == "\\" {
                    guard let next = characters.next() else { throw unclosed(quote) }
                    if "\"\\$`".contains(next) {
                        word.append(next)
                    } else if !next.isNewline {
                        word.append(character)
                        word.append(next)
                    }
                } else {
                    word.append(character)
                }
            default:
                if character == "'" || character == "\"" {
                    quote = character
                    inWord = true
                } else if character == "\\" {
                    guard let next = characters.next() else {
                        throw AgentVMError(
                            "the command ends in a lone backslash",
                            hint: "Remove it, or write \\\\ for a backslash of its own.")
                    }
                    // A backslash before a line break joins the lines.
                    if !next.isNewline {
                        word.append(next)
                        inWord = true
                    }
                } else if character.isWhitespace {
                    if inWord {
                        words.append(word)
                        word = ""
                        inWord = false
                    }
                } else {
                    word.append(character)
                    inWord = true
                }
            }
        }
        if quote != nil { throw unclosed(quote) }
        if inWord { words.append(word) }
        return words
    }

    /// Arguments back into a line that splits into the same arguments: plain
    /// words as they are, anything else in single quotes.
    public static func join(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }

    private static let plain = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")

    static func quote(_ argument: String) -> String {
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(plain.contains) { return argument }
        // A single quote can't appear inside single quotes: close them, add
        // an escaped quote, and open them again.
        return "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func unclosed(_ quote: Character?) -> AgentVMError {
        AgentVMError(
            "the command has an unclosed \(quote == "'" ? "single" : "double") quote",
            hint: "Close it, or put a backslash before a quote you mean literally.")
    }
}
