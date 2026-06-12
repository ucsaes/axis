import Common

/// How the connected monitors are physically arranged.
/// Axis assumes monitors form a single row or a single column (the user's invariant).
/// Non-collinear arrangements are resolved best-effort by the dominant axis.
enum MonitorArrangement: Sendable {
    /// Monitors are stacked top to bottom. Each monitor carries a horizontal strip,
    /// so the strip axis is left/right and the monitor axis is up/down.
    case verticalStack
    /// Monitors are placed left to right. Each monitor carries a vertical strip,
    /// so the strip axis is up/down and the monitor axis is left/right.
    case horizontalRow
}

func detectMonitorArrangement(_ monitorRects: [Rect]) -> MonitorArrangement {
    // A single monitor carries a horizontal strip
    guard monitorRects.count > 1 else { return .verticalStack }
    let xs = monitorRects.map(\.center.x)
    let ys = monitorRects.map(\.center.y)
    let xSpread = (xs.max() ?? 0) - (xs.min() ?? 0)
    let ySpread = (ys.max() ?? 0) - (ys.min() ?? 0)
    return xSpread > ySpread ? .horizontalRow : .verticalStack
}

/// The workspace plane: one strip of workspaces per monitor.
/// Present only when the config defines `[strips]` for the current number of monitors.
struct StripPlane {
    let arrangement: MonitorArrangement
    /// Monitors ordered along the arrangement axis (top to bottom, or left to right)
    let monitors: [Monitor]
    /// strips[i] is pinned to monitors[i]
    let strips: [[String]]

    @MainActor static var current: StripPlane? {
        let allMonitors = AppBundle.monitors
        guard let strips = config.strips[allMonitors.count] else { return nil }
        let arrangement = detectMonitorArrangement(allMonitors.map { $0.rect })
        let orderedMonitors = switch arrangement {
            case .verticalStack: allMonitors.sortedBy([\.rect.minY, \.rect.minX])
            case .horizontalRow: allMonitors.sortedBy([\.rect.minX, \.rect.minY])
        }
        return StripPlane(arrangement: arrangement, monitors: orderedMonitors, strips: strips)
    }

    /// The orientation of movement *within* a strip
    var stripAxisOrientation: Orientation {
        switch arrangement {
            case .verticalStack: .h
            case .horizontalRow: .v
        }
    }

    func position(ofWorkspace name: String) -> (stripIndex: Int, indexInStrip: Int)? {
        for (stripIndex, strip) in strips.enumerated() {
            if let indexInStrip = strip.firstIndex(of: name) {
                return (stripIndex, indexInStrip)
            }
        }
        return nil
    }

    func monitorIndex(of monitor: Monitor) -> Int? {
        monitors.firstIndex { $0.rect.topLeftCorner == monitor.rect.topLeftCorner }
    }

    /// The monitor the workspace is pinned to, or nil for workspaces outside the plane ("pocket" workspaces)
    func assignedMonitor(forWorkspace name: String) -> Monitor? {
        position(ofWorkspace: name).map { monitors[$0.stripIndex] }
    }

    /// The next workspace within the workspace's strip. Wraps around (strips loop)
    func workspaceInStrip(after workspaceName: String, inDirection direction: CardinalDirection) -> String? {
        guard let (stripIndex, indexInStrip) = position(ofWorkspace: workspaceName) else { return nil }
        let strip = strips[stripIndex]
        let targetIndex = (indexInStrip + direction.focusOffset + strip.count) % strip.count
        return strip[targetIndex]
    }
}
