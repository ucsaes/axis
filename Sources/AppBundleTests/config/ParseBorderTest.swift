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
        assertEquals(border.defaultColor, BorderColor(topLeft: 0xFFEC_ECEE, bottomRight: 0xFFEC_ECEE))
        assertEquals(border.color(forWorkspace: "1"), BorderColor(topLeft: 0xFFE8_6C64, bottomRight: 0xFFCE_4A42))
        assertEquals(border.color(forWorkspace: "2"), BorderColor(topLeft: 0xFFEC_A644, bottomRight: 0xFFEC_A644))
        // Unlisted workspace falls back to default
        assertEquals(border.color(forWorkspace: "9"), border.defaultColor)
    }

    func testGradientFlag() {
        assertEquals(BorderColor(topLeft: 0xFFE8_6C64, bottomRight: 0xFFCE_4A42).isGradient, true)
        assertEquals(BorderColor(topLeft: 0xFFEC_A644, bottomRight: 0xFFEC_A644).isGradient, false)
    }

    func testAlphaHexIsPreserved() {
        let result = parseConfig(
            """
            [border.colors]
            1 = '0x80ff0000'
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.config.border.color(forWorkspace: "1"), BorderColor(topLeft: 0x80FF_0000, bottomRight: 0x80FF_0000))
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

    func testGradientMustBePair() {
        let result = parseConfig(
            """
            [border.colors]
            1 = ['#ff0000', '#00ff00', '#0000ff']
            """,
        )
        assertEquals(result.errors, ["[ERROR] border.colors.1: A gradient color must be a pair [top-left, bottom-right]"])
    }
}
