import Common

/// How the connected monitors are physically arranged.
/// Axis assumes monitors form a single row or a single column (the user's invariant).
/// Non-collinear arrangements are resolved best-effort by the dominant axis.
enum MonitorArrangement: Sendable {
    /// Monitors are stacked top to bottom. Each monitor carries a horizontal strip,
    /// so the strip axis is left/right and the stack axis is up/down.
    case verticalStack
    /// Monitors are placed left to right. Each monitor carries a vertical strip,
    /// so the strip axis is up/down and the stack axis is left/right.
    case horizontalRow
}

/// Multi-monitor arrangement is detected from the physical layout. A single monitor has no layout
/// to infer from, so its strip direction comes from config (`strip-orientation`).
@MainActor
func detectMonitorArrangement(_ monitorRects: [Rect]) -> MonitorArrangement {
    guard monitorRects.count > 1 else { return config.singleMonitorStripArrangement }
    let xs = monitorRects.map(\.center.x)
    let ys = monitorRects.map(\.center.y)
    let xSpread = (xs.max() ?? 0) - (xs.min() ?? 0)
    let ySpread = (ys.max() ?? 0) - (ys.min() ?? 0)
    return xSpread > ySpread ? .horizontalRow : .verticalStack
}

/// The workspace plane defined by the `[strips]` config: a stack of workspace strips.
/// Multiple monitors pin strips 1:1 (monitor i carries strip i). A single monitor hosts
/// the whole stack and switches between strips on stack-axis navigation.
/// Present only when the config defines `[strips]` for the current number of monitors.
struct StripPlane {
    let arrangement: MonitorArrangement
    /// Monitors ordered along the arrangement axis (top to bottom, or left to right)
    let monitors: [Monitor]
    /// The strip stack, ordered along the same axis
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

    /// Strips are pinned 1:1 to monitors in multi-monitor setups. A single monitor hosts the whole stack
    func monitor(forStripAt index: Int) -> Monitor {
        monitors.count > 1 ? monitors[index] : monitors.first.orDie()
    }

    func position(ofWorkspace name: String) -> (stripIndex: Int, indexInStrip: Int)? {
        for (stripIndex, strip) in strips.enumerated() {
            if let indexInStrip = strip.firstIndex(of: name) {
                return (stripIndex, indexInStrip)
            }
        }
        return nil
    }

    /// The monitor the workspace is pinned to, or nil for workspaces outside the plane ("pocket" workspaces)
    func assignedMonitor(forWorkspace name: String) -> Monitor? {
        position(ofWorkspace: name).map { monitor(forStripAt: $0.stripIndex) }
    }

    /// The next workspace within the workspace's strip. Wraps around (strips loop)
    func workspaceInStrip(after workspaceName: String, inDirection direction: CardinalDirection) -> String? {
        guard let (stripIndex, indexInStrip) = position(ofWorkspace: workspaceName) else { return nil }
        let strip = strips[stripIndex]
        let targetIndex = (indexInStrip + direction.focusOffset + strip.count) % strip.count
        return strip[targetIndex]
    }

    /// The strip context of the workspace: its own strip, or for pocket workspaces the strip
    /// of the workspace previously visible on the same monitor (first hosted strip as a fallback)
    @MainActor func stripIndex(of workspace: Workspace) -> Int? {
        if let position = position(ofWorkspace: workspace.name) { return position.stripIndex }
        let monitor = workspace.workspaceMonitor
        if let prevVisible = prevVisibleWorkspaceName(on: monitor),
           let position = position(ofWorkspace: prevVisible)
        {
            return position.stripIndex
        }
        if monitors.count > 1 {
            return monitors.firstIndex { $0.rect.topLeftCorner == monitor.rect.topLeftCorner }
        }
        return 0
    }

    /// The most recently used workspace of the strip (the strip's first workspace until one is focused)
    @MainActor func mostRecentWorkspace(inStripAt index: Int) -> Workspace {
        let strip = strips[index]
        if let name = stripKeyToMruWorkspaceName[stripKey(strip)], strip.contains(name) {
            return Workspace.get(byName: name)
        }
        return Workspace.get(byName: strip.first.orDie())
    }

    /// Called on every focus change to keep per-strip MRU. Cheap: no-op unless [strips] is configured
    @MainActor static func recordFocusForStripMru(workspaceName: String) {
        guard !config.strips.isEmpty, let plane = StripPlane.current else { return }
        guard let position = plane.position(ofWorkspace: workspaceName) else { return }
        stripKeyToMruWorkspaceName[stripKey(plane.strips[position.stripIndex])] = workspaceName
    }
}

/// Keyed by strip content rather than index: indices are not stable across
/// monitor-count changes, stale keys of unplugged setups are harmless
@MainActor private var stripKeyToMruWorkspaceName: [String: String] = [:]
private func stripKey(_ strip: [String]) -> String { strip.joined(separator: "\u{1F}") }

/// Test isolation only
@MainActor func resetStripMruState() { stripKeyToMruWorkspaceName = [:] }
