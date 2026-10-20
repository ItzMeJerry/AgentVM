//
//  PaneLayout.swift
//  How one instance's shell sessions share the terminal area: a tree of splits
//  whose leaves are sessions, or empty zones a layout template left open.
//
//  Tabs stay the list of sessions; a layout decides which of them are on screen
//  and where. Every rule — snapping a session to an edge, templates, divider
//  snapping, what happens when a pane goes away — is a value operation here, with
//  no AppKit or SwiftUI, so all of it is under test.
//
//  Coordinates follow SwiftUI: y grows downward, so "top" is the smaller y.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//

import CoreGraphics
import Foundation

/// What one pane shows.
public enum PaneContent: Hashable, Sendable {
    /// A shell session, by its ID.
    case session(UUID)
    /// A zone a template created that no session fills yet.
    case empty(UUID)

    public var sessionID: UUID? {
        if case .session(let id) = self { id } else { nil }
    }

    public var isEmpty: Bool {
        if case .empty = self { true } else { false }
    }
}

/// The direction a split lays its children out in.
public enum SplitAxis: Hashable, Sendable {
    /// Side by side; the dividers are vertical lines.
    case horizontal
    /// Stacked; the dividers are horizontal lines.
    case vertical
}

public enum PaneNode: Hashable, Sendable {
    case leaf(PaneContent)
    /// Children in reading order, and the share of the split's length each one
    /// takes. The shares are positive and add up to 1.
    case split(SplitAxis, [PaneNode], [Double])
}

/// How a divider responds to a drag.
public enum ResizeMode: String, CaseIterable, Sendable {
    /// The default: dividers jump between halves, thirds, quarters and equal
    /// shares, so panes stay at tidy sizes.
    case snap
    /// Dividers follow the pointer, only kept clear of the minimum pane size.
    case free
}

/// Where, over a pane, a dragged session would land.
public enum DropZone: CaseIterable, Sendable {
    case left, right, top, bottom
    /// Into the pane itself: a swap, or a replacement.
    case center
}

public struct DropTarget: Hashable, Sendable {
    public let pane: PaneContent
    public let zone: DropZone

    public init(pane: PaneContent, zone: DropZone) {
        self.pane = pane
        self.zone = zone
    }
}

/// One divider, by the split it belongs to and its position among that split's
/// dividers. Stable while only fractions change, which is all a drag does.
public struct DividerID: Hashable, Sendable {
    /// Child indices from the root to the split.
    public let path: [Int]
    /// The divider between child `index` and child `index + 1`.
    public let index: Int

    public init(path: [Int], index: Int) {
        self.path = path
        self.index = index
    }
}

/// A divider as laid out in a rectangle.
public struct PaneDivider: Hashable, Sendable {
    public let id: DividerID
    /// The axis of the split it divides.
    public let axis: SplitAxis
    /// The gap between the two panes it separates (zero-thick without a gap).
    public let rect: CGRect
    /// Where it sits, as a share of the split's length.
    public let boundary: Double
    /// The split's length available to panes, in points — what a drag of one
    /// point moves `boundary` by the reciprocal of.
    public let length: Double
}

public struct PaneLayout: Hashable, Sendable {
    public private(set) var root: PaneNode
    /// The pane that takes the keyboard. Always one of `leaves`.
    public private(set) var focused: PaneContent

    /// One session filling the whole area.
    public init(session: UUID) {
        root = .leaf(.session(session))
        focused = .session(session)
    }

    init(root: PaneNode, focused: PaneContent) {
        self.root = Self.normalized(root)
        self.focused = focused
    }

    // MARK: - Reading

    /// Every pane, in reading order.
    public var leaves: [PaneContent] { Self.leaves(of: root) }

    /// The sessions on screen, in reading order.
    public var sessions: [UUID] { leaves.compactMap(\.sessionID) }

    public var isSplit: Bool {
        if case .split = root { true } else { false }
    }

