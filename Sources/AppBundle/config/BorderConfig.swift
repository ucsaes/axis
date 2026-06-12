import Common

struct BorderConfig: ConvenienceCopyable, Equatable, Sendable {
    var enabled: Bool
    var width: Int
    var cornerRadius: Int
    var blacklist: [String] // app bundle ids
    var defaultColor: BorderColor
    var workspaceColors: [String: BorderColor]

    static let `default` = BorderConfig(
        enabled: false,
        width: 6,
        cornerRadius: 12,
        blacklist: [],
        defaultColor: BorderColor(topLeft: 0xFFEC_ECEE, bottomRight: 0xFFCC_CCD0),
        workspaceColors: [:],
    )

    @MainActor func color(forWorkspace name: String) -> BorderColor {
        workspaceColors[name] ?? defaultColor
    }
}

/// A border color: a single solid color (topLeft == bottomRight) or a top-left → bottom-right gradient.
/// Stored as 0xAARRGGBB.
struct BorderColor: Equatable, Sendable {
    var topLeft: UInt32
    var bottomRight: UInt32

    var isGradient: Bool { topLeft != bottomRight }
}
