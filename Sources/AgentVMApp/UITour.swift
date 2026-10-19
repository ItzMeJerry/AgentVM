//
//  UITour.swift
//  Development only (DEBUG builds): screenshots of every main screen, for
//  reviewing the interface without clicking through it.
//
//      bash Scripts/build-app.sh debug
//      AGENTVM_UI_TOUR=/tmp/agentvm-tour .build/AgentVM.app/Contents/MacOS/AgentVM
//
//  AGENTVM_UI_TOUR_APPEARANCE=light (or dark) shows it in that appearance
//  whatever the system's is set to.
//
//  The tour works in a world of its own: names under `agentvmtour-`, so it
//  neither sees nor touches real instances; a throwaway env registry with
//  made-up values, so no secret can end up in a picture; and the default
//  preferences — text size, reading interval — neither read nor saved. It
//  creates what it shows from alpine:3.20, saves a PNG per screen, deletes
//  it all and quits.
//
//  Each shot is the window as the window server composites it, Liquid Glass
//  included. Only the app's own windows are captured, which needs no
//  screen-recording permission. The tour brings its window to the front while
//  it runs, so the shots show the active appearance.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

#if DEBUG
import AgentVMKit
import AgentVMLayout
import AppKit
import SwiftUI

@MainActor
enum UITour {
    /// Asks the instance detail view to show a tab.
    static let showTab = Notification.Name("AgentVMUITourShowTab")
    /// Holds the dashboard's instance page part-way through a back swipe.
    static let swipeTo = Notification.Name("AgentVMUITourSwipeTo")
    /// Reads back a moment on every chart, as pointing at it does: the object
    /// is how far along the chart's span, 0…1, or nil to stop. A synthetic
    /// pointer can't do this reliably — the real cursor's position wins each
    /// time the charts redraw.
    static let scrubTo = Notification.Name("AgentVMUITourScrubTo")