    public var focusedSession: UUID? { focused.sessionID }

    public func contains(_ content: PaneContent) -> Bool { path(of: content) != nil }

    public func contains(session id: UUID) -> Bool { contains(.session(id)) }

    // MARK: - Focus and showing sessions

    @discardableResult
    public mutating func focus(_ content: PaneContent) -> Bool {
        guard contains(content) else { return false }
        focused = content
        return true
    }

    /// What clicking a session's tab does: focus its pane if it's on screen,
    /// otherwise show it in the focused pane, which then stops showing whatever
    /// it had (that session stays a tab).
    public mutating func reveal(session id: UUID) {
        let incoming = PaneContent.session(id)
        if !contains(incoming) {
            replaceContent(focused, with: incoming)
        }
        focused = incoming
    }

    /// Puts a session into a particular pane: an empty zone, or one showing
    /// another session. If the session is already on screen elsewhere, the two
    /// trade places.
    @discardableResult
    public mutating func show(session id: UUID, in pane: PaneContent) -> Bool {
        let incoming = PaneContent.session(id)
        guard pane != incoming, contains(pane) else { return false }
        if contains(incoming) {
            swapContents(incoming, pane)
        } else {
            replaceContent(pane, with: incoming)
        }
        focused = incoming
        return true
    }

    /// A session replaced by a fresh one in the same pane, as Reopen does.
    @discardableResult
    public mutating func replace(session old: UUID, with new: UUID) -> Bool {
        let incoming = PaneContent.session(new)
        guard contains(.session(old)), !contains(incoming) else { return false }
        replaceContent(.session(old), with: incoming)
        if focused == .session(old) { focused = incoming }
        return true
    }

    // MARK: - Snapping and unsnapping

    /// Drops a session onto a pane. An edge splits that pane and gives the
    /// session the half on that side; the center puts it into the pane itself.
    /// A session already on screen moves: it leaves its own pane first.
    @discardableResult
    public mutating func snap(session id: UUID, to target: DropTarget) -> Bool {
        let incoming = PaneContent.session(id)
        guard target.pane != incoming, contains(target.pane) else { return false }
        if target.zone == .center {
            return show(session: id, in: target.pane)
        }
        if contains(incoming) {
            // The target is another pane, so there are at least two: removable.
            guard removeLeaf(incoming) else { return false }
        }
        insert(incoming, beside: target.pane, zone: target.zone)
        focused = incoming
        return true
    }

    /// Takes a pane out — a session's, which stays a tab, or an empty zone.
    /// The panes around it grow into its space, in proportion. The last pane
    /// can't be removed.
    @discardableResult
    public mutating func remove(pane: PaneContent) -> Bool { removeLeaf(pane) }

    /// Drops the panes of sessions that no longer exist. Empty zones stay.
    /// Returns false when nothing could remain — the caller starts over with a
    /// session it still has.
    @discardableResult
    public mutating func retain(sessions alive: Set<UUID>) -> Bool {
        for content in leaves {
            guard let id = content.sessionID, !alive.contains(id) else { continue }
            if !removeLeaf(content) { return false }
        }
        return true
    }

    // MARK: - Dividers

    /// Moves a divider toward `requested`, a share of its split's length.
    ///
    /// In `.snap` mode it lands on the nearest of halves, thirds, quarters or
    /// equal shares that leaves room on both sides; in `.free` mode it goes
    /// where asked, kept clear of the same limits. Room means every pane on
    /// either side keeps `minimumSize` — including panes nested in a split next
    /// to the divider, not just its direct neighbours. Returns whether anything
    /// moved.
    @discardableResult
    public mutating func moveDivider(
        _ id: DividerID, to requested: Double, mode: ResizeMode, length: Double, minimumSize: CGSize,
        gap: Double = 0
    ) -> Bool {
        moveDivider(id, to: requested, mode: mode, length: length) { axis, before, after in
            (
                Self.minimumLength(of: before, along: axis, minimumSize: minimumSize, gap: gap),
                Self.minimumLength(of: after, along: axis, minimumSize: minimumSize, gap: gap)
            )
        }
    }

