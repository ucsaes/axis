import AppKit
import Common

/// Navigates the workspace plane defined by the `[strips]` config.
///
/// In any direction, window focus moves within the workspace first. What happens at the
/// workspace boundary depends on the axis of the direction:
/// - Strip axis (perpendicular to the monitor arrangement): the next workspace in the strip
///   of the current monitor (wraps around). Focus enters at the window closest to the
///   entered side, e.g. `nav right` lands on the leftmost window of the next workspace.
/// - Monitor axis (along the monitor arrangement): the visible workspace of the neighbor
///   monitor. Movement stops at the outermost monitors.
///
/// Workspaces outside the plane ("pocket" workspaces, e.g. dedicated app workspaces) can be
/// visited freely; strip-axis navigation from a pocket returns to the monitor's strip.
struct NavCommand: Command {
    let args: NavCmdArgs
    /*conforms*/ var shouldResetClosedWindowsCache: Bool { args.carry }

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let plane = StripPlane.current else {
            return .fail(io.err("nav requires a [strips] config entry for the current number of monitors (\(monitors.count))"))
        }
        let direction = args.direction.val

        // 1. Move within the workspace if there is a window in the given direction
        if let window = target.windowOrNil {
            if args.carry {
                // Delegate to 'move' with silenced IO: a boundary hit must fall through to the plane
                let moveArgs = MoveCmdArgs(rawArgs: [], direction)
                    .copy(\.windowId, window.windowId)
                    .copy(\.rawBoundaries, .workspace)
                    .copy(\.rawBoundariesAction, .fail)
                if try await MoveCommand(args: moveArgs).run(env, CmdIo(stdin: .emptyStdin)) == .succ {
                    return .succ
                }
            } else if let (parent, ownIndex) = window.closestParent(hasChildrenInDirection: direction, withLayout: nil) {
                guard let windowToFocus = parent.children[ownIndex + direction.focusOffset]
                    .findLeafWindowRecursive(snappedTo: direction.opposite) else { return .fail }
                return .from(bool: windowToFocus.focusWindow())
            }
        }

        // 2. Workspace boundary is hit
        return direction.orientation == plane.stripAxisOrientation
            ? navAlongStrip(target, plane, direction, io)
            : navAcrossStack(target, plane, direction, io)
    }

    @MainActor private func navAlongStrip(
        _ target: LiveFocus,
        _ plane: StripPlane,
        _ direction: CardinalDirection,
        _ io: CmdIo,
    ) -> BinaryExitCode {
        let currentWs = target.workspace
        let targetWs: Workspace
        if let next = plane.workspaceInStrip(after: currentWs.name, inDirection: direction) {
            if next == currentWs.name { return .succ } // Single-workspace strip
            targetWs = Workspace.get(byName: next)
        } else {
            // Pocket workspace: return to the most recently used workspace of the context strip
            guard let stripIndex = plane.stripIndex(of: currentWs) else {
                return .fail(io.err("Should never happen. Can't find the current monitor in the strip plane"))
            }
            targetWs = plane.mostRecentWorkspace(inStripAt: stripIndex)
        }
        return goTo(workspace: targetWs, target, direction, io)
    }

    @MainActor private func navAcrossStack(
        _ target: LiveFocus,
        _ plane: StripPlane,
        _ direction: CardinalDirection,
        _ io: CmdIo,
    ) -> BinaryExitCode {
        guard let currentStripIndex = plane.stripIndex(of: target.workspace) else {
            return .fail(io.err("Should never happen. Can't find the current monitor in the strip plane"))
        }
        let targetStripIndex = currentStripIndex + direction.focusOffset
        guard plane.strips.indices.contains(targetStripIndex) else {
            return .succ // The outermost strip: the stack axis doesn't wrap
        }
        let targetMonitor = plane.monitor(forStripAt: targetStripIndex)
        let currentMonitor = target.workspace.workspaceMonitor
        let targetWs: Workspace = targetMonitor.rect.topLeftCorner != currentMonitor.rect.topLeftCorner
            ? targetMonitor.activeWorkspace // Jump to whatever is visible on the neighbor monitor
            : plane.mostRecentWorkspace(inStripAt: targetStripIndex) // Hidden strip on the same monitor
        return goTo(workspace: targetWs, target, direction, io)
    }

    @MainActor private func goTo(
        workspace targetWs: Workspace,
        _ target: LiveFocus,
        _ direction: CardinalDirection,
        _ io: CmdIo,
    ) -> BinaryExitCode {
        if args.carry {
            guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
            // Enter the workspace from the side we came from
            let index = direction.isPositive ? 0 : INDEX_BIND_LAST
            return moveWindowToWorkspace(window, targetWs, io, focusFollowsWindow: true, failIfNoop: false, index: index)
        }
        if let windowToFocus = targetWs.findLeafWindowRecursive(snappedTo: direction.opposite) {
            return .from(bool: windowToFocus.focusWindow())
        }
        return .from(bool: targetWs.focusWorkspace())
    }
}
