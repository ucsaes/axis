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
    private(set) var color: BorderColor = BorderColor(stops: [0])
    private var width: CGFloat = 0
    private var cornerRadius: CGFloat = 0
    // What was last painted into the window buffer. The SLS surface keeps its content while the
    // border is hidden (ordered out), so re-showing an unchanged border can skip the (expensive,
    // for multi-stop gradients) repaint and just reorder it back in.
    private var painted: (size: CGSize, color: BorderColor, width: CGFloat, cornerRadius: CGFloat)?
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
            painted = nil // new surface starts blank
        }
        windowSize = frame.size

        // Repaint only when the appearance actually changed. Re-focusing an unchanged window keeps
        // the existing buffer (the SLS surface survives being hidden), which matters most for the
        // multi-stop conic gradient whose repaint is the costly part of a focus switch.
        let want = (size: frame.size, color: color, width: width, cornerRadius: cornerRadius)
        if painted.map({ $0 != want }) ?? true {
            draw(size: frame.size)
            painted = want
        }

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

        let stops = color.stops
        switch stops.count {
            case 0: break
            case 1:
                context.setFillColor(stops[0].cgColor)
                context.fill(CGRect(origin: .zero, size: size))
            case 2:
                // top-left -> bottom-right. SLS context origin is bottom-left, so top-left is (0, height)
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [stops[0].cgColor, stops[1].cgColor] as CFArray, locations: [0, 1])
                {
                    context.drawLinearGradient(g, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0),
                                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
            default:
                drawConicGradient(in: size, anchors: conicAnchors(for: stops, in: size))
        }
        context.restoreGState()

        context.flush()
        SLSFlushWindowContentRegion(cid, wid, nil)
    }

    /// Maps the stops to anchor angles (degrees, measured from the ring center, context y-up) around
    /// the perimeter. 4 stops land on the corners, 8 on corners + edge midpoints (clockwise from
    /// top-left); any other count is spread evenly clockwise from the top.
    private func conicAnchors(for stops: [UInt32], in size: CGSize) -> [(angle: Double, color: UInt32)] {
        func deg(_ x: Double, _ y: Double) -> Double { (atan2(y, x) * 180 / .pi).truncatingRemainder(dividingBy: 360) }
        let w = size.width / 2, h = size.height / 2
        let tl = deg(-w, h), tr = deg(w, h), br = deg(w, -h), bl = deg(-w, -h)
        let top = 90.0, right = 0.0, bottom = 270.0, left = 180.0
        let angles: [Double] = switch stops.count {
            case 4: [tl, tr, br, bl] // corners, clockwise from top-left
            case 8: [tl, top, tr, right, br, bottom, bl, left] // corners + edge midpoints
            default: (0 ..< stops.count).map { top - Double($0) * 360 / Double(stops.count) } // even, clockwise from top
        }
        return zip(angles, stops).map { ($0, $1) }
    }

    /// Fills the (already clipped) ring with a conic gradient by sweeping thin wedges from the center.
    private func drawConicGradient(in size: CGSize, anchors: [(angle: Double, color: UInt32)]) {
        guard let context, anchors.count >= 2 else { return }
        let sorted = anchors.map { (angle: (($0.angle.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360), color: $0.color) }
            .sorted { $0.angle < $1.angle }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = hypot(size.width, size.height) // overshoots the frame so wedges cover the whole ring
        let stepDeg = 2.0
        // Each wedge extends a bit past the next one's start so neighbors overlap. Without this, the
        // antialiased edges of adjacent wedges leave a thin transparent seam that reads as a dark gap.
        let overlapDeg = 1.5
        var a = 0.0
        while a < 360 {
            let mid = a + stepDeg / 2
            context.setFillColor(conicColor(atAngle: mid, sorted).cgColor)
            let a0 = a * .pi / 180, a1 = (a + stepDeg + overlapDeg) * .pi / 180
            context.beginPath()
            context.move(to: center)
            context.addLine(to: CGPoint(x: center.x + r * cos(a0), y: center.y + r * sin(a0)))
            context.addLine(to: CGPoint(x: center.x + r * cos(a1), y: center.y + r * sin(a1)))
            context.closePath()
            context.fillPath()
            a += stepDeg
        }
    }

    /// Interpolates the 0xAARRGGBB color at `angle` (degrees) between the two surrounding anchors.
    private func conicColor(atAngle angle: Double, _ sorted: [(angle: Double, color: UInt32)]) -> UInt32 {
        let a = ((angle.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        var lo = sorted[sorted.count - 1], hi = sorted[0]
        var span = hi.angle + 360 - lo.angle
        var pos = a < hi.angle ? a + 360 - lo.angle : a - lo.angle
        for i in 0 ..< sorted.count - 1 where a >= sorted[i].angle && a < sorted[i + 1].angle {
            lo = sorted[i]; hi = sorted[i + 1]
            span = hi.angle - lo.angle
            pos = a - lo.angle
        }
        let t = span > 0 ? pos / span : 0
        return lo.color.lerp(to: hi.color, t)
    }
}

extension UInt32 {
    /// Linearly interpolate each 0xAARRGGBB channel toward `other` by t in [0, 1]
    fileprivate func lerp(to other: UInt32, _ t: Double) -> UInt32 {
        func ch(_ shift: UInt32) -> UInt32 {
            let a = Double((self >> shift) & 0xFF), b = Double((other >> shift) & 0xFF)
            return UInt32((a + (b - a) * t).rounded()) << shift
        }
        return ch(24) | ch(16) | ch(8) | ch(0)
    }

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