    /// The same, with one minimum length in points for both neighbours.
    @discardableResult
    public mutating func moveDivider(
        _ id: DividerID, to requested: Double, mode: ResizeMode, length: Double, minimumLength: Double
    ) -> Bool {
        moveDivider(id, to: requested, mode: mode, length: length) { _, _, _ in (minimumLength, minimumLength) }
    }

    mutating func moveDivider(
        _ id: DividerID, to requested: Double, mode: ResizeMode, length: Double,
        minimumBefore: Double, minimumAfter: Double
    ) -> Bool {
        moveDivider(id, to: requested, mode: mode, length: length) { _, _, _ in (minimumBefore, minimumAfter) }
    }

    /// The one move all of them make, given the minimum lengths in points of
    /// the two panes either side of the divider.
    private mutating func moveDivider(
        _ id: DividerID, to requested: Double, mode: ResizeMode, length: Double,
        minimums: (SplitAxis, PaneNode, PaneNode) -> (before: Double, after: Double)
    ) -> Bool {
        guard case .split(let axis, let children, var fractions)? = Self.node(at: id.path[...], in: root),
            id.index >= 0, id.index < children.count - 1
        else { return false }
        let (minimumBefore, minimumAfter) = minimums(axis, children[id.index], children[id.index + 1])
        let before = fractions[..<id.index].reduce(0, +)
        let current = before + fractions[id.index]
        let after = current + fractions[id.index + 1]
        // Each side keeps its minimum; when the pair can't give both theirs,
        // they share what there is in proportion — and never get nothing.
        let pair = after - before
        var lowShare = length > 0 ? minimumBefore / length : 0
        var highShare = length > 0 ? minimumAfter / length : 0
        if lowShare + highShare > pair {
            let scale = pair / (lowShare + highShare)
            lowShare *= scale
            highShare *= scale
        }
        let low = before + max(Self.smallestShare, lowShare)
        let high = after - max(Self.smallestShare, highShare)
        guard low <= high else { return false }

        let target: Double
        switch mode {
        case .free:
            target = min(max(requested, low), high)
        case .snap:
            let candidates = Self.snapPoints(splitting: children.count)
                .filter { $0 >= low - Self.epsilon && $0 <= high + Self.epsilon }
            guard let nearest = candidates.min(by: { abs($0 - requested) < abs($1 - requested) }) else {
                return false
            }
            target = nearest
        }
        guard abs(target - current) > Self.epsilon else { return false }
        fractions[id.index] = target - before
        fractions[id.index + 1] = after - target
        set(at: id.path, .split(axis, children, fractions))
        return true
    }

    /// The least length `node` needs along `axis` for each of its panes to keep
    /// `minimumSize`: panes laid out along the axis add up, with their gaps;
    /// panes stacked across it need only as much as the largest of them.
    public static func minimumLength(
        of node: PaneNode, along axis: SplitAxis, minimumSize: CGSize, gap: Double = 0
    ) -> Double {
        switch node {
        case .leaf:
            return axis == .horizontal ? minimumSize.width : minimumSize.height
        case .split(let splitAxis, let children, _):
            let minimums = children.map { minimumLength(of: $0, along: axis, minimumSize: minimumSize, gap: gap) }
            return splitAxis == axis
                ? minimums.reduce(0, +) + gap * Double(children.count - 1)
                : minimums.max() ?? 0
        }
    }

    /// Gives every child of the split at `path` an equal share.
    @discardableResult
    public mutating func equalize(splitAt path: [Int]) -> Bool {
        guard case .split(let axis, let children, let fractions)? = Self.node(at: path[...], in: root) else {
            return false
        }
        let equal = Array(repeating: 1 / Double(children.count), count: children.count)
        guard zip(fractions, equal).contains(where: { abs($0 - $1) > Self.epsilon }) else { return false }
        set(at: path, .split(axis, children, equal))
        return true
    }

