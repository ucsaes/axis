import AppKit
import Common
import PrivateApi

/// Owns one border per managed window, following JankyBorders' model: borders are glued to their
/// window for life and never moved between windows, so focus changes only recolor (no ghosting).
/// Window-server events reposition the relevant border directly (smooth dragging). Axis drives
/// which windows are tracked and which one is focused / what color it gets.
@MainActor
final class BorderManager {
    static let shared = BorderManager()

    private let cid: Int32 = SLSMainConnectionID()
    private var borders: [UInt32: BorderWindow] = [:]
    private var eventsRegistered = false
    private var visibleWid: UInt32?

    private init() {}

    /// Reconcile tracked windows + focus/color to the current model. Called at the end of every
    /// refresh session. Cheap and idempotent.
    func reconcile() {
        guard config.border.enabled else {
            for border in borders.values { border.hide() }
            borders = [:]
            visibleWid = nil
            return
        }
        registerEventsIfNeeded()

        // A border is kept for every managed window for the window's whole lifetime, regardless of
        // which workspace is visible. Tearing borders down on a workspace switch would recreate them
        // as brand-new window-server windows, which dimming tools (e.g. HazeOver) then re-classify
        // from scratch — causing random dimming right after a switch. Keeping the wid stable avoids
        // that entirely. Borders are removed only when their window is destroyed.
        let allWindows = Workspace.all.flatMap { $0.allLeafWindowsRecursive }
        let desired = Set(allWindows.map(\.windowId))

        var changed = false
        for wid in borders.keys where !desired.contains(wid) {
            borders[wid]?.hide()
            borders[wid] = nil
            changed = true
        }
        for window in allWindows where borders[window.windowId] == nil {
            if let border = BorderWindow(cid: cid, targetWid: window.windowId) {
                borders[window.windowId] = border
                changed = true
            }
        }
        if changed { requestNotifications() }

        // The border color is a static function of the window's workspace, so it isn't recomputed on
        // focus changes — only when a window's workspace assignment changes. Focus changes just
        // toggle which border is visible; the drag fast path keeps positions current via events.
        let newVisibleWid = focusedBorderWid()
        if newVisibleWid != visibleWid, let old = visibleWid {
            borders[old]?.hide()
        }
        visibleWid = newVisibleWid
        guard let wid = newVisibleWid, let border = borders[wid], let window = Window.get(byId: wid) else { return }
        let color = config.border.color(forWorkspace: window.nodeWorkspace?.name ?? focus.workspace.name)
        // Re-render only when something actually changed (focus moved here, color/size differs).
        if !border.isVisible || border.color != color {
            border.render(color: color, width: CGFloat(config.border.width), cornerRadius: CGFloat(config.border.cornerRadius), visible: true)
        }
    }

    /// The window that should currently show a border, or nil (empty workspace, fullscreen, blacklisted).
    private func focusedBorderWid() -> UInt32? {
        guard let window = focus.windowOrNil, !window.isFullscreen,
              !config.border.blacklist.contains(window.app.rawAppBundleId ?? "") else { return nil }
        return window.windowId
    }

    // MARK: - Window-server events

    func onWindowMoved(_ wid: UInt32) {
        borders[wid]?.reposition()
    }

    func onWindowResized(_ wid: UInt32) {
        // Only the visible (focused) border needs to be redrawn at the new size; hidden ones are
        // redrawn lazily when they become focused.
        guard wid == visibleWid, let border = borders[wid] else { return }
        border.render(color: border.color, width: CGFloat(config.border.width), cornerRadius: CGFloat(config.border.cornerRadius), visible: true)
    }

    /// A window changed z-order. Axis focuses windows by raising them asynchronously (AXRaise on the
    /// app's thread), so the focused window is raised *after* the synchronous border render — at which
    /// point this event fires. Re-place the border below the now-raised window so it doesn't stay
    /// stuck behind the previously-focused window (and so HazeOver sees the correct front window).
    func onWindowReordered(_ wid: UInt32) {
        guard wid == visibleWid, let border = borders[wid] else { return }
        border.render(color: border.color, width: CGFloat(config.border.width), cornerRadius: CGFloat(config.border.cornerRadius), visible: true)
    }

