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

    private init() {}

    /// Reconcile tracked windows + focus/color to the current model. Called at the end of every
    /// refresh session. Cheap and idempotent.
    func reconcile() {
        guard config.border.enabled else {
            for border in borders.values { border.hide() }
            borders = [:]
            return
        }
        registerEventsIfNeeded()

        // Track every window currently visible on a visible workspace; those are the windows whose
        // border could be shown without a workspace switch. Others get torn down.
        let visibleWindows = Workspace.all
            .filter(\.isVisible)
            .flatMap { $0.allLeafWindowsRecursive }
        let desired = Set(visibleWindows.map(\.windowId))

        var changed = false
        for wid in borders.keys where !desired.contains(wid) {
            borders[wid]?.hide()
            borders[wid] = nil
            changed = true
        }
        for window in visibleWindows where borders[window.windowId] == nil {
            if let border = BorderWindow(cid: cid, targetWid: window.windowId) {
                borders[window.windowId] = border
                changed = true
            }
        }
        if changed { requestNotifications() }

        let focusedWid = focus.windowOrNil?.windowId
        let focusedBlacklisted = focus.windowOrNil.map { config.border.blacklist.contains($0.app.rawAppBundleId ?? "") } ?? false
        let activeColor = config.border.color(forWorkspace: focus.workspace.name)
        let width = CGFloat(config.border.width)
        let radius = CGFloat(config.border.cornerRadius)

        for (wid, border) in borders {
            let isFocused = wid == focusedWid && !focusedBlacklisted && focus.windowOrNil?.isFullscreen != true
            border.render(color: activeColor, width: width, cornerRadius: radius, visible: isFocused)
        }
    }

    // MARK: - Window-server events

    func onWindowMoved(_ wid: UInt32) {
        borders[wid]?.reposition()
    }

    func onWindowResized(_ wid: UInt32) {
        // Re-render with stored appearance (reshape + redraw at the new size)
        guard let border = borders[wid] else { return }
        border.render(
            color: config.border.color(forWorkspace: focus.workspace.name),
            width: CGFloat(config.border.width),
            cornerRadius: CGFloat(config.border.cornerRadius),
            visible: wid == focus.windowOrNil?.windowId,
        )
    }

    func onWindowDestroyed(_ wid: UInt32) {
        borders[wid]?.hide()
        borders[wid] = nil
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
                case EVENT_WINDOW_CLOSE, EVENT_WINDOW_DESTROY: BorderManager.shared.onWindowDestroyed(wid)
                default: break
            }
        }
    }
    let handler = unsafeBitCast(modify, to: UnsafeMutableRawPointer.self)
    let ctx = UnsafeMutableRawPointer(bitPattern: Int(cid))
    for event in [EVENT_WINDOW_MOVE, EVENT_WINDOW_RESIZE, EVENT_WINDOW_CLOSE] {
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
private let EVENT_WINDOW_DESTROY: UInt32 = 1326