    /// Where a snapping divider may sit, as shares of its split: the familiar
    /// fractions, plus equal shares for however many panes the split has.
    public static func snapPoints(splitting count: Int) -> [Double] {
        let familiar: [Double] = [1.0 / 4, 1.0 / 3, 1.0 / 2, 2.0 / 3, 3.0 / 4]
        let equal = count > 1 ? (1..<count).map { Double($0) / Double(count) } : []
        var points: [Double] = []
        for point in (familiar + equal).sorted() where !points.contains(where: { abs($0 - point) < epsilon }) {
            points.append(point)
        }
        return points
    }

    // MARK: - Geometry

    /// Every pane's frame, the panes separated by `gap` points. Boundaries are
    /// rounded to whole points so terminals never sit on half a pixel.
    public func frames(in rect: CGRect, gap: Double = 0) -> [PaneContent: CGRect] {
        var frames: [PaneContent: CGRect] = [:]
        Self.walk(root, in: rect, gap: gap, path: []) { frames[$0] = $1 } divider: { _ in }
        return frames
    }

    /// Every divider, in the same layout `frames(in:gap:)` produces.
    public func dividers(in rect: CGRect, gap: Double = 0) -> [PaneDivider] {
        var dividers: [PaneDivider] = []
        Self.walk(root, in: rect, gap: gap, path: []) { _, _ in } divider: { dividers.append($0) }
        return dividers
    }

    /// The pane under `point` and the zone of it the point is in, for a
    /// session being dragged. Edges of a pane too small to split in two, with
    /// both halves at least `minimumSize`, count as its center.
    public func dropTarget(
        at point: CGPoint, in rect: CGRect, gap: Double = 0, minimumSize: CGSize = .zero
    ) -> DropTarget? {
        guard let (pane, frame) = frames(in: rect, gap: gap).first(where: { $0.value.contains(point) }) else {
            return nil
        }
        var zone = Self.zone(at: point, in: frame)
        // Not `case .left, .right where …`: a `where` there binds to the last
        // pattern only.
        switch zone {
        case .left, .right:
            if frame.width < 2 * minimumSize.width + gap { zone = .center }
        case .top, .bottom:
            if frame.height < 2 * minimumSize.height + gap { zone = .center }
        case .center:
            break
        }
        return DropTarget(pane: pane, zone: zone)
    }

    /// How far from a pane's middle, as a share of its size, still counts as its
    /// center: a fifth each way, as editors' drop zones do.
    public static let centerReach = 0.2

    /// The zone of `rect` that `point` falls in: its center, or else the edge
    /// it's nearest to, measured relative to the pane's size.
    public static func zone(at point: CGPoint, in rect: CGRect) -> DropZone {
        guard rect.width > 0, rect.height > 0 else { return .center }
        let u = (point.x - rect.minX) / rect.width
        let v = (point.y - rect.minY) / rect.height
        if abs(u - 0.5) <= centerReach && abs(v - 0.5) <= centerReach { return .center }
        let distances: [(DropZone, Double)] = [(.left, u), (.right, 1 - u), (.top, v), (.bottom, 1 - v)]
        return distances.min { $0.1 < $1.1 }!.0
    }

    /// The part of a pane a drop into `zone` would take: the half on that side,
    /// or all of it for the center.
    public static func previewRect(for zone: DropZone, in rect: CGRect) -> CGRect {
        switch zone {
        case .left: CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right: CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .top: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .bottom: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        case .center: rect
        }
    }

    // MARK: - Internals

    static let epsilon = 1e-9

    /// The least share a divider can leave a pane with, whatever minimum the
    /// caller asks for: a pane always keeps a sliver of its split.
    static let smallestShare = 1e-3

