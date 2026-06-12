import AppKit
import Common
import PrivateApi

/// A window-server (SkyLight) window that draws the border for ONE target window and stays glued
/// to it for its whole lifetime. Following JankyBorders: the border is never moved between target
/// windows — focus changes only recolor/hide it — so there is no ghosting. Window-server move
/// events reposition it via a transaction with no redraw, which is what makes dragging smooth.
@MainActor
final class BorderWindow {
    let targetWid: UInt32
    private let cid: Int32
    private var context: CGContext?
    private var windowSize: CGSize = .zero

    // Last rendered appearance, so a move event can reposition without recomputing them
    private(set) var color: BorderColor = BorderColor(topLeft: 0, bottomRight: 0)
    private var width: CGFloat = 0
    private var cornerRadius: CGFloat = 0
    private(set) var isVisible = false

    /// SLS window tags. (1 << 1): no shadow. (1 << 9): keep out of normal window management.
    private static let setTags: UInt64 = (1 << 1) | (1 << 9)
    private static let tagSize: Int32 = 0x40

    let wid: UInt32

    init?(cid: Int32, targetWid: UInt32) {
        self.cid = cid
        self.targetWid = targetWid
        guard let region = Self.region(CGRect(x: 0, y: 0, width: 1, height: 1)) else { return nil }
        var wid: UInt32 = 0
        guard SLSNewWindow(cid, 2, 0, 0, region, &wid) == .success, wid != 0 else { return nil }
        self.wid = wid

        SLSSetWindowResolution(cid, wid, Double(NSScreen.main?.backingScaleFactor ?? 2))
        SLSSetWindowOpacity(cid, wid, false)
        var tags = Self.setTags
        SLSSetWindowTags(cid, wid, &tags, Self.tagSize)
        context = SLWindowContextCreate(cid, wid, nil)?.takeRetainedValue()
        context?.interpolationQuality = .none
    }

    deinit {
        SLSReleaseWindow(cid, wid)
    }

    private static func region(_ rect: CGRect) -> CFTypeRef? {
        var rect = rect
        var region: Unmanaged<CFTypeRef>?
        guard CGSNewRegionWithRect(&rect, &region) == .success else { return nil }
        return region?.takeRetainedValue()
    }

    private func targetBounds() -> CGRect? {
        var bounds = CGRect.zero
        guard SLSGetWindowBounds(cid, targetWid, &bounds) == .success, !bounds.isEmpty else { return nil }
        return bounds
    }

    /// Full update: reshape if the target resized, redraw the stroke, and (re)order. Used on
    /// create, resize, recolor, and focus changes.
    func render(color: BorderColor, width: CGFloat, cornerRadius: CGFloat, visible: Bool) {
        self.color = color
        self.width = width
        self.cornerRadius = cornerRadius
        self.isVisible = visible

        guard visible else { return hide() }
        guard let bounds = targetBounds() else { return hide() }
        // Outset by the full width so the whole stroke lands OUTSIDE the target frame (in the tiling
        // gap). Combined with placing the border one level above the target, this keeps the border
        // visible above any dimming overlay (e.g. HazeOver) without ever covering window content.
        let outset = width
        let frame = bounds.insetBy(dx: -outset, dy: -outset)

        SLSDisableUpdate(cid)
        defer { SLSReenableUpdate(cid) }

        if frame.size != windowSize, let region = Self.region(CGRect(origin: .zero, size: frame.size)) {
            SLSSetWindowShape(cid, wid, Float(frame.origin.x), Float(frame.origin.y), region)
            context = SLWindowContextCreate(cid, wid, nil)?.takeRetainedValue()
            context?.interpolationQuality = .none
        }
        windowSize = frame.size
        draw(size: frame.size)

        // Position + z-order in one atomic transaction. The border sits one level ABOVE the target:
        // a dimming overlay lives at the target's (normal) level, so a border at the same level races
        // it for z-order on every focus change (random dimming). One level up removes the race
        // entirely — the border is unconditionally above the overlay — and the outside-only stroke
        // means being above the window costs no content overlap.
        var level: Int32 = 0
        SLSGetWindowLevel(cid, targetWid, &level)
        let transaction = SLSTransactionCreate(cid).takeRetainedValue()
        SLSTransactionSetWindowLevel(transaction, wid, level + 1)
        SLSTransactionMoveWindowWithGroup(transaction, wid, frame.origin)
        SLSTransactionOrderWindow(transaction, wid, 1, targetWid)
        SLSTransactionCommit(transaction, 0)
    }

    /// Fast path for window-server move events: reposition only, no redraw. This is what keeps the
    /// border glued to the window during a mouse drag with no lag.
    func reposition() {
        guard isVisible, let bounds = targetBounds() else { return }
        let outset = width
        let origin = CGPoint(x: bounds.origin.x - outset, y: bounds.origin.y - outset)
        let transaction = SLSTransactionCreate(cid).takeRetainedValue()
        SLSTransactionMoveWindowWithGroup(transaction, wid, origin)
        SLSTransactionCommit(transaction, 0)
    }

    func hide() {
        isVisible = false
        SLSOrderWindow(cid, wid, 0, 0)
    }

    private func draw(size: CGSize) {
        guard let context else { return }
        context.clear(CGRect(origin: .zero, size: size))

        let inset = width / 2
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let radius = max(0, cornerRadius)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        context.saveGState()
        context.setLineWidth(width)
        context.addPath(path)
        context.replacePathWithStrokedPath()
        context.clip()

        if color.isGradient {
            let cgGradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [color.topLeft.cgColor, color.bottomRight.cgColor] as CFArray,
                locations: [0, 1],
            )
            if let cgGradient {
                // top-left -> bottom-right. SLS context origin is bottom-left, so top-left is (0, height)
                context.drawLinearGradient(
                    cgGradient,
                    start: CGPoint(x: 0, y: size.height),
                    end: CGPoint(x: size.width, y: 0),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation],
                )
            }
        } else {
            context.setFillColor(color.topLeft.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
        }
        context.restoreGState()

        context.flush()
        SLSFlushWindowContentRegion(cid, wid, nil)
    }
}

extension UInt32 {
    /// Interpret 0xAARRGGBB as a CGColor
    fileprivate var cgColor: CGColor {
        CGColor(
            red: CGFloat((self >> 16) & 0xFF) / 255,
            green: CGFloat((self >> 8) & 0xFF) / 255,
            blue: CGFloat(self & 0xFF) / 255,
            alpha: CGFloat((self >> 24) & 0xFF) / 255,
        )
    }
}
