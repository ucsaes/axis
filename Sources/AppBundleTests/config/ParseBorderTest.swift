@testable import AppBundle
import Common
import XCTest

@MainActor
final class ParseBorderTest: XCTestCase {
    func testDefaults() {
        let result = parseConfig("")
        assertEquals(result.errors, [])
        assertEquals(result.config.border, BorderConfig.default)
    }

    func testFullBorderConfig() {
        let result = parseConfig(
            """
            [border]
            enabled = true
            width = 12
            corner-radius = 16
            blacklist = ['com.raycast.macos', 'com.kakao.KakaoTalkMac']

            [border.colors]
            default = '#ececee'
            1 = ['#e86c64', '#ce4a42']
            2 = '#eca644'
            """,
        )
        assertEquals(result.errors, [])
        let border = result.config.border
        assertEquals(border.enabled, true)
        assertEquals(border.width, 12)
        assertEquals(border.cornerRadius, 16)
        assertEquals(border.blacklist, ["com.raycast.macos", "com.kakao.KakaoTalkMac"])
        // #rrggbb gets opaque alpha
        assertEquals(border.defaultColor, BorderColor(stops: [0xFFEC_ECEE]))
        assertEquals(border.color(forWorkspace: "1"), BorderColor(stops: [0xFFE8_6C64, 0xFFCE_4A42]))
        assertEquals(border.color(forWorkspace: "2"), BorderColor(stops: [0xFFEC_A644]))
        // Unlisted workspace falls back to default
        assertEquals(border.color(forWorkspace: "9"), border.defaultColor)
    }

    func testGradientFlag() {
        assertEquals(BorderColor(stops: [0xFFE8_6C64, 0xFFCE_4A42]).isGradient, true)
        assertEquals(BorderColor(stops: [0xFFEC_A644]).isGradient, false)
    }

    func testUpToEightStops() {
        let eight = (1 ... 8).map { "'#\(String(repeating: String($0), count: 6))'" }.joined(separator: ", ")
        let result = parseConfig(
            """
            [border.colors]
            1 = [\(eight)]
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.config.border.color(forWorkspace: "1").stops.count, 8)
    }

    func testAlphaHexIsPreserved() {
        let result = parseConfig(
            """
            [border.colors]
            1 = '0x80ff0000'
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.config.border.color(forWorkspace: "1"), BorderColor(stops: [0x80FF_0000]))
    }

    func testInvalidColorReportsError() {
        let result = parseConfig(
            """
            [border.colors]
            1 = '#xyz'
            """,
        )
        assertEquals(result.errors, ["[ERROR] border.colors.1: Can't parse color '#xyz'. Expected #rrggbb, #aarrggbb, or 0xaarrggbb"])
    }

    func testTooManyStopsReportsError() {
        let nine = (1 ... 9).map { _ in "'#ff0000'" }.joined(separator: ", ")
        let result = parseConfig(
            """
            [border.colors]
            1 = [\(nine)]
            """,
        )
        assertEquals(result.errors, ["[ERROR] border.colors.1: A gradient must have 1 to 8 colors (corners and edge midpoints around the ring)"])
    }
}
