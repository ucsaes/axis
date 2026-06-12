import AppKit
import Common
import PrivateApi

/// A single window-server (SkyLight) window used to draw one window's border.
/// Lives entirely at the SLS level — no NSWindow — so it can be repositioned in the same
/// coordinate space the window server reports the target window, avoiding the lag of
/// AX-driven overlays. Sources the target frame from SLSGetWindowBounds, so no AppKit
/// coordinate flipping is involved.
@MainActor
final class BorderWindow {
    let wid: UInt32
    private let cid: Int32
    private var context: CGContext?
    private var windowSize: CGSize = .zero

    /// SLS window tags. (1 << 1): no shadow. (1 << 9): keep the overlay out of normal window
    /// management. 0x40 is the tag bit width SLS expects.
    private static let setTags: UInt64 = (1 << 1) | (1 << 9)
    private static let tagSize: Int32 = 0x40

    init?(cid: Int32) {
        self.cid = cid
        guard let region = Self.region(CGRect(x: 0, y: 0, width: 1, height: 1)) else { return nil }
        var wid: UInt32 = 0
        // type 2: a plain buffered window, the kind used for overlays
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

    /// Draw the border wrapping `targetWid` just beneath it in the z-order. Returns false if the
    /// target's bounds can't be read (window gone). Coordinates stay entirely in SLS space.
    @discardableResult
    func update(around targetWid: UInt32, color: BorderColor, width: CGFloat, cornerRadius: CGFloat) -> Bool {
        var targetBounds = CGRect.zero
        guard SLSGetWindowBounds(cid, targetWid, &targetBounds) == .success, !targetBounds.isEmpty else {
            return false
        }
        // The border window spans the target plus half the stroke on each side
        let outset = width / 2
        let windowFrame = targetBounds.insetBy(dx: -outset, dy: -outset)

        if windowFrame.size != windowSize, let region = Self.region(CGRect(origin: .zero, size: windowFrame.size)) {
            SLSDisableUpdate(cid)
            SLSSetWindowShape(cid, wid, Float(windowFrame.origin.x), Float(windowFrame.origin.y), region)
            context = SLWindowContextCreate(cid, wid, nil)?.takeRetainedValue()
            context?.interpolationQuality = .none
            SLSReenableUpdate(cid)
        }
        windowSize = windowFrame.size
        draw(size: windowFrame.size, color: color, width: width, cornerRadius: cornerRadius)

        var origin = windowFrame.origin
        SLSMoveWindow(cid, wid, &origin)
        SLSSetWindowLevel(cid, wid, windowLevel(of: targetWid))
        // Order just below the focused window so the visible border hugs its edge
        SLSOrderWindow(cid, wid, 1, targetWid)
        return true
    }

    func hide() {
        SLSOrderWindow(cid, wid, 0, 0)
    }

    private func windowLevel(of targetWid: UInt32) -> Int32 {
        var level: Int32 = 0
        SLSGetWindowLevel(cid, targetWid, &level)
        return level
    }

    private func draw(size: CGSize, color: BorderColor, width: CGFloat, cornerRadius: CGFloat) {
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
