#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Identifies a pane (a leaf) inside a ``SplitTree``.
public typealias PaneID = UUID

/// The axis along which a split lays out its two children.
public enum SplitAxis: String, Codable, Sendable {
    /// Children sit side by side (left | right).
    case horizontal
    /// Children are stacked (top / bottom).
    case vertical
}

/// A direction relative to a pane, used for splitting, focus movement and resizing.
public enum SplitDirection: String, CaseIterable, Codable, Sendable {
    case left, right, up, down

    public var axis: SplitAxis {
        switch self {
        case .left, .right: .horizontal
        case .up, .down: .vertical
        }
    }

    /// Whether a pane created in this direction goes after the existing one.
    var insertsAfter: Bool { self == .right || self == .down }
}

/// A node of the split tree: either a single pane or a split of two subtrees.
public indirect enum SplitNode: Equatable, Codable, Sendable {
    case leaf(PaneID)
    case split(Split)

    /// Panes in reading order (left-to-right, top-to-bottom).
    public var leaves: [PaneID] {
        switch self {
        case .leaf(let id): [id]
        case .split(let split): split.first.leaves + split.second.leaves
        }
    }

    var firstLeaf: PaneID {
        switch self {
        case .leaf(let id): id
        case .split(let split): split.first.firstLeaf
        }
    }

    var lastLeaf: PaneID {
        switch self {
        case .leaf(let id): id
        case .split(let split): split.second.lastLeaf
        }
    }

    func contains(_ pane: PaneID) -> Bool {
        switch self {
        case .leaf(let id): id == pane
        case .split(let split): split.first.contains(pane) || split.second.contains(pane)
        }
    }
}

/// Two subtrees laid out along an axis. `ratio` is the fraction given to `first`.
public struct Split: Equatable, Codable, Sendable, Identifiable {
    public let id: UUID
    public var axis: SplitAxis
    public var ratio: Double
    public var first: SplitNode
    public var second: SplitNode

    public init(id: UUID = UUID(), axis: SplitAxis, ratio: Double = 0.5, first: SplitNode, second: SplitNode) {
        self.id = id
        self.axis = axis
        self.ratio = ratio
        self.first = first
        self.second = second
    }
}

/// A binary tree of panes, in the spirit of terminal splits (Ghostty, tmux).
///
/// The tree is a pure value type: it knows nothing about web views, so all of
/// the layout and navigation logic can be unit tested in isolation.
public struct SplitTree: Equatable, Codable, Sendable {
    public static let minimumRatio = 0.1
    public static let maximumRatio = 0.9

    public private(set) var root: SplitNode

    public init(root: SplitNode) {
        self.root = root
    }

    public init(pane: PaneID) {
        self.root = .leaf(pane)
    }

    public var leaves: [PaneID] { root.leaves }
    public var count: Int { leaves.count }
    public func contains(_ pane: PaneID) -> Bool { root.contains(pane) }

    // MARK: - Structure

    /// Splits `target`, placing `newPane` on the given side. Returns `false` if `target` is not in the tree.
    @discardableResult
    public mutating func split(_ target: PaneID, direction: SplitDirection, newPane: PaneID, ratio: Double = 0.5) -> Bool {
        guard contains(target), !contains(newPane) else { return false }
        root = Self.splitting(root, target: target, direction: direction, newPane: newPane, ratio: ratio)
        return true
    }

    private static func splitting(_ node: SplitNode, target: PaneID, direction: SplitDirection, newPane: PaneID, ratio: Double) -> SplitNode {
        switch node {
        case .leaf(let id) where id == target:
            let fresh = SplitNode.leaf(newPane)
            let (first, second) = direction.insertsAfter ? (node, fresh) : (fresh, node)
            // `ratio` always describes the share kept by the existing pane.
            let firstRatio = direction.insertsAfter ? ratio : 1 - ratio
            return .split(Split(axis: direction.axis, ratio: clamp(firstRatio), first: first, second: second))
        case .leaf:
            return node
        case .split(var split):
            split.first = splitting(split.first, target: target, direction: direction, newPane: newPane, ratio: ratio)
            split.second = splitting(split.second, target: target, direction: direction, newPane: newPane, ratio: ratio)
            return .split(split)
        }
    }

