//
//  DashboardScreen.swift
//  The dashboard, and an instance's charts pushed over it. Back is the way
//  pages go back on a Mac: a two-finger swipe to the right that the page
//  follows, as in Safari and Finder — or three fingers, if that's what "Swipe
//  between pages" is set to — the mouse's back button, ⌘[, or the toolbar's
//  back button.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AgentVMKit
import AppKit
import SwiftUI

struct DashboardScreen: View {
    @Environment(AppModel.self) private var model
    let monitor: ResourceMonitor
    @Binding var showingNewInstance: Bool
    /// How far a back swipe has carried the page off, 0…1.
    @State private var swipe: CGFloat = 0

    private var page: AgentVMInstance? {
        model.dashboardInstance.flatMap { name in model.instances.first { $0.fullName == name } }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                DashboardView(monitor: monitor, showingNewInstance: $showingNewInstance)
                    .allowsHitTesting(page == nil)
                    .accessibilityHidden(page != nil)
                if let page {
                    InstanceUsageView(instance: page, monitor: monitor)
                        .background(DashboardColor.page)
                        // The edge the dashboard shows past while the page
                        // follows a swipe.
                        .overlay(alignment: .leading) {
                            LinearGradient(
                                colors: [.black.opacity(0), .black.opacity(0.16)], startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 14)
                            .offset(x: -14)
                            .opacity(swipe > 0 ? 1 : 0)
                            .allowsHitTesting(false)
                        }
                        .offset(x: geometry.size.width * swipe)
                        .background {
                            SwipeBack(
                                onProgress: { swipe = $0 },
                                onFinish: { wentBack in
                                    if wentBack { model.closeDashboardPage(animated: false) }
                                    swipe = 0
                                },
                                onBack: { model.closeDashboardPage() })
                        }
                        .transition(.move(edge: .trailing))
                        .zIndex(1)
                }
            }
            .clipped()
        }
        .navigationTitle(page?.shortName ?? "Dashboard")
        .navigationSubtitle(page.map { InstanceUsageView.subtitle(for: $0, history: monitor.histories[$0.fullName]) }
            ?? DashboardView.subtitle(for: model))
        .toolbar {
            if let page {
                ToolbarItem(placement: .navigation) {
                    Button {
                        model.closeDashboardPage()
                    } label: {
                        Label("Dashboard", systemImage: "chevron.backward")
                    }
                    .featureTip("Back to the dashboard")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.selection = page.fullName
                    } label: {
                        Label("Show Instance", systemImage: "terminal")
                    }
                    .featureTip("Show the instance")
                }
            }
        }
        .onAppear { monitor.dashboardAppeared(model) }
        .onDisappear { monitor.dashboardDisappeared() }
        #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: UITour.swipeTo)) { note in
                if let amount = note.object as? CGFloat { swipe = amount }
            }
        #endif
    }
}

/// Back, as the Mac does it for pages. A two-finger horizontal swipe is
/// tracked with AppKit's own fluid-swipe tracking, so the page follows the
/// fingers and finishes — or springs back — with the same feel as Safari's.
/// It applies only over the view it backs, and never takes a click.
struct SwipeBack: NSViewRepresentable {
    /// How far a two-finger swipe has carried the page, 0…1, as it goes.
    var onProgress: (CGFloat) -> Void
    /// The two-finger swipe is over: true if it went through.
    var onFinish: (Bool) -> Void
    /// Back with nothing to follow: a three-finger swipe or the back button.
    var onBack: () -> Void

    func makeNSView(context: Context) -> SwipeBackView { SwipeBackView() }

    func updateNSView(_ view: SwipeBackView, context: Context) {
        view.onProgress = onProgress
        view.onFinish = onFinish
        view.onBack = onBack
    }

    static func dismantleNSView(_ view: SwipeBackView, coordinator: ()) {
        view.stopWatching()
    }
}

final class SwipeBackView: NSView {
    var onProgress: ((CGFloat) -> Void)?
    var onFinish: ((Bool) -> Void)?
    var onBack: (() -> Void)?

    private var monitor: Any?
    private var tracking = false
    /// Whether the scroll gesture under way has been seen to be vertical, so
    /// it's left to the scroll view however it wanders.
    private var vertical = false

    /// The mouse button browsers use for Back.
    private static let backButton = 3

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopWatching() } else { startWatching() }
    }

    func startWatching() {
        guard monitor == nil else { return }
        // A local monitor sees each event before the view under the pointer
        // does — the scroll view the page is in, here — and can keep it.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe, .otherMouseDown]) {
            [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }
    }

    func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func isOver(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        return bounds.contains(convert(event.locationInWindow, from: nil))
    }

    /// True when the event was back, and is used up.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .scrollWheel:
            return trackSwipe(event)
        case .swipe:
            // A three-finger swipe: +1 is to the right, back.
            guard event.deltaX > 0, isOver(event) else { return false }
            onBack?()
            return true
        case .otherMouseDown:
            guard event.buttonNumber == Self.backButton, isOver(event) else { return false }
            onBack?()
            return true
        default:
            return false
        }
    }

    private func trackSwipe(_ event: NSEvent) -> Bool {
        if event.phase == .began { vertical = false }
        guard !tracking, !vertical, event.phase == .began || event.phase == .changed,
            NSEvent.isSwipeTrackingFromScrollEventsEnabled, isOver(event)
        else { return false }
        let dx = abs(event.scrollingDeltaX)
        let dy = abs(event.scrollingDeltaY)
        // Undecided until the fingers have moved.
        guard dx > 0 || dy > 0 else { return false }
        guard dx > dy else {
            vertical = true
            return false
        }

        tracking = true
        var wentBack = false
        // Back only: 0 to 1. A swipe the other way gives elastic resistance.
        event.trackSwipeEvent(
            options: [.lockDirection, .clampGestureAmount], dampenAmountThresholdMin: 0, max: 1
        ) { [weak self] amount, phase, isComplete, _ in
            guard let self else { return }
            // Ended means the fingers let go past the point of no return;
            // the amount then animates on to 1, or back to 0 if cancelled.
            if phase == .ended { wentBack = true }
            if phase == .cancelled { wentBack = false }
            self.onProgress?(min(1, max(0, amount)))
            if isComplete {
                self.tracking = false
                self.onFinish?(wentBack && amount > 0.5)
            }
        }
        return true
    }
}
