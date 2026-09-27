//
//  AgentVMTerminalView.swift
//  SwiftTerm's view with trackpad handling that feels like Terminal.app.
//
//  Stock SwiftTerm turns every wheel event into 1, 3, 10 or a page of lines
//  based on its coarse delta, so a trackpad flick jumps and a slow drag
//  stutters, and inside vim or less a scroll does nothing at all. Here:
//
//  - precise (trackpad) deltas are accumulated in points and spent a line at
//    a time, momentum included, so scrolling tracks the fingers;
//  - when the program asked for mouse reporting, the wheel is reported to it;
//  - on the alternate screen without mouse reporting (less, man, git log),
//    the wheel becomes arrow keys, as Terminal.app does;
//  - pinch zooms the font, a two-finger double tap resets it;
//  - a right click (or two-finger click) opens a context menu.
//
//  SwiftTerm's `scrollWheel` is `public`, not `open`, so it can't be
//  overridden from this module. Wheel events are routed in by one local event
//  monitor instead — see `TerminalScrollRouter`.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import AppKit
import SwiftTerm

final class AgentVMTerminalView: TerminalView {
    static let defaultFontSize: CGFloat = 12
    static let fontSizeRange: ClosedRange<CGFloat> = 9...28

    /// Asked to change the shared font size; the owner applies it to every view.
    var onFontSizeRequest: ((CGFloat) -> Void)?
    /// A three-finger horizontal swipe: -1 previous session, +1 next.
    var onSwipe: ((Int) -> Void)?

    private var pendingPoints: CGFloat = 0
    private var pendingMagnification: CGFloat = 0

    init(fontSize: CGFloat) {
        super.init(
            frame: CGRect(x: 0, y: 0, width: 640, height: 400),
            font: Self.font(ofSize: fontSize))
        menu = makeContextMenu()
        TerminalScrollRouter.install()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static func font(ofSize size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func applyFontSize(_ size: CGFloat) {
        guard abs(font.pointSize - size) > 0.01 else { return }
        font = Self.font(ofSize: size)
    }

    // MARK: - Scrolling

    /// The same arithmetic SwiftTerm uses for its rows.
    private var lineHeight: CGFloat {
        max(1, ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)))
    }