    /// Removes `target` from the tree; its sibling takes over the freed space.
    ///
    /// - Returns: The pane that should receive focus next, or `nil` if `target`
    ///   is not in the tree or is the only pane (the last pane cannot be removed).
    @discardableResult
    public mutating func remove(_ target: PaneID) -> PaneID? {
        guard count > 1 else { return nil }
        let result = Self.removing(target, from: root)
        guard result.found, let node = result.node else { return nil }
        root = node
        return result.focus
    }

    private static func removing(_ target: PaneID, from node: SplitNode) -> (node: SplitNode?, focus: PaneID?, found: Bool) {
        switch node {
        case .leaf(let id):
            return id == target ? (nil, nil, true) : (node, nil, false)
        case .split(var split):
            let first = removing(target, from: split.first)
            if first.found {
                guard let remaining = first.node else {
                    // The removed pane was the whole first half: focus the nearest pane after it.
                    return (split.second, split.second.firstLeaf, true)
                }
                split.first = remaining
                return (.split(split), first.focus, true)
            }
            let second = removing(target, from: split.second)
            if second.found {
                guard let remaining = second.node else {
                    return (split.first, split.first.lastLeaf, true)
                }
                split.second = remaining
                return (.split(split), second.focus, true)
            }
            return (node, nil, false)
        }
    }

    /// Replaces the pane `old` with `new`, keeping the layout intact.
    public mutating func replace(_ old: PaneID, with new: PaneID) {
        root = Self.replacing(old, with: new, in: root)
    }

    private static func replacing(_ old: PaneID, with new: PaneID, in node: SplitNode) -> SplitNode {
        switch node {
        case .leaf(let id):
            return id == old ? .leaf(new) : node
        case .split(var split):
            split.first = replacing(old, with: new, in: split.first)
            split.second = replacing(old, with: new, in: split.second)
            return .split(split)
        }
    }

    /// Exchanges the positions of two panes.
    @discardableResult
    public mutating func swap(_ a: PaneID, _ b: PaneID) -> Bool {
        guard a != b, contains(a), contains(b) else { return false }
        let placeholder = UUID()
        replace(a, with: placeholder)
        replace(b, with: a)
        replace(placeholder, with: b)
        return true
    }

    /// Moves `pane` out of its slot and docks it on the given side of `target`.
    @discardableResult
    public mutating func move(_ pane: PaneID, to target: PaneID, direction: SplitDirection) -> Bool {
        guard pane != target, contains(pane), contains(target) else { return false }
        var copy = self
        guard copy.remove(pane) != nil, copy.split(target, direction: direction, newPane: pane) else { return false }
        self = copy
        return true
    }

    // MARK: - Sizing

    /// Sets the ratio of the split with the given identifier.
    public mutating func setRatio(_ ratio: Double, forSplit splitID: UUID) {
        root = Self.mapSplits(root) { split in
            if split.id == splitID { split.ratio = Self.clamp(ratio) }
        }
    }

    /// Distributes space evenly: every pane along a run of same-axis splits gets an equal share.
    public mutating func equalize() {
        root = Self.equalized(root)
    }

    private static func equalized(_ node: SplitNode) -> SplitNode {
        guard case .split(var split) = node else { return node }
        split.first = equalized(split.first)
        split.second = equalized(split.second)
        let a = Double(slots(split.first, along: split.axis))
        let b = Double(slots(split.second, along: split.axis))
        split.ratio = a / (a + b)
        return .split(split)
    }

    /// The number of panes a subtree contributes along an axis.
    private static func slots(_ node: SplitNode, along axis: SplitAxis) -> Int {
        guard case .split(let split) = node, split.axis == axis else { return 1 }
        return slots(split.first, along: axis) + slots(split.second, along: axis)
    }

    /// Moves the divider nearest to `pane` in `direction` by `amount` (a fraction of that split's size).
    ///
    /// Mirrors Ghostty's `resize_split`: resizing `.right` moves the divider to the right.
    @discardableResult
    public mutating func resize(_ pane: PaneID, direction: SplitDirection, by amount: Double) -> Bool {
        guard let splitID = Self.nearestAncestor(of: pane, axis: direction.axis, in: root) else { return false }
        let delta = direction.insertsAfter ? amount : -amount
        root = Self.mapSplits(root) { split in
            if split.id == splitID { split.ratio = Self.clamp(split.ratio + delta) }
        }
        return true
    }

