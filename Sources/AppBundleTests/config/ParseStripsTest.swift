@testable import AppBundle
import Common
import XCTest

@MainActor
final class ParseStripsTest: XCTestCase {
    func testParseStripsFullForm() {
        let result = parseConfig(
            """
            [strips]
            1 = ['1', '2', '3', '4', '5']
            2 = [['1', '2', '3', '4', '5'], ['6', '7', '8']]
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.config.strips[1], [["1", "2", "3", "4", "5"]])
        assertEquals(result.config.strips[2], [["1", "2", "3", "4", "5"], ["6", "7", "8"]])
    }

    func testSingleStripShorthandAndBareNumbers() {
        let result = parseConfig(
            """
            [strips]
            1 = [1, 2, 3]
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.config.strips[1], [["1", "2", "3"]])
    }

    func testSingleMonitorHostsAStackOfStrips() {
        let result = parseConfig(
            """
            [strips]
            1 = [['S', 'D'], ['1', '2', '3'], ['M']]
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.config.strips[1], [["S", "D"], ["1", "2", "3"], ["M"]])
    }

    func testStripCountMustMatchMonitorCount() {
        let result = parseConfig(
            """
            [strips]
            2 = [['1', '2', '3']]
            """,
        )
        assertEquals(result.errors, ["[ERROR] strips.2: strips.2 must define exactly 2 strip(s) (one per monitor). But it defines 1"])
    }

    func testDuplicateWorkspaceAcrossStrips() {
        let result = parseConfig(
            """
            [strips]
            2 = [['1', '2'], ['2', '3']]
            """,
        )
        assertEquals(result.errors, ["[ERROR] strips.2[1]: Workspace '2' appears in multiple strips"])
    }

    func testInvalidMonitorCountKey() {
        let result = parseConfig(
            """
            [strips]
            zero = [['1']]
            """,
        )
        assertEquals(result.errors, ["[ERROR] strips.zero: The key must be a positive number of monitors. But got: 'zero'"])
    }

    func testEmptyStripIsRejected() {
        let result = parseConfig(
            """
            [strips]
            2 = [['1'], []]
            """,
        )
        assertEquals(result.errors, ["[ERROR] strips.2[1]: A strip must contain at least one workspace"])
    }

    func testStripMembersBecomePersistent() {
        let result = parseConfig(
            """
            [strips]
            2 = [['1', '2'], ['6', '7']]
            """,
        )
        assertEquals(result.errors, [])
        for name in ["1", "2", "6", "7"] {
            XCTAssertTrue(result.config.persistentWorkspaces.contains(name), "workspace \(name) must be persistent")
        }
    }
}

final class DetectMonitorArrangementTest: XCTestCase {
    private func rect(_ x: CGFloat, _ y: CGFloat, w: CGFloat = 1920, h: CGFloat = 1080) -> Rect {
        Rect(topLeftX: x, topLeftY: y, width: w, height: h)
    }

    func testSingleMonitorIsVerticalStack() {
        assertEquals(detectMonitorArrangement([rect(0, 0)]), .verticalStack)
    }

    func testVerticalStack() {
        assertEquals(detectMonitorArrangement([rect(0, 0), rect(0, 1080)]), .verticalStack)
        assertEquals(detectMonitorArrangement([rect(0, 0), rect(100, 1080), rect(50, 2160)]), .verticalStack)
    }

    func testHorizontalRow() {
        assertEquals(detectMonitorArrangement([rect(0, 0), rect(1920, 0)]), .horizontalRow)
        assertEquals(detectMonitorArrangement([rect(0, 100), rect(1920, 0), rect(3840, 50)]), .horizontalRow)
    }

    func testWeirdArrangementResolvesByDominantAxis() {
        // Diagonal-ish arrangement: x spread is wider than y spread -> horizontal row
        assertEquals(detectMonitorArrangement([rect(0, 0), rect(1920, 900)]), .horizontalRow)
    }
}
