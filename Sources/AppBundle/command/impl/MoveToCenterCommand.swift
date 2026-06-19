import AppKit
import Common

/// Centers the focused floating window on its monitor (à la Rectangle). Tiling windows are managed
/// by the layout engine, so centering only applies to floating windows.
struct MoveToCenterCommand: Command {
    let args: MoveToCenterCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        guard window.isFloating else {
            return .succ(io.err("move-to-center only applies to floating windows. Tip: 'layout floating' first"))
        }
        guard let rect = try await window.getAxRect() else { return .fail }

        let visible = (window.nodeMonitor ?? target.workspace.workspaceMonitor).visibleRect
        let topLeft = CGPoint(
            x: visible.topLeftX + (visible.width - rect.width) / 2,
            y: visible.topLeftY + (visible.height - rect.height) / 2,
        )
        window.setAxFrame(topLeft, nil)
        return .succ
    }
}
