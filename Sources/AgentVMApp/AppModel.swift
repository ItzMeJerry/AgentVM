//
//  AppModel.swift
//  The app's single source of truth: config, the instance list, sessions, and
//  every operation the UI can start.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import AgentVMKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var config: AgentVMConfig
    @Published var instances: [AgentVMInstance] = []
    @Published var selection: String?
    @Published var daemon: AgentVMEngine.DaemonStatus?
    @Published var networkNames: Set<String> = []

    /// A one-line description of whatever long operation is in flight.
    @Published var busy: String?
    @Published var alert: AppAlert?
    @Published var showingPrune = false
    /// The last polling failure, shown in the status bar rather than as an alert.
    @Published var lastRefreshError: String?
    @Published var sessions: [String: [TerminalSession]] = [:]
    @Published var selectedSession: [String: UUID] = [:]
    /// Instances whose baked-in environment predates the current registry.
    @Published var staleEnvironment: Set<String> = []
    /// The instance a Delete is waiting on confirmation for, from wherever it
    /// was asked: the header, the sidebar's menu, or a swipe.
    @Published var pendingDelete: AgentVMInstance?
    /// The instance whose Ports sheet is open.
    @Published var editingPorts: AgentVMInstance?
    /// One size for every terminal, so a pinch in one tab doesn't leave the
    /// others behind. Remembered across launches.
    @Published var terminalFontSize: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(terminalFontSize), forKey: Self.fontSizeKey)
            for session in sessions.values.joined() { session.terminalView.applyFontSize(terminalFontSize) }
        }
    }
    private static let fontSizeKey = "terminalFontSize"

    let engine = AgentVMEngine.shared
    private var refreshTask: Task<Void, Never>?

    struct AppAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    init() {
        config = (try? AgentVMConfig.load()) ?? AgentVMConfig()
        let stored = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        terminalFontSize = stored > 0 ? CGFloat(stored) : AgentVMTerminalView.defaultFontSize
    }

    var selectedInstance: AgentVMInstance? {
        instances.first { $0.fullName == selection }
    }

    var registry: EnvRegistry { EnvRegistry(url: config.envFileURL) }

    // MARK: - Polling

    /// The daemon has no change feed, so the list is polled while the window is
    /// up. Cheap: one XPC round trip.
    func startPolling() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopPolling() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        let status = await engine.daemonStatus()
        daemon = status
        guard status.running else {
            instances = []
            return
        }
        do {
            let config = self.config
            instances = try await engine.list(config: config)
            lastRefreshError = nil
            networkNames = (try? await engine.agentVMNetworkNames(config: config)) ?? []
            recomputeStaleEnvironment()
            if let selection, !instances.contains(where: { $0.fullName == selection }) {
                self.selection = instances.first?.fullName
            }
            if selection == nil { selection = instances.first?.fullName }
        } catch {
            // Polling runs every couple of seconds: a transient XPC hiccup must
            // neither clear the list under the user nor raise a wall of alerts.
            // The next tick recovers; a real outage shows up as the status light.
            lastRefreshError = error.agentVMDisplayMessage
        }
    }

    private func recomputeStaleEnvironment() {
        guard let registryModified = registry.modifiedAt else {
            staleEnvironment = []
            return
        }
        staleEnvironment = Set(
            instances.filter { $0.createdAt < registryModified && !$0.envKeys.isEmpty }
                .map(\.fullName))
    }

    // MARK: - Operations

    func create(spec: RunSpec) async -> Bool {
        busy = "Preparing"
        defer { busy = nil }
        do {
            let name = try await engine.create(spec: spec, config: config) { [weak self] step in
                Task { @MainActor in self?.busy = step }
            }
            await refresh()
            selection = name
            return true
        } catch {
            report(error, title: "Could not create the instance")
            return false
        }
    }

    func start(_ instance: AgentVMInstance) async {
        busy = "Starting \(instance.shortName)"
        defer { busy = nil }
        do {
            try await engine.start(instance)
            await refresh()
        } catch {
            report(error, title: "Could not start \(instance.shortName)")
        }
    }

    func stop(_ instance: AgentVMInstance) async {
        busy = "Stopping \(instance.shortName)"
        defer { busy = nil }
        do {
            try await engine.stop(instance)
            endSessions(for: instance.fullName)
            await refresh()
        } catch {
            report(error, title: "Could not stop \(instance.shortName)")
        }
    }

    func delete(_ instance: AgentVMInstance, force: Bool) async {
        busy = "Removing \(instance.shortName)"
        defer { busy = nil }
        do {
            try await engine.delete(instance, force: force)
            endSessions(for: instance.fullName)
            sessions[instance.fullName] = nil
            await refresh()
        } catch {
            report(error, title: "Could not remove \(instance.shortName)")
        }
    }

    /// Rewrites a stopped instance's published ports, optionally starting it
    /// straight after. Returns the failure for the sheet to show in place —
    /// an alert behind a sheet is easy to miss.
    func setPorts(_ ports: [PortMapping], on instance: AgentVMInstance, thenStart: Bool) async -> String? {
        busy = "Changing the ports of \(instance.shortName)"
        do {
            try await engine.setPorts(ports, on: instance)
        } catch {
            busy = nil
            return error.agentVMDisplayMessage
        }
        busy = nil
        await refresh()
        if thenStart, let updated = instances.first(where: { $0.fullName == instance.fullName }) {
            await start(updated)
        }
        return nil
    }

    func prune() async {
        busy = "Pruning"
        defer { busy = nil }
        do {
            let result = try await engine.prune(config: config)
            for name in result.containers { endSessions(for: name); sessions[name] = nil }
            await refresh()
            if !result.failures.isEmpty {
                alert = AppAlert(
                    title: "Pruned with problems",
                    message: result.failures.joined(separator: "\n"))
            }
        } catch {
            report(error, title: "Could not prune")
        }
    }

    // MARK: - Sessions

    @discardableResult
    func openSession(in instance: AgentVMInstance, command: [String] = ["sh"], workingDirectory: String? = nil)
        -> TerminalSession?
    {
        guard instance.isRunning else {
            alert = AppAlert(
                title: "\(instance.shortName) is not running",
                message: "Start it first — a session is a process inside a running instance.")
            return nil
        }
        let session = TerminalSession(instanceName: instance.fullName, command: command, fontSize: terminalFontSize)
        session.terminalView.onFontSizeRequest = { [weak self] size in self?.setTerminalFontSize(size) }
        session.terminalView.onSwipe = { [weak self] offset in
            self?.selectAdjacentSession(offset, in: instance.fullName)
        }
        sessions[instance.fullName, default: []].append(session)
        selectedSession[instance.fullName] = session.id
        session.start(engine: engine, instance: instance, workingDirectory: workingDirectory)
        return session
    }

    /// Closes one session tab. The instance is untouched.
    func closeSession(_ session: TerminalSession) {
        session.terminate()
        let name = session.instanceName
        let index = sessions[name]?.firstIndex { $0.id == session.id }
        sessions[name]?.removeAll { $0.id == session.id }
        if selectedSession[name] == session.id, let list = sessions[name], let index {
            // The neighbour takes its place, as when closing a browser tab.
            selectedSession[name] = list.isEmpty ? nil : list[min(index, list.count - 1)].id
        }
    }

    /// Replaces an ended session with a fresh one running the same command,
    /// in the same tab position.
    func reopenSession(_ session: TerminalSession) {
        guard let instance = instances.first(where: { $0.fullName == session.instanceName }),
            let replacement = openSession(in: instance, command: session.command)
        else { return }
        var list = sessions[session.instanceName] ?? []
        list.removeAll { $0.id == replacement.id }
        if let index = list.firstIndex(where: { $0.id == session.id }) {
            list[index] = replacement
        } else {
            list.append(replacement)
        }
        session.terminate()
        sessions[session.instanceName] = list
        selectedSession[session.instanceName] = replacement.id
    }

    /// Next or previous session tab, wrapping around.
    func selectAdjacentSession(_ offset: Int, in instanceName: String? = nil) {
        guard let name = instanceName ?? selection, let list = sessions[name], !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selectedSession[name] } ?? list.count - 1
        let next = (current + offset % list.count + list.count) % list.count
        selectedSession[name] = list[next].id
    }

    func selectSession(number: Int) {
        guard let name = selection, let list = sessions[name], !list.isEmpty else { return }
        // ⌘9 is always the last tab, as in Safari and Terminal.
        let index = number == 9 ? list.count - 1 : number - 1
        guard list.indices.contains(index) else { return }
        selectedSession[name] = list[index].id
    }

    var selectedSessionForCurrentInstance: TerminalSession? {
        guard let name = selection, let list = sessions[name] else { return nil }
        return list.first { $0.id == selectedSession[name] } ?? list.last
    }

    func setTerminalFontSize(_ size: CGFloat) {
        let range = AgentVMTerminalView.fontSizeRange
        terminalFontSize = min(max(size.rounded(), range.lowerBound), range.upperBound)
    }

    private func endSessions(for instanceName: String) {
        sessions[instanceName]?.forEach { $0.terminate() }
    }

    // MARK: - Config and registry

    func reloadConfig() {
        config = (try? AgentVMConfig.load()) ?? AgentVMConfig()
    }

    func saveConfig(_ newValue: AgentVMConfig) {
        do {
            try newValue.save()
            config = newValue
        } catch {
            report(error, title: "Could not write the config file")
        }
    }

    func saveRegistry(_ entries: [EnvEntry]) {
        do {
            try registry.save(entries)
            recomputeStaleEnvironment()
        } catch {
            report(error, title: "Could not write the env registry")
        }
    }

    func report(_ error: Error, title: String) {
        alert = AppAlert(title: title, message: error.agentVMDisplayMessage)
    }
}