    static var directory: URL? {
        ProcessInfo.processInfo.environment["AGENTVM_UI_TOUR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static func run(model: AppModel, in directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var log: [String] = []
        func note(_ line: String) { log.append(line) }

        // A world of its own.
        let registry = FileManager.default.temporaryDirectory.appending(path: "agentvm-tour-env")
        try? "API_KEY=example\nGITHUB_TOKEN=example\n".write(to: registry, atomically: true, encoding: .utf8)
        var config = AgentVMConfig()
        config.namePrefix = "agentvmtour-"
        config.envFilePath = registry.path(percentEncoded: false)
        model.config = config
        switch ProcessInfo.processInfo.environment["AGENTVM_UI_TOUR_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }

        guard let window = await mainWindow() else {
            note("no main window")
            finish(log, in: directory)
            return
        }
        window.setFrame(NSRect(x: 80, y: 80, width: 1240, height: 780), display: true)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

        await wait { model.daemon?.running == true }
        await model.refresh()
        // Long enough for the first frame to reach the screen.
        await pause(2.5)
        await shot(window, "01-empty-state", in: directory)

        // Instances to show: a running one, and a stopped killswitch one.
        let created = await model.create(spec: spec(name: "demo", net: .open))
        let offline = await model.create(spec: spec(name: "offline", net: .killswitch))
        note("created demo=\(created) offline=\(offline)")
        await model.refresh()
        if let instance = model.instances.first(where: { $0.shortName == "offline" }) {
            await model.stop(instance)
        }
        await model.refresh()
        guard let demo = model.instances.first(where: { $0.shortName == "demo" }) else {
            note("demo instance missing")
            await cleanUp(model)
            finish(log, in: directory)
            return
        }

        model.selection = demo.fullName
        tab("Sessions")
        await pause(1.5)
        await shot(window, "02-sessions-empty", in: directory)

        let commands = ["ls -la /etc | head -24", "top -b -n 1 | head -20", "cat /etc/os-release; uname -a"]
        for command in commands {
            if let session = model.openSession(in: demo) {
                await pause(1.2)
                session.terminalView.send(txt: command + "\n")
            }
        }
        await pause(2)
        await shot(window, "03-sessions-one-pane", in: directory)

        model.applyTemplate(.halves, in: demo.fullName)
        await pause(1.5)
        await shot(window, "04-split-halves", in: directory)
        // The same split as solid terminals, for comparison.
        model.glassSessions = false
        await pause(1.2)
        await shot(window, "04b-split-halves-solid", in: directory)
        model.glassSessions = true
        await pause(0.8)

        model.applyTemplate(.quarters, in: demo.fullName)
        await pause(1.5)
        await shot(window, "05-split-quarters-with-empty-zone", in: directory)

        // Something for the dashboard to show: a core kept busy for a while,
        // and a burst of writes.
        model.sessions[demo.fullName]?.first?.terminalView.send(
            txt: "timeout 60 sh -c 'while :; do :; done' & dd if=/dev/zero of=/tmp/tour bs=1M count=256; rm /tmp/tour\n")
        model.selection = AppModel.dashboardID
        // Readings every second for these shots, which also checks that a
        // change of pace carries the lines on. The tour never saves it.
        let interval = model.samplingInterval
        model.samplingInterval = 1
        // Long enough for a few readings, so the lines have a shape.
        await pause(10)
        await shot(window, "06-dashboard", in: directory)
        // Pointing at a line reads that moment back.
        NotificationCenter.default.post(name: scrubTo, object: 0.9)
        await pause(0.8)
        await shot(window, "06b-dashboard-pointing", in: directory)
        NotificationCenter.default.post(name: scrubTo, object: nil)

        // An instance's own page, pushed over the dashboard.
        model.openDashboardPage(demo.fullName)
        await pause(1.5)
        await shot(window, "06c-instance-charts", in: directory)
        // Pointing at one chart marks that moment on every chart.
        NotificationCenter.default.post(name: scrubTo, object: 0.9)
        await pause(0.8)
        await shot(window, "06d-instance-charts-pointing", in: directory)
        NotificationCenter.default.post(name: scrubTo, object: nil)
        // Part-way through a two-finger swipe back.
        NotificationCenter.default.post(name: swipeTo, object: CGFloat(0.4))
        await pause(0.8)
        await shot(window, "06e-swipe-back-midway", in: directory)
        NotificationCenter.default.post(name: swipeTo, object: CGFloat(0))
        model.closeDashboardPage()
        model.samplingInterval = interval
        await pause(1)
        let wide = window.frame
        window.setFrame(NSRect(x: wide.minX, y: wide.minY, width: 940, height: wide.height), display: true)
        await pause(2.5)
        await shot(window, "07-dashboard-narrow", in: directory)
        model.openDashboardPage(demo.fullName)
        await pause(1.5)
        await shot(window, "07c-instance-charts-narrow", in: directory)
        model.closeDashboardPage()
        await pause(0.5)
        window.setFrame(wide, display: true)

        // As it looks with the container service down — shown, not caused:
        // polling pauses and the app is told the service didn't answer.
        model.stopPolling()
        await pause(0.5)
        let live = (daemon: model.daemon, instances: model.instances)
        model.daemon = .notRunning
        model.instances = []
        await pause(1.5)
        await shot(window, "07b-dashboard-service-down", in: directory)
        model.daemon = live.daemon
        model.instances = live.instances
        model.startPolling()

        model.selection = demo.fullName
        model.applyTemplate(.single, in: demo.fullName)
        // Coming from the dashboard, the instance's view has to exist before
        // it can hear which tab to show.
        await pause(0.8)
        tab("Logs")
        await pause(1.5)
        await shot(window, "08-logs", in: directory)

        tab("Inspect")
        await pause(1.2)
        await shot(window, "09-inspect", in: directory)

        if let stopped = model.instances.first(where: { $0.shortName == "offline" }) {
            model.selection = stopped.fullName
            tab("Sessions")
            await pause(1.2)
            await shot(window, "10-stopped-instance", in: directory)
        }

        // Sheets and windows, each in a window of its own.
        await render(NewInstanceSheet().environmentObject(model), "11-new-instance", in: directory)
        await render(PortsSheet(instance: demo).environmentObject(model), "12-ports", in: directory)
        await render(SettingsView().environmentObject(model), "13-settings", in: directory)
        await render(HelpView(), "14-help", in: directory)
        await render(
            LayoutPicker(current: .halves, mode: .constant(.snap)) { _, _ in }, "15-layout-picker", in: directory)

        await cleanUp(model)
        finish(log, in: directory)
    }

    // MARK: - Steps

    private static func spec(name: String, net: NetPosture) -> RunSpec {
        var spec = RunSpec()
        spec.image = "alpine:3.20"
        spec.name = name
        spec.net = net
        spec.mode = .instance
        spec.useRegistry = true
        return spec
    }

    private static func tab(_ name: String) {
        NotificationCenter.default.post(name: showTab, object: name)
    }

    private static func cleanUp(_ model: AppModel) async {
        for session in model.sessions.values.joined() { model.closeSession(session) }
        await model.refresh()
        for instance in model.instances where instance.fullName.hasPrefix("agentvmtour-") {
            await model.delete(instance, force: true)
        }
    }

    private static func finish(_ log: [String], in directory: URL) {
        try? log.joined(separator: "\n").write(to: directory.appending(path: "tour.log"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    // MARK: - Capturing

    private static func mainWindow() async -> NSWindow? {
        for _ in 0..<50 {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title == "AgentVM" }) {
                return window
            }
            await pause(0.2)
        }
        return NSApp.windows.first { $0.isVisible }
    }

    /// The window as drawn, title bar and toolbar included.
    private static func shot(_ window: NSWindow, _ name: String, in directory: URL) async {
        window.displayIfNeeded()
        save(window, to: directory.appending(path: "\(name).png"))
    }

    /// A view in a titled window of its own, sized to fit it.
    private static func render(_ content: some View, _ name: String, in directory: URL) async {
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: max(size.width, 200), height: max(size.height, 120)),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        await pause(1.2)
        save(window, to: directory.appending(path: "\(name).png"))
        window.orderOut(nil)
    }

    /// The window exactly as the window server composites it — Liquid Glass,
    /// materials and all. It's the app's own window, which needs no
    /// screen-recording permission. CGWindowListCreateImage is hidden from the
    /// macOS 26 SDK, so it's looked up at run time.
    private static func save(_ window: NSWindow, to url: URL) {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3
        let ignoreFramingAtBestResolution: UInt32 = (1 << 0) | (1 << 3)
        guard
            let image = createImage(.null, includingWindow, UInt32(window.windowNumber), ignoreFramingAtBestResolution)?
                .takeRetainedValue()
        else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func wait(timeout: Double = 15, until condition: () -> Bool) async {
        var waited = 0.0
        while !condition() && waited < timeout {
            await pause(0.25)
            waited += 0.25
        }
    }
}
#endif