    /// Returns false to let the event through untouched.
    func handleScroll(_ event: NSEvent) -> Bool {
        // A mostly sideways gesture is not a vertical scroll, and it may
        // belong to a swipe the system is tracking.
        guard abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return true }

        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            pendingPoints = 0
        }

        let lines: Int
        if event.hasPreciseScrollingDeltas {
            pendingPoints += event.scrollingDeltaY
            let whole = (pendingPoints / lineHeight).rounded(.towardZero)
            pendingPoints -= whole * lineHeight
            lines = Int(whole)
        } else {
            // A mouse wheel: deltas are already in (accelerated) lines, and
            // a single slow notch must still move something.
            let delta = event.scrollingDeltaY
            lines = delta == 0 ? 0 : Int(delta.sign == .minus ? min(-1, delta.rounded()) : max(1, delta.rounded()))
        }
        guard lines != 0 else { return true }

        let terminal = getTerminal()
        if allowMouseReporting && terminal.mouseMode != .off {
            reportWheel(lines: lines, event: event)
        } else if terminal.isCurrentBufferAlternate {
            // Momentum makes a full-screen app overshoot badly; the fingers
            // are the only input here.
            guard event.momentumPhase.isEmpty else { return true }
            let up: [UInt8] = terminal.applicationCursor ? [0x1b, 0x4f, 0x41] : [0x1b, 0x5b, 0x41]
            let down: [UInt8] = terminal.applicationCursor ? [0x1b, 0x4f, 0x42] : [0x1b, 0x5b, 0x42]
            for _ in 0..<min(abs(lines), 12) { send(lines > 0 ? up : down) }
        } else if lines > 0 {
            scrollUp(lines: lines)
        } else {
            scrollDown(lines: -lines)
        }
        return true
    }

    private func reportWheel(lines: Int, event: NSEvent) {
        let terminal = getTerminal()
        let point = convert(event.locationInWindow, from: nil)
        let cellWidth = max(1, bounds.width / CGFloat(max(terminal.cols, 1)))
        let col = min(max(Int(point.x / cellWidth), 0), terminal.cols - 1)
        let row = min(max(Int((bounds.height - point.y) / lineHeight), 0), terminal.rows - 1)
        let flags = event.modifierFlags
        let button = terminal.encodeButton(
            button: lines > 0 ? 4 : 5, release: false,
            shift: flags.contains(.shift), meta: flags.contains(.option), control: flags.contains(.control))
        for _ in 0..<min(abs(lines), 12) {
            terminal.sendEvent(buttonFlags: button, x: col, y: row)
        }
    }

    // MARK: - Gestures

    override func magnify(with event: NSEvent) {
        if event.phase.contains(.began) { pendingMagnification = 0 }
        pendingMagnification += event.magnification
        // One point of font size per ~8% of pinch.
        let steps = (pendingMagnification / 0.08).rounded(.towardZero)
        guard steps != 0 else { return }
        pendingMagnification -= steps * 0.08
        requestFontSize(font.pointSize + steps)
    }

    override func smartMagnify(with event: NSEvent) {
        requestFontSize(font.pointSize == Self.defaultFontSize ? Self.defaultFontSize + 4 : Self.defaultFontSize)
    }

    override func swipe(with event: NSEvent) {
        // deltaX is +1 for a swipe to the right, i.e. "go back".
        if event.deltaX > 0 { onSwipe?(-1) } else if event.deltaX < 0 { onSwipe?(1) }
    }

    private func requestFontSize(_ size: CGFloat) {
        let clamped = min(max(size.rounded(), Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        if let onFontSizeRequest { onFontSizeRequest(clamped) } else { applyFontSize(clamped) }
    }

    // MARK: - Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            return item
        }
        menu.addItem(item("Copy", #selector(copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("Clear Scrollback", #selector(clearScrollbackAction(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bigger", #selector(biggerAction(_:)), "+"))
        menu.addItem(item("Smaller", #selector(smallerAction(_:)), "-"))
        menu.addItem(item("Actual Size", #selector(actualSizeAction(_:)), "0"))
        return menu
    }

    @objc private func clearScrollbackAction(_ sender: Any?) {
        // ED 3 drops the scrollback; the screen itself is left alone, so a
        // full-screen program doesn't lose its display.
        feed(text: "\u{1b}[3J")
    }

    @objc private func biggerAction(_ sender: Any?) { requestFontSize(font.pointSize + 1) }
    @objc private func smallerAction(_ sender: Any?) { requestFontSize(font.pointSize - 1) }
    @objc private func actualSizeAction(_ sender: Any?) { requestFontSize(Self.defaultFontSize) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(clearScrollbackAction(_:)), #selector(biggerAction(_:)),
            #selector(smallerAction(_:)), #selector(actualSizeAction(_:)):
            return true
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    // The native colors are resolved when they're set, so a switch between
    // light and dark has to set them again.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { configureNativeColors() }
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // A right click is a click: take focus so Paste lands here.
        window?.makeFirstResponder(self)
        return super.menu(for: event)
    }
}

/// Sends wheel events over a terminal to that terminal's handler before
/// SwiftTerm's own `scrollWheel` sees them.
@MainActor
enum TerminalScrollRouter {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let window = event.window, let content = window.contentView,
                let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
            else { return event }
            var view: NSView? = hit
            var terminal: AgentVMTerminalView?
            while let current = view, terminal == nil {
                terminal = (current as? AgentVMTerminalView) ?? (current as? TerminalContainerView)?.terminal
                view = current.superview
            }
            guard let terminal, !terminal.isHiddenOrHasHiddenAncestor else { return event }
            return terminal.handleScroll(event) ? nil : event
        }
    }
}
