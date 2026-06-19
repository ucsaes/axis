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
        defaultColor: BorderColor(stops: [0xFFEC_ECEE, 0xFFCC_CCD0]),
        workspaceColors: [:],
    )

    @MainActor func color(forWorkspace name: String) -> BorderColor {
        workspaceColors[name] ?? defaultColor
    }
}

/// A border color: 1 to 8 stops (each 0xAARRGGBB) placed around the border ring. The number of
/// stops decides the layout (see BorderWindow for rendering):
/// - 1: solid
/// - 2: top-left → bottom-right diagonal gradient
/// - 4: one per corner
/// - 8: corners + edge midpoints (clockwise from top-left)
/// - other counts: spread evenly around the ring
struct BorderColor: Equatable, Sendable {
    var stops: [UInt32]

    var isGradient: Bool { stops.count > 1 }
}
