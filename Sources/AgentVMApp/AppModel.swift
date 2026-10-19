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
import AgentVMLayout
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var config: AgentVMConfig
    @Published var instances: [AgentVMInstance] = []
    @Published var selection: String? {
        // Leaving the dashboard closes the instance page over it, so coming
        // back starts from the overview.
        didSet { if selection != Self.dashboardID, dashboardInstance != nil { dashboardInstance = nil } }
    }
    /// The instance whose charts are open over the dashboard.
    @Published var dashboardInstance: String?
    @Published var daemon: AgentVMEngine.DaemonStatus?
    @Published var networkNames: Set<String> = []

    /// A one-line description of whatever long operation is in flight.
    @Published var busy: String?
    @Published var alert: AppAlert?
    @Published var showingPrune = false
    /// The last polling failure, shown in the status bar rather than as an alert.
    @Published var lastRefreshError: String?
    @Published var sessions: [String: [TerminalSession]] = [:]
    /// The session tab last chosen, per instance — where ⌘[ and ⌘] start from.
    @Published var selectedSession: [String: UUID] = [:]
    /// Which sessions are on screen and where, per instance. Present whenever
    /// the instance has sessions; one pane until you split it.
    @Published var layouts: [String: PaneLayout] = [:]
    /// Whether pane dividers snap to standard sizes (the default) or move
    /// freely. Remembered across launches.
    @Published var paneResizeMode: ResizeMode {
        didSet { if Self.remembersPreferences { UserDefaults.standard.set(paneResizeMode.rawValue, forKey: Self.resizeModeKey) } }
    }
    private static let resizeModeKey = "paneResizeMode"
    /// How often the dashboard reads each instance and this Mac, in seconds.
    /// Remembered across launches.
    @Published var samplingInterval: TimeInterval {
        didSet {
            if Self.remembersPreferences { UserDefaults.standard.set(samplingInterval, forKey: Self.samplingIntervalKey) }
            if samplingInterval != oldValue { resources.intervalChanged(self) }
        }
    }
    private static let samplingIntervalKey = "samplingInterval"
    /// Shell sessions as panes of Liquid Glass over the desktop, or solid
    /// terminals. Remembered across launches.
    @Published var glassSessions: Bool {
        didSet {
            if Self.remembersPreferences { UserDefaults.standard.set(glassSessions, forKey: Self.glassSessionsKey) }
            for session in sessions.values.joined() { session.terminalView.isGlass = glassSessions }
        }
    }
    private static let glassSessionsKey = "glassSessions"
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
            if Self.remembersPreferences { UserDefaults.standard.set(Double(terminalFontSize), forKey: Self.fontSizeKey) }
            for session in sessions.values.joined() { session.terminalView.applyFontSize(terminalFontSize) }
        }
    }
    private static let fontSizeKey = "terminalFontSize"

    let engine = AgentVMEngine.shared
    /// The dashboard's readings, taken only while it's on screen.
    let resources = ResourceMonitor()
    private var refreshTask: Task<Void, Never>?

    /// The sidebar's Dashboard row, in the same selection as the instances.
    /// A container name can't start with `#`, so it never matches one.
    static let dashboardID = "#dashboard"

    var showingDashboard: Bool { selection == Self.dashboardID }

    /// Slides an instance's charts in over the dashboard.
    func openDashboardPage(_ name: String) {
        withAnimation(Self.pageAnimation) { dashboardInstance = name }
    }

    /// Back to the dashboard: the page slides off the way it came. A swipe
    /// that has already carried it off closes it without sliding it again.
    func closeDashboardPage(animated: Bool = true) {
        guard dashboardInstance != nil else { return }
        if animated {
            withAnimation(Self.pageAnimation) { dashboardInstance = nil }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dashboardInstance = nil }
        }
    }

    static let pageAnimation = Animation.smooth(duration: 0.3)

    struct AppAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// Whether preferences are read and written. Not during the UI tour: it
    /// runs with the defaults, so its pictures don't depend on whoever ran
    /// it, and nothing it changes outlives it.
    private static var remembersPreferences: Bool {
        #if DEBUG
            UITour.directory == nil
        #else
            true
        #endif
    }

    init() {
        config = (try? AgentVMConfig.load()) ?? AgentVMConfig()
        let defaults = Self.remembersPreferences ? UserDefaults.standard : nil
        let stored = defaults?.double(forKey: Self.fontSizeKey) ?? 0
        terminalFontSize = stored > 0 ? CGFloat(stored) : AgentVMTerminalView.defaultFontSize
        paneResizeMode = ResizeMode(rawValue: defaults?.string(forKey: Self.resizeModeKey) ?? "") ?? .snap
        samplingInterval = SamplingInterval.validated(defaults?.double(forKey: Self.samplingIntervalKey) ?? 0)
        glassSessions = defaults?.object(forKey: Self.glassSessionsKey) as? Bool ?? true
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
            if let name = dashboardInstance, !instances.contains(where: { $0.fullName == name }) {
                dashboardInstance = nil
            }
            if let selection, selection != Self.dashboardID, !instances.contains(where: { $0.fullName == selection }) {
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
            layouts[instance.fullName] = nil
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
            for name in result.containers {
                endSessions(for: name)
                sessions[name] = nil
                layouts[name] = nil
            }
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

    /// Opens a shell session and shows it: in the focused pane, or in `pane`
    /// when given — an empty zone's New Session button.
    @discardableResult
    func openSession(
        in instance: AgentVMInstance, command: [String] = ["sh"], workingDirectory: String? = nil,
        intoPane pane: PaneContent? = nil
    ) -> TerminalSession? {
        guard let session = makeSession(in: instance, command: command, workingDirectory: workingDirectory) else {
            return nil
        }
        let name = instance.fullName
        sessions[name, default: []].append(session)
        if let pane, var layout = layouts[name], layout.show(session: session.id, in: pane) {
            layouts[name] = layout
            selectedSession[name] = session.id
        } else {
            reveal(session.id, in: name)
        }
        return session
    }

    /// A started session, not yet listed as a tab or shown in a pane.
    private func makeSession(
        in instance: AgentVMInstance, command: [String], workingDirectory: String?
    ) -> TerminalSession? {
        guard instance.isRunning else {
            alert = AppAlert(
                title: "\(instance.shortName) is not running",
                message: "Start it first — a session is a process inside a running instance.")
            return nil
        }
        let name = instance.fullName
        let session = TerminalSession(instanceName: name, command: command, fontSize: terminalFontSize)
        session.terminalView.isGlass = glassSessions
        let id = session.id
        session.terminalView.onFontSizeRequest = { [weak self] size in self?.setTerminalFontSize(size) }
        session.terminalView.onSwipe = { [weak self] offset in self?.selectAdjacentSession(offset, in: name) }
        // A click into a terminal gives its pane the focus.
        session.terminalView.onActivate = { [weak self] in self?.focusPane(.session(id), in: name) }
        session.start(engine: engine, instance: instance, workingDirectory: workingDirectory)
        return session
    }

    /// Shows a session the way clicking its tab does: its pane takes the focus
    /// if it's on screen; otherwise it appears in the focused pane.
    func reveal(_ id: UUID, in name: String) {
        selectedSession[name] = id
        if var layout = layouts[name] {
            layout.reveal(session: id)
            layouts[name] = layout
        } else {
            layouts[name] = PaneLayout(session: id)
        }
    }

    /// Closes one session tab. The instance is untouched.
    func closeSession(_ session: TerminalSession) {
        session.terminate()
        let name = session.instanceName
        let index = sessions[name]?.firstIndex { $0.id == session.id }
        sessions[name]?.removeAll { $0.id == session.id }
        let remaining = (sessions[name] ?? []).map(\.id)
        let next = PaneLayout.closing(session.id, from: layouts[name], remaining: remaining, at: index)
        layouts[name] = next?.layout
        selectedSession[name] = next?.selected
    }

    /// Replaces an ended session with a fresh one running the same command,
    /// in the same tab position and the same pane.
    func reopenSession(_ session: TerminalSession) {
        guard let instance = instances.first(where: { $0.fullName == session.instanceName }),
            let replacement = makeSession(in: instance, command: session.command, workingDirectory: nil)
        else { return }
        let name = session.instanceName
        var list = sessions[name] ?? []
        if let index = list.firstIndex(where: { $0.id == session.id }) {
            list[index] = replacement
        } else {
            list.append(replacement)
        }
        session.terminate()
        sessions[name] = list
        if var layout = layouts[name], layout.replace(session: session.id, with: replacement.id) {
            layout.focus(.session(replacement.id))
            layouts[name] = layout
            selectedSession[name] = replacement.id
        } else {
            reveal(replacement.id, in: name)
        }
    }

    /// Next or previous session tab, wrapping around.
    func selectAdjacentSession(_ offset: Int, in instanceName: String? = nil) {
        guard let name = instanceName ?? selection, let list = sessions[name], !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selectedSession[name] } ?? list.count - 1
        let next = (current + offset % list.count + list.count) % list.count
        reveal(list[next].id, in: name)
    }

    func selectSession(number: Int) {
        guard let name = selection, let list = sessions[name], !list.isEmpty else { return }
        // ⌘9 is always the last tab, as in Safari and Terminal.
        let index = number == 9 ? list.count - 1 : number - 1
        guard list.indices.contains(index) else { return }
        reveal(list[index].id, in: name)
    }

    /// The session the keyboard goes to. Nil while an empty zone has the focus.
    var selectedSessionForCurrentInstance: TerminalSession? {
        guard let name = selection, let list = sessions[name] else { return nil }
        if let layout = layouts[name] {
            return layout.focusedSession.flatMap { id in list.first { $0.id == id } }
        }
        return list.first { $0.id == selectedSession[name] } ?? list.last
    }

    // MARK: - Split panes

    func focusPane(_ pane: PaneContent, in name: String) {
        guard var layout = layouts[name], layout.focused != pane, layout.focus(pane) else { return }
        layouts[name] = layout
        if let id = pane.sessionID { selectedSession[name] = id }
    }

    /// Drops a session onto a pane, as dragging its tab there does.
    func snap(_ sessionID: UUID, to target: DropTarget, in name: String) {
        guard var layout = layouts[name], layout.snap(session: sessionID, to: target) else { return }
        layouts[name] = layout
        selectedSession[name] = sessionID
    }

    /// Puts a session into a particular pane — an empty zone, say.
    func show(_ sessionID: UUID, inPane pane: PaneContent, in name: String) {
        guard var layout = layouts[name], layout.show(session: sessionID, in: pane) else { return }
        layouts[name] = layout
        selectedSession[name] = sessionID
    }

    /// Takes a pane out of the split. A session in it stays a tab.
    func removePane(_ pane: PaneContent, in name: String) {
        guard var layout = layouts[name], layout.remove(pane: pane) else { return }
        layouts[name] = layout
        if let id = layout.focusedSession { selectedSession[name] = id }
    }

    /// Rearranges into a template, the focused session in zone `focusZone`.
    func applyTemplate(_ template: LayoutTemplate, focusZone: Int = 0, in name: String) {
        guard var layout = layouts[name] else { return }
        layout.apply(template, focusZone: focusZone, tabOrder: (sessions[name] ?? []).map(\.id))
        layouts[name] = layout
        if let id = layout.focusedSession { selectedSession[name] = id }
    }

    func moveDivider(_ divider: PaneDivider, to boundary: Double, in name: String) {
        guard var layout = layouts[name],
            layout.moveDivider(
                divider.id, to: boundary, mode: paneResizeMode, length: divider.length,
                minimumSize: PaneMetrics.minimumSize, gap: PaneMetrics.gap(glass: glassSessions))
        else { return }
        layouts[name] = layout
    }

    /// The selected instance's layout, for the menu bar.
    var selectedLayout: PaneLayout? { selection.flatMap { layouts[$0] } }

    func applyTemplateToSelection(_ template: LayoutTemplate) {
        guard let name = selection else { return }
        applyTemplate(template, in: name)
    }

    func removeFocusedPane() {
        guard let name = selection, let layout = layouts[name], layout.isSplit else { return }
        removePane(layout.focused, in: name)
    }

    func equalizeSplit(at path: [Int], in name: String) {
        guard var layout = layouts[name], layout.equalize(splitAt: path) else { return }
        layouts[name] = layout
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