    static func leaves(of node: PaneNode) -> [PaneContent] {
        switch node {
        case .leaf(let content): [content]
        case .split(_, let children, _): children.flatMap(leaves(of:))
        }
    }

    func path(of content: PaneContent) -> [Int]? { Self.path(of: content, in: root) }

    static func path(of content: PaneContent, in node: PaneNode) -> [Int]? {
        switch node {
        case .leaf(let leaf):
            return leaf == content ? [] : nil
        case .split(_, let children, _):
            for (index, child) in children.enumerated() {
                if let rest = path(of: content, in: child) { return [index] + rest }
            }
            return nil
        }
    }

    static func node(at path: ArraySlice<Int>, in node: PaneNode) -> PaneNode? {
        guard let first = path.first else { return node }
        guard case .split(_, let children, _) = node, children.indices.contains(first) else { return nil }
        return self.node(at: path.dropFirst(), in: children[first])
    }

    mutating func set(at path: [Int], _ replacement: PaneNode) {
        root = Self.setting(path[...], in: root, to: replacement)
    }

    static func setting(_ path: ArraySlice<Int>, in node: PaneNode, to replacement: PaneNode) -> PaneNode {
        guard let first = path.first else { return replacement }
        guard case .split(let axis, var children, let fractions) = node, children.indices.contains(first) else {
            return node
        }
        children[first] = setting(path.dropFirst(), in: children[first], to: replacement)
        return .split(axis, children, fractions)
    }

    mutating func replaceContent(_ old: PaneContent, with new: PaneContent) {
        guard let path = path(of: old) else { return }
        set(at: path, .leaf(new))
    }

    mutating func swapContents(_ a: PaneContent, _ b: PaneContent) {
        guard let pathA = path(of: a), let pathB = path(of: b) else { return }
        set(at: pathA, .leaf(b))
        set(at: pathB, .leaf(a))
    }

    /// Splits `target`, or — when its parent already runs along the same axis —
    /// adds a sibling beside it, so three side-by-side panes are one split of
    /// three rather than splits nested inside splits.
    mutating func insert(_ incoming: PaneContent, beside target: PaneContent, zone: DropZone) {
        guard zone != .center, let path = path(of: target) else { return }
        let axis: SplitAxis = zone == .left || zone == .right ? .horizontal : .vertical
        let before = zone == .left || zone == .top
        if let index = path.last,
            case .split(let parentAxis, var children, var fractions)? = Self.node(at: path.dropLast(), in: root),
            parentAxis == axis
        {
            let half = fractions[index] / 2
            fractions[index] = half
            let position = before ? index : index + 1
            children.insert(.leaf(incoming), at: position)
            fractions.insert(half, at: position)
            set(at: Array(path.dropLast()), .split(axis, children, fractions))
        } else {
            let pair: [PaneNode] = before ? [.leaf(incoming), .leaf(target)] : [.leaf(target), .leaf(incoming)]
            set(at: path, .split(axis, pair, [0.5, 0.5]))
        }
        root = Self.normalized(root)
    }

    /// Removes a pane; its space goes to its siblings in proportion to their
    /// size. If it was focused, the neighbour that took its place is.
    mutating func removeLeaf(_ content: PaneContent) -> Bool {
        guard let path = path(of: content), let index = path.last else { return false }
        let parentPath = Array(path.dropLast())
        guard case .split(let axis, var children, var fractions)? = Self.node(at: parentPath[...], in: root) else {
            return false
        }
        let removed = fractions.remove(at: index)
        children.remove(at: index)
        let remaining = 1 - removed
        let count = Double(fractions.count)
        fractions = fractions.map { remaining > Self.epsilon ? $0 / remaining : 1 / count }
        let heir: PaneContent? =
            focused == content
            ? (index > 0 ? Self.leaves(of: children[index - 1]).last : Self.leaves(of: children[index]).first)
            : nil
        set(at: parentPath, .split(axis, children, fractions))
        root = Self.normalized(root)
        if let heir { focused = heir }
        return true
    }

