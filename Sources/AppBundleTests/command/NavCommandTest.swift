@testable import AppBundle
import Common
import XCTest

@MainActor
final class NavCommandTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        // Single test monitor carrying one strip: [1, 2, 3]
        config.strips = [1: [["1", "2", "3"]]]
    }

    func testParse() {
        testParseCommandSucc("nav left", NavCmdArgs(rawArgs: [], .left))
        testParseCommandSucc("nav --carry right", NavCmdArgs(rawArgs: [], .right).copy(\.carry, true))
        assertEquals(parseCommand("nav").errorOrNil, "ERROR: Argument '(left|down|up|right)' is mandatory")
    }

    func testFailsWithoutStripsConfig() async throws {
        config.strips = [:]
        Workspace.get(byName: "1").rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }
        let result = try await NavCommand(args: NavCmdArgs(rawArgs: [], .right)).run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
    }

    func testFocusWindowWithinWorkspaceFirst() async throws {
        let ws = Workspace.get(byName: "1")
        var w1: TestWindow!
        ws.rootTilingContainer.apply {
            w1 = TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
            _ = w1.focusWindow()
        }
        try await NavCommand(args: NavCmdArgs(rawArgs: [], .right)).run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil?.windowId, 2)
        assertEquals(focus.workspace.name, "1")
    }

    func testStripAxisAdvancesToNextWorkspaceAtBoundary() async throws {
        Workspace.get(byName: "1").rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            _ = TestWindow.new(id: 2, parent: $0).focusWindow() // rightmost
        }
        try await NavCommand(args: NavCmdArgs(rawArgs: [], .right)).run(.defaultEnv, .emptyStdin)
        assertEquals(focus.workspace.name, "2")
    }

    func testStripAxisEntersAtOppositeEdge() async throws {
        Workspace.get(byName: "1").rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }
        Workspace.get(byName: "2").rootTilingContainer.apply {
            TestWindow.new(id: 10, parent: $0)
            TestWindow.new(id: 11, parent: $0)
        }
        try await NavCommand(args: NavCmdArgs(rawArgs: [], .right)).run(.defaultEnv, .emptyStdin)
        // nav right lands on the leftmost window of the next workspace
        assertEquals(focus.workspace.name, "2")
        assertEquals(focus.windowOrNil?.windowId, 10)
    }

    func testStripWrapsAround() async throws {
        Workspace.get(byName: "1").rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }
        try await NavCommand(args: NavCmdArgs(rawArgs: [], .left)).run(.defaultEnv, .emptyStdin)
        assertEquals(focus.workspace.name, "3") // 1 -> wraps to the strip end
        try await NavCommand(args: NavCmdArgs(rawArgs: [], .right)).run(.defaultEnv, .emptyStdin)
        assertEquals(focus.workspace.name, "1") // and back
    }

    func testMonitorAxisStopsOnSingleMonitor() async throws {
        Workspace.get(byName: "1").rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }
        let result = try await NavCommand(args: NavCmdArgs(rawArgs: [], .down)).run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0) // Stops quietly at the outermost monitor
        assertEquals(focus.workspace.name, "1")
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    func testMonitorAxisStillFocusesWindowsWithinWorkspace() async throws {
        let ws = Workspace.get(byName: "1")
        var top: TestWindow!
        TilingContainer.newVTiles(parent: ws.rootTilingContainer, adaptiveWeight: 1, index: 0).apply {
            top = TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
            _ = top.focusWindow()
        }
        try await NavCommand(args: NavCmdArgs(rawArgs: [], .down)).run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil?.windowId, 2)
        assertEquals(focus.workspace.name, "1")
    }

    func testCarryMovesWindowToNextWorkspace() async throws {
        Workspace.get(byName: "1").rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }
        Workspace.get(byName: "2").rootTilingContainer.apply {
            TestWindow.new(id: 10, parent: $0)
        }
        try await NavCommand(args: NavCmdArgs(rawArgs: [], .right).copy(\.carry, true)).run(.defaultEnv, .emptyStdin)
        XCTAssertTrue(Workspace.get(byName: "1").isEffectivelyEmpty)
        assertEquals(focus.workspace.name, "2")
        assertEquals(focus.windowOrNil?.windowId, 1)
        // Carrying rightwards enters the workspace at the leftmost position
        assertEquals(Workspace.get(byName: "2").rootTilingContainer.children.map { ($0 as? Window)?.windowId }, [1, 10])
    }

    func testCarryWithinWorkspaceFirst() async throws {
        let ws = Workspace.get(byName: "1")
        var w1: TestWindow!
        ws.rootTilingContainer.apply {
            w1 = TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
            _ = w1.focusWindow()
        }
        try await NavCommand(args: NavCmdArgs(rawArgs: [], .right).copy(\.carry, true)).run(.defaultEnv, .emptyStdin)
        // Windows swapped within the workspace, no workspace switch
        assertEquals(focus.workspace.name, "1")
        assertEquals(ws.rootTilingContainer.children.map { ($0 as? Window)?.windowId }, [2, 1])
    }

    func testPocketWorkspaceReturnsToStrip() async throws {
        Workspace.get(byName: "2").rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }
        check(Workspace.get(byName: "2").focusWorkspace())
        // Visit the pocket workspace S (not in any strip)
        Workspace.get(byName: "S").rootTilingContainer.apply {
            TestWindow.new(id: 20, parent: $0)
        }
        check(Workspace.get(byName: "S").focusWorkspace())
        assertEquals(focus.workspace.name, "S")

        // Strip-axis navigation from the pocket returns to the strip (most recently used workspace)
        try await NavCommand(args: NavCmdArgs(rawArgs: [], .right)).run(.defaultEnv, .emptyStdin)
        assertEquals(focus.workspace.name, "2")
    }
}
