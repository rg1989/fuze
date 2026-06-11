import XCTest
@testable import Fuse

/// In-memory AX tree node for exercising NotificationSweep without the
/// live Accessibility API.
final class MockNode: AXTreeNode {
    var mockChildren: [MockNode]
    var mockRole: String?
    var mockSubrole: String?
    var mockActions: [(name: String, description: String?)]
    /// When true, performNodeAction records the attempt but reports failure.
    var failActions: Bool
    private(set) var performedActions: [String] = []

    init(role: String? = nil, subrole: String? = nil,
         actions: [(name: String, description: String?)] = [],
         children: [MockNode] = [], failActions: Bool = false) {
        self.mockRole = role
        self.mockSubrole = subrole
        self.mockActions = actions
        self.mockChildren = children
        self.failActions = failActions
    }

    var childNodes: [MockNode] { mockChildren }
    var nodeRole: String? { mockRole }
    var nodeSubrole: String? { mockSubrole }
    func nodeActions() -> [(name: String, description: String?)] { mockActions }

    @discardableResult
    func performNodeAction(named name: String) -> Bool {
        performedActions.append(name)
        return !failActions
    }
}

final class NotificationSweepTests: XCTestCase {

    // MARK: - SweepMatch (description matchers)

    func testClearAllMatcherAcceptsAndRejects() {
        XCTAssertTrue(SweepMatch.isClearAll("Clear All"))
        XCTAssertTrue(SweepMatch.isClearAll("clear all"))
        XCTAssertTrue(SweepMatch.isClearAll("CLEAR ALL"))
        XCTAssertFalse(SweepMatch.isClearAll(nil))
        XCTAssertFalse(SweepMatch.isClearAll(""))
        XCTAssertFalse(SweepMatch.isClearAll("Close"))
        XCTAssertFalse(SweepMatch.isClearAll("Show Details"))
    }

    func testCloseMatchesCloseAndClearButNotClearAll() {
        XCTAssertTrue(SweepMatch.isClose("Close"))
        XCTAssertTrue(SweepMatch.isClose("close"))
        XCTAssertTrue(SweepMatch.isClose("Clear"))
        XCTAssertFalse(SweepMatch.isClose("Clear All"))
        XCTAssertFalse(SweepMatch.isClose(nil))
    }

    func testExtraPhrasesExtendTheMatchers() {
        XCTAssertFalse(SweepMatch.isClearAll("Alle entfernen"))
        XCTAssertTrue(SweepMatch.isClearAll("Alle entfernen", extraPhrases: ["alle entfernen"]))
    }

    // MARK: - collect

    func testFindsClearAllTwoLevelsDeep() {
        let grandchild = MockNode(role: "AXButton", actions: [(name: "Name:clear-all", description: "Clear All")])
        let child = MockNode(role: "AXGroup", children: [grandchild])
        let root = MockNode(role: "AXWindow", children: [child])

        let items = NotificationSweep.collect(root: root, maxDepth: 12)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].actionName, "Name:clear-all")
        XCTAssertTrue(items[0].isClearAll)
    }

    func testDepthLimitRespected() {
        // Linear chain: root is depth 0; `deepest` (which carries the action)
        // ends up at depth 13 after 13 wraps.
        let deepest = MockNode(actions: [(name: "Name:close", description: "Close")])
        var node = deepest
        for _ in 0..<13 {
            node = MockNode(children: [node])
        }
        let root = node

        XCTAssertTrue(NotificationSweep.collect(root: root, maxDepth: 12).isEmpty,
                      "an action at depth 13 must be ignored when maxDepth is 12")
        XCTAssertEqual(NotificationSweep.collect(root: root, maxDepth: 13).count, 1)
    }

    // MARK: - performSweep

    func testPrefersClearAllOverCloseWhenBothPresent() {
        let closeButton = MockNode(actions: [(name: "Name:close", description: "Close")])
        let clearAllButton = MockNode(actions: [(name: "Name:clear-all", description: "Clear All")])
        let root = MockNode(children: [closeButton, clearAllButton])

        let performed = NotificationSweep.performSweep(root: root, maxDepth: 12)

        XCTAssertEqual(performed, 1)
        XCTAssertEqual(clearAllButton.performedActions, ["Name:clear-all"])
        XCTAssertTrue(closeButton.performedActions.isEmpty,
                      "Close must not fire when a Clear All exists")
    }

    func testPerformsAllCloseActionsWhenNoClearAll() {
        let banners = (0..<3).map { i in
            MockNode(actions: [(name: "Name:close-\(i)", description: "Close")])
        }
        let root = MockNode(children: banners)

        let performed = NotificationSweep.performSweep(root: root, maxDepth: 12)

        XCTAssertEqual(performed, 3)
        for banner in banners {
            XCTAssertEqual(banner.performedActions.count, 1)
        }
    }

    func testEmptyTreeReturnsZero() {
        let root = MockNode()
        XCTAssertTrue(NotificationSweep.collect(root: root, maxDepth: 12).isEmpty)
        XCTAssertEqual(NotificationSweep.performSweep(root: root, maxDepth: 12), 0)
    }

    func testFailedActionsAreNotCounted() {
        let stuck = MockNode(actions: [(name: "Name:close", description: "Close")], failActions: true)
        let root = MockNode(children: [stuck])

        XCTAssertEqual(NotificationSweep.performSweep(root: root, maxDepth: 12), 0)
        XCTAssertEqual(stuck.performedActions, ["Name:close"], "the action must still be attempted")
    }
}
