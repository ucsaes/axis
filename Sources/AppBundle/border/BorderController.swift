import AppKit
import Common
import PrivateApi

/// Owns the focused-window border. Single entry point `refreshBorder()` is called whenever the
/// focus or layout might have changed; it decides whether to show a border, on which window, and
/// in what color. A lightweight timer tracks live frame changes during mouse drags/resizes, the
/// one case the window server moves a window without us driving it.
@MainActor
final class BorderController {
    static let shared = BorderController()

    private let cid: Int32 = SLSMainConnectionID()
    private var border: BorderWindow?
    private var trackedWid: UInt32?
    private var dragMonitor: Any?

    private init() {}

    /// Recompute the border from current focus/config. Cheap and idempotent — safe to call
    /// from every refresh session.
    func refreshBorder() {
        guard config.border.enabled else { return hideAndStopTracking() }
        guard let window = focus.windowOrNil,
              !window.isFullscreen,
              !config.border.blacklist.contains(window.app.rawAppBundleId ?? "")
        else { return hideAndStopTracking() }

        let color = config.border.color(forWorkspace: focus.workspace.name)
        draw(targetWid: window.windowId, color: color)
        installDragMonitor()
    }

    private func draw(targetWid: UInt32, color: BorderColor) {
        let border = border ?? BorderWindow(cid: cid)
        self.border = border
        guard let border else { return }
        trackedWid = targetWid
        let ok = border.update(
            around: targetWid,
            color: color,
            width: CGFloat(config.border.width),
            cornerRadius: CGFloat(config.border.cornerRadius),
        )
        if !ok { hideAndStopTracking() }
    }

    private func redrawTracked() {
        guard let trackedWid, config.border.enabled else { return }
        let color = config.border.color(forWorkspace: focus.workspace.name)
        if border?.update(
            around: trackedWid,
            color: color,
            width: CGFloat(config.border.width),
            cornerRadius: CGFloat(config.border.cornerRadius),
        ) != true {
            hideAndStopTracking()
        }
    }

    private func hideAndStopTracking() {
        border?.hide()
        trackedWid = nil
    }

    // MARK: - Drag/resize tracking

    /// Keyboard-driven moves are already covered by refreshBorder() at the end of every command,
    /// with zero lag because Axis itself moved the window. The remaining case is the user dragging
    /// or resizing a window with the mouse, where the window server moves it without telling us.
    /// A global drag monitor redraws on each drag event — event-driven, no polling. Installed once.
    private func installDragMonitor() {
        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { _ in
            MainActor.assumeIsolated {
                BorderController.shared.redrawTracked()
            }
        }
    }
}
