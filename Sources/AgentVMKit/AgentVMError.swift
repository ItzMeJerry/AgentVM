//
//  AgentVMError.swift
//  Errors raised by AgentVMKit itself (as opposed to ContainerizationError, which
//  comes back from the container daemon over XPC).
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

public struct AgentVMError: LocalizedError, Sendable {
    public let message: String
    public let hint: String?

    public init(_ message: String, hint: String? = nil) {
        self.message = message
        self.hint = hint
    }

    public var errorDescription: String? { message }
    public var recoverySuggestion: String? { hint }
}

extension Error {
    /// A message fit for a UI alert, unwrapping the layers the container client
    /// wraps around the underlying failure.
    public var agentVMDisplayMessage: String {
        if let error = self as? AgentVMError {
            guard let hint = error.hint else { return error.message }
            return "\(error.message)\n\n\(hint)"
        }
        return "\(self)"
    }
}
