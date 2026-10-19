//
//  AgentVMTerminalView.swift
//  SwiftTerm's view, plus the gestures and menu the app adds on top of it.
//
//  Scrolling is SwiftTerm's own: line-accurate trackpad deltas, wheel reports to
//  programs that track the mouse, and Alternate Scroll Mode (the wheel as arrow
//  keys in less, man or git log). This file only adds what SwiftTerm leaves to
//  the host app:
//
//  - pinch zooms the font, a two-finger double tap resets it;
//  - a three-finger swipe moves between sessions;
//  - a right click (or two-finger click) opens a context menu.
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
    /// A click landed in this terminal, so its pane should have the focus.
    var onActivate: (() -> Void)?

    private var pendingMagnification: CGFloat = 0

    init(fontSize: CGFloat) {
        super.init(
            frame: CGRect(x: 0, y: 0, width: 640, height: 400),
            font: Self.font(ofSize: fontSize))
        menu = makeContextMenu()
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

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // A right click is a click: take focus so Paste lands here.
        onActivate?()
        window?.makeFirstResponder(self)
        return super.menu(for: event)
    }
}
