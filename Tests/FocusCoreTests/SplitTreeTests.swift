#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
@testable import FocusCore

@Suite struct SplitTreeTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test func splittingRightPlacesNewPaneAfter() {
        var tree = SplitTree(pane: a)
        #expect(tree.split(a, direction: .right, newPane: b))
        #expect(tree.leaves == [a, b])
        guard case .split(let split) = tree.root else { Issue.record("expected split"); return }
        #expect(split.axis == .horizontal)
        #expect(split.ratio == 0.5)
    }

    @Test func splittingLeftAndUpPlacesNewPaneBefore() {
        var tree = SplitTree(pane: a)
        tree.split(a, direction: .left, newPane: b)
        tree.split(a, direction: .up, newPane: c)
        #expect(tree.leaves == [b, c, a])
    }

    @Test func splittingUnknownPaneFails() {
        var tree = SplitTree(pane: a)
        #expect(!tree.split(b, direction: .right, newPane: c))
        #expect(!tree.split(a, direction: .right, newPane: a))
        #expect(tree.leaves == [a])
    }

    @Test func removingCollapsesSplitAndPicksNeighbor() {
        var tree = SplitTree(pane: a)
        tree.split(a, direction: .right, newPane: b)
        tree.split(b, direction: .down, newPane: c)
        // a | (b / c)
        #expect(tree.remove(b) == c)
        #expect(tree.leaves == [a, c])
        #expect(tree.remove(c) == a)
        #expect(tree.root == .leaf(a))
    }

    @Test func lastPaneCannotBeRemoved() {
        var tree = SplitTree(pane: a)
        #expect(tree.remove(a) == nil)
        #expect(tree.leaves == [a])
    }

    @Test func removingSecondFocusesLastLeafOfFirst() {
        var tree = SplitTree(pane: a)
        tree.split(a, direction: .down, newPane: b)
        tree.split(a, direction: .right, newPane: c)
        // (a | c) / b
        #expect(tree.remove(b) == c)
    }

    @Test func layoutDividesSpace() {
        var tree = SplitTree(pane: a)
        tree.split(a, direction: .right, newPane: b)
        tree.split(b, direction: .down, newPane: c)
        let frames = tree.layout(in: CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(frames[a] == CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(frames[b] == CGRect(x: 100, y: 0, width: 100, height: 50))
        #expect(frames[c] == CGRect(x: 100, y: 50, width: 100, height: 50))
    }

    @Test func directionalNavigation() {
        var tree = SplitTree(pane: a)
        tree.split(a, direction: .right, newPane: b)
        tree.split(b, direction: .down, newPane: c)
        tree.split(a, direction: .down, newPane: d)
        // (a / d) | (b / c)
        #expect(tree.neighbor(of: a, direction: .right) == b)
        #expect(tree.neighbor(of: d, direction: .right) == c)
        #expect(tree.neighbor(of: c, direction: .left) == d)
        #expect(tree.neighbor(of: b, direction: .down) == c)
        #expect(tree.neighbor(of: c, direction: .up) == b)
        #expect(tree.neighbor(of: a, direction: .left) == nil)
        #expect(tree.neighbor(of: a, direction: .up) == nil)
    }

    @Test func navigationPrefersAlignedNeighbor() {
        var tree = SplitTree(pane: a)
        tree.split(a, direction: .right, newPane: b)
        tree.split(b, direction: .down, newPane: c)
        tree.split(c, direction: .down, newPane: d)
        // a | (b / (c / d)); from a, the closest-centered pane on the right is c.
        #expect(tree.neighbor(of: a, direction: .right) == c)
    }

    @Test func cyclingWraps() {
        var tree = SplitTree(pane: a)
        tree.split(a, direction: .right, newPane: b)
        tree.split(b, direction: .right, newPane: c)
        #expect(tree.next(after: c) == a)
        #expect(tree.previous(before: a) == c)
        #expect(tree.next(after: a) == b)
    }

    @Test func equalizeWeighsByPaneCount() {
        var tree = SplitTree(pane: a)
        tree.split(a, direction: .right, newPane: b)
        tree.split(b, direction: .right, newPane: c)
        // a | (b | c): the outer split should give a one third.
        tree.equalize()
        let frames = tree.layout(in: CGRect(x: 0, y: 0, width: 300, height: 100))
        #expect(abs(frames[a]!.width - 100) < 0.001)
        #expect(abs(frames[b]!.width - 100) < 0.001)
        #expect(abs(frames[c]!.width - 100) < 0.001)
    }

    @Test func resizeMovesNearestMatchingDivider() {
        var tree = SplitTree(pane: a)
        tree.split(a, direction: .right, newPane: b)
        tree.split(b, direction: .down, newPane: c)
        #expect(tree.resize(c, direction: .right, by: 0.1))
        #expect(abs(tree.layout()[a]!.width - 0.6) < 0.001)
        #expect(tree.resize(c, direction: .up, by: 0.1))
        #expect(abs(tree.layout()[b]!.height - 0.4) < 0.001)
        // No vertical split above `a`.
        #expect(!tree.resize(a, direction: .down, by: 0.1))
    }

    @Test func ratiosAreClamped() {
        var tree = SplitTree(pane: a)
        tree.split(a, direction: .right, newPane: b)
        guard case .split(let split) = tree.root else { Issue.record("expected split"); return }
        tree.setRatio(5, forSplit: split.id)
        #expect(abs(tree.layout()[a]!.width - SplitTree.maximumRatio) < 0.001)
    }

    @Test func replaceKeepsLayout() {
        var tree = SplitTree(pane: a)
        tree.split(a, direction: .right, newPane: b)
        tree.replace(a, with: c)
        #expect(tree.leaves == [c, b])
    }
}