    /// The canonical form every operation leaves behind: no split with a single
    /// child, no split directly inside one along the same axis, and shares that
    /// add up to exactly 1.
    static func normalized(_ node: PaneNode) -> PaneNode {
        guard case .split(let axis, let children, let fractions) = node else { return node }
        var flatChildren: [PaneNode] = []
        var flatFractions: [Double] = []
        for (child, share) in zip(children.map(normalized), fractions) {
            if case .split(let childAxis, let grandchildren, let shares) = child, childAxis == axis {
                flatChildren += grandchildren
                flatFractions += shares.map { $0 * share }
            } else {
                flatChildren.append(child)
                flatFractions.append(share)
            }
        }
        if flatChildren.count == 1 { return flatChildren[0] }
        let total = flatFractions.reduce(0, +)
        return .split(axis, flatChildren, flatFractions.map { $0 / total })
    }

    static func walk(
        _ node: PaneNode, in rect: CGRect, gap: Double, path: [Int],
        leaf: (PaneContent, CGRect) -> Void, divider: (PaneDivider) -> Void
    ) {
        switch node {
        case .leaf(let content):
            leaf(content, rect)
        case .split(let axis, let children, let fractions):
            let horizontal = axis == .horizontal
            let origin = horizontal ? rect.minX : rect.minY
            let total = horizontal ? rect.width : rect.height
            let count = children.count
            // Every edge is clamped to the end of the split, so in a space too
            // small for its gaps the last panes and gaps shrink to nothing
            // rather than spilling out: panes and gaps always tile it exactly.
            let limit = origin + total
            let available = max(0, total - gap * Double(count - 1))
            var share = 0.0
            var start = origin
            for index in 0..<count {
                share += fractions[index]
                let end =
                    index == count - 1
                    ? limit
                    : min(limit, max(start, (origin + available * share + gap * Double(index)).rounded()))
                let child =
                    horizontal
                    ? CGRect(x: start, y: rect.minY, width: end - start, height: rect.height)
                    : CGRect(x: rect.minX, y: start, width: rect.width, height: end - start)
                walk(children[index], in: child, gap: gap, path: path + [index], leaf: leaf, divider: divider)
                if index < count - 1 {
                    let next = min(end + gap, limit)
                    let gapRect =
                        horizontal
                        ? CGRect(x: end, y: rect.minY, width: next - end, height: rect.height)
                        : CGRect(x: rect.minX, y: end, width: rect.width, height: next - end)
                    divider(
                        PaneDivider(
                            id: DividerID(path: path, index: index), axis: axis, rect: gapRect,
                            boundary: share, length: available))
                    start = next
                }
            }
        }
    }
}

extension PaneLayout {
    /// What the layout becomes when a session's tab is closed, and which session
    /// counts as selected afterwards. `remaining` is the tab order without the
    /// closed session; `index` is where it was in the tabs. Nil when no tabs
    /// remain.
    ///
    /// The other panes keep their places. When the closed session's pane was
    /// the only one, the neighbouring tab takes over the area — as closing a
    /// browser tab shows the next — and when only empty zones would be left,
    /// that neighbour fills the focused one.
    public static func closing(
        _ closed: UUID, from layout: PaneLayout?, remaining: [UUID], at index: Int?
    ) -> (layout: PaneLayout, selected: UUID)? {
        guard !remaining.isEmpty else { return nil }
        let neighbour = remaining[min(max(index ?? 0, 0), remaining.count - 1)]
        guard var layout, layout.retain(sessions: Set(remaining)) else {
            return (PaneLayout(session: neighbour), neighbour)
        }
        if layout.sessions.isEmpty { layout.reveal(session: neighbour) }
        return (layout, layout.focusedSession ?? neighbour)
    }
}