    func onWindowDestroyed(_ wid: UInt32) {
        borders[wid]?.hide()
        borders[wid] = nil
        if visibleWid == wid { visibleWid = nil }
    }

    /// Drop all borders so the next reconcile rebuilds them with current config (width, radius,
    /// colors). Called on config reload, where every setting may have changed.
    func invalidateAll() {
        for border in borders.values { border.hide() }
        borders = [:]
        visibleWid = nil
    }

    private func requestNotifications() {
        var list = Array(borders.keys)
        guard !list.isEmpty else { return }
        SLSRequestNotificationsForWindows(cid, &list, Int32(list.count))
    }

    private func registerEventsIfNeeded() {
        guard !eventsRegistered else { return }
        eventsRegistered = true
        registerBorderEvents(cid)
    }
}

// MARK: - C event bridge

/// Window-server move/resize/destroy events arrive as C callbacks on the run loop the event port
/// is attached to (the main run loop). They carry the target window id; we forward to the manager.
private func registerBorderEvents(_ cid: Int32) {
    let modify: @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void = { event, data, _, _ in
        guard let data else { return }
        let wid = data.load(as: UInt32.self)
        MainActor.assumeIsolated {
            switch event {
                case EVENT_WINDOW_MOVE: BorderManager.shared.onWindowMoved(wid)
                case EVENT_WINDOW_RESIZE: BorderManager.shared.onWindowResized(wid)
                case EVENT_WINDOW_REORDER: BorderManager.shared.onWindowReordered(wid)
                case EVENT_WINDOW_CLOSE, EVENT_WINDOW_DESTROY: BorderManager.shared.onWindowDestroyed(wid)
                default: break
            }
        }
    }
    let handler = unsafeBitCast(modify, to: UnsafeMutableRawPointer.self)
    let ctx = UnsafeMutableRawPointer(bitPattern: Int(cid))
    for event in [EVENT_WINDOW_MOVE, EVENT_WINDOW_RESIZE, EVENT_WINDOW_REORDER, EVENT_WINDOW_CLOSE] {
        SLSRegisterNotifyProc(handler, event, ctx)
    }
    // The spawn-event payload puts the wid after a uint64 space id; destroy is enough for cleanup.
    let spawn: @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void = { event, data, _, _ in
        guard let data, event == EVENT_WINDOW_DESTROY else { return }
        let wid = data.load(fromByteOffset: 8, as: UInt32.self)
        MainActor.assumeIsolated { BorderManager.shared.onWindowDestroyed(wid) }
    }
    SLSRegisterNotifyProc(unsafeBitCast(spawn, to: UnsafeMutableRawPointer.self), EVENT_WINDOW_DESTROY, ctx)

    // Pump the connection's event port on the main run loop so the notify procs above fire.
    var port = mach_port_t()
    guard SLSGetEventPort(cid, &port) == .success else { return }
    let drain: @convention(c) (CFMachPort?, UnsafeMutableRawPointer?, CFIndex, UnsafeMutableRawPointer?) -> Void = { _, _, _, _ in
        let cid = SLSMainConnectionID()
        while let event = SLEventCreateNextEvent(cid) {
            event.release()
        }
    }
    guard let cfPort = CFMachPortCreateWithPort(nil, port, drain, nil, nil) else { return }
    _CFMachPortSetOptions(cfPort, 0x40)
    if let source = CFMachPortCreateRunLoopSource(nil, cfPort, 0) {
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }
}

private let EVENT_WINDOW_CLOSE: UInt32 = 804
private let EVENT_WINDOW_MOVE: UInt32 = 806
private let EVENT_WINDOW_RESIZE: UInt32 = 807
private let EVENT_WINDOW_REORDER: UInt32 = 808
private let EVENT_WINDOW_DESTROY: UInt32 = 1326