    private static func nearestAncestor(of pane: PaneID, axis: SplitAxis, in node: SplitNode) -> UUID? {
        guard case .split(let split) = node else { return nil }
        let child = split.first.contains(pane) ? split.first : split.second
        guard child.contains(pane) else { return nil }
        if let deeper = nearestAncestor(of: pane, axis: axis, in: child) { return deeper }
        return split.axis == axis ? split.id : nil
    }

    private static func mapSplits(_ node: SplitNode, _ transform: (inout Split) -> Void) -> SplitNode {
        guard case .split(var split) = node else { return node }
        transform(&split)
        split.first = mapSplits(split.first, transform)
        split.second = mapSplits(split.second, transform)
        return .split(split)
    }

    static func clamp(_ ratio: Double) -> Double {
        min(max(ratio, minimumRatio), maximumRatio)
    }

    // MARK: - Geometry & navigation

    /// Frames of every pane inside `rect` (top-left origin, y grows downward).
    public func layout(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [PaneID: CGRect] {
        var frames: [PaneID: CGRect] = [:]
        Self.layout(root, in: rect, into: &frames)
        return frames
    }

    private static func layout(_ node: SplitNode, in rect: CGRect, into frames: inout [PaneID: CGRect]) {
        switch node {
        case .leaf(let id):
            frames[id] = rect
        case .split(let split):
            let ratio = CGFloat(split.ratio)
            switch split.axis {
            case .horizontal:
                let w = rect.width * ratio
                layout(split.first, in: CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height), into: &frames)
                layout(split.second, in: CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height), into: &frames)
            case .vertical:
                let h = rect.height * ratio
                layout(split.first, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h), into: &frames)
                layout(split.second, in: CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h), into: &frames)
            }
        }
    }

    /// The pane adjacent to `pane` in `direction`, chosen spatially like Ghostty's `goto_split`.
    public func neighbor(of pane: PaneID, direction: SplitDirection) -> PaneID? {
        let frames = layout()
        guard let origin = frames[pane] else { return nil }
        let epsilon = 1e-6

        func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
            min(a1, b1) - max(a0, b0)
        }

        var best: (id: PaneID, distance: CGFloat, offset: CGFloat)?
        for (id, frame) in frames where id != pane {
            let distance: CGFloat
            let sharesEdge: Bool
            let offset: CGFloat
            switch direction {
            case .right:
                distance = frame.minX - origin.maxX
                sharesEdge = overlap(origin.minY, origin.maxY, frame.minY, frame.maxY) > epsilon
                offset = abs(frame.midY - origin.midY)
            case .left:
                distance = origin.minX - frame.maxX
                sharesEdge = overlap(origin.minY, origin.maxY, frame.minY, frame.maxY) > epsilon
                offset = abs(frame.midY - origin.midY)
            case .down:
                distance = frame.minY - origin.maxY
                sharesEdge = overlap(origin.minX, origin.maxX, frame.minX, frame.maxX) > epsilon
                offset = abs(frame.midX - origin.midX)
            case .up:
                distance = origin.minY - frame.maxY
                sharesEdge = overlap(origin.minX, origin.maxX, frame.minX, frame.maxX) > epsilon
                offset = abs(frame.midX - origin.midX)
            }
            guard distance > -epsilon, sharesEdge else { continue }
            if let current = best {
                if distance < current.distance - epsilon
                    || (abs(distance - current.distance) <= epsilon && offset < current.offset) {
                    best = (id, distance, offset)
                }
            } else {
                best = (id, distance, offset)
            }
        }
        return best?.id
    }

    /// The pane after `pane` in reading order, wrapping around.
    public func next(after pane: PaneID) -> PaneID? {
        let all = leaves
        guard let index = all.firstIndex(of: pane) else { return nil }
        return all[(index + 1) % all.count]
    }

    /// The pane before `pane` in reading order, wrapping around.
    public func previous(before pane: PaneID) -> PaneID? {
        let all = leaves
        guard let index = all.firstIndex(of: pane) else { return nil }
        return all[(index - 1 + all.count) % all.count]
    }
}
