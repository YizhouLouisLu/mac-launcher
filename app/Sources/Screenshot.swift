import AppKit
import CoreGraphics

/// Screen capture for the Snipaste-style overlay.
///
/// `CGWindowListCreateImage` is deprecated since macOS 14 but still functional — measured on
/// this machine (macOS 26): a 400×240 region came back with real content, only 2% dark pixels.
/// It is isolated here so a future switch to ScreenCaptureKit touches one function.
enum ScreenCapture {
    static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Full-resolution image of one screen, in global display coordinates (origin at the top
    /// left of the main display, which is what the CG APIs use).
    static func image(of screen: NSScreen) -> CGImage? {
        let rect = ScreenGeometry.cgRect(fromAppKit: screen.frame)
        return CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
    }

    static func image(of rect: CGRect) -> CGImage? {
        CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
    }

    /// The screen a point (AppKit coordinates) falls on; the main screen otherwise.
    static func screen(containing point: NSPoint) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

/// Conversions between AppKit (bottom-left origin) and the CG window APIs (top-left origin).
/// Getting this backwards mirrors the capture, so it lives in one place.
enum ScreenGeometry {
    static var mainDisplayMaxY: CGFloat {
        // The screen with the menu bar owns the origin of the CG coordinate space.
        (NSScreen.screens.first ?? NSScreen.main)?.frame.maxY ?? 0
    }

    static func cgRect(fromAppKit rect: NSRect) -> CGRect {
        CGRect(x: rect.minX,
               y: mainDisplayMaxY - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    static func appKitRect(fromCG rect: CGRect) -> NSRect {
        NSRect(x: rect.minX,
               y: mainDisplayMaxY - rect.maxY,
               width: rect.width,
               height: rect.height)
    }
}

/// Lines the selection can snap to, expressed in the overlay's own coordinate space.
struct SnapTargets {
    var verticals: [CGFloat] = []
    var horizontals: [CGFloat] = []

    /// Screen edges and centre plus, when allowed, the edges and centres of every ordinary
    /// on-screen window. Window titles are only visible with Screen Recording permission,
    /// which the caller checks before asking for them.
    static func forScreen(_ screen: NSScreen, includeWindows: Bool = true) -> SnapTargets {
        var targets = SnapTargets()
        let bounds = NSRect(origin: .zero, size: screen.frame.size)
        targets.verticals = [bounds.minX, bounds.midX, bounds.maxX]
        targets.horizontals = [bounds.minY, bounds.midY, bounds.maxY]
        guard includeWindows else { return targets }

        let screenCG = ScreenGeometry.cgRect(fromAppKit: screen.frame)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                             kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let raw = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let cgBounds = CGRect(dictionaryRepresentation: raw as CFDictionary)
            else { continue }
            guard cgBounds.width >= 60, cgBounds.height >= 40 else { continue }
            // Only windows that actually intersect this screen.
            guard cgBounds.intersects(screenCG) else { continue }
            // CG global coordinates -> local overlay coordinates.
            let local = NSRect(x: cgBounds.minX - screenCG.minX,
                               y: cgBounds.minY - screenCG.minY,
                               width: cgBounds.width,
                               height: cgBounds.height)
            targets.verticals.append(contentsOf: [local.minX, local.midX, local.maxX])
            targets.horizontals.append(contentsOf: [local.minY, local.midY, local.maxY])
        }
        return targets
    }
}

/// Pure snapping arithmetic, kept free of AppKit so it can be tested from the command line.
enum SnapEngine {
    struct Result {
        var rect: NSRect
        var verticalGuide: CGFloat?
        var horizontalGuide: CGFloat?
    }

    /// Moves a rectangle so that its nearest edge lands on a target within `threshold`, and
    /// reports the guide lines that matched so the overlay can draw them.
    static func snap(_ rect: NSRect, targets: SnapTargets, threshold: CGFloat = 8,
                     stickyVertical: CGFloat? = nil, stickyHorizontal: CGFloat? = nil) -> Result {
        var result = Result(rect: rect, verticalGuide: nil, horizontalGuide: nil)
        // Hysteresis: a guide already in effect keeps the box until the pointer leaves a wider
        // band, otherwise the snap flips between the two nearest lines and the box shakes.
        if let sticky = stickyVertical, abs(rect.minX - sticky) <= threshold * 2
            || abs(rect.maxX - sticky) <= threshold * 2 {
            result.rect.origin.x += sticky - (abs(rect.minX - sticky) <= abs(rect.maxX - sticky) ? rect.minX : rect.maxX)
            result.verticalGuide = sticky
            return finishHorizontal(result, rect: result.rect, targets: targets,
                                    threshold: threshold, sticky: stickyHorizontal)
        }

        // Horizontal movement: match the closest of left/right/centre.
        let verticalCandidates: [(edge: CGFloat, target: CGFloat, delta: CGFloat)] =
            targets.verticals.flatMap { target in
                [rect.minX, rect.midX, rect.maxX].map { edge in (edge, target, target - edge) }
            }
        if let best = verticalCandidates.filter({ abs($0.delta) <= threshold })
            .min(by: { abs($0.delta) < abs($1.delta) }) {
            result.rect.origin.x += best.delta
            result.verticalGuide = best.target
        }

        return finishHorizontal(result, rect: result.rect, targets: targets,
                                threshold: threshold, sticky: stickyHorizontal)
    }

    private static func finishHorizontal(_ result: Result, rect: NSRect, targets: SnapTargets,
                                         threshold: CGFloat, sticky: CGFloat?) -> Result {
        var result = result
        let rect = rect
        if let sticky = sticky, abs(rect.minY - sticky) <= threshold * 2 || abs(rect.maxY - sticky) <= threshold * 2 {
            result.rect.origin.y += sticky - (abs(rect.minY - sticky) <= abs(rect.maxY - sticky) ? rect.minY : rect.maxY)
            result.horizontalGuide = sticky
            return result
        }
        let horizontalCandidates: [(edge: CGFloat, target: CGFloat, delta: CGFloat)] =
            targets.horizontals.flatMap { target in
                [rect.minY, rect.midY, rect.maxY].map { edge in (edge, target, target - edge) }
            }
        if let best = horizontalCandidates.filter({ abs($0.delta) <= threshold })
            .min(by: { abs($0.delta) < abs($1.delta) }) {
            result.rect.origin.y += best.delta
            result.horizontalGuide = best.target
        }

        return result
    }

    /// Snaps a single point — the free corner while drawing a fresh selection — to the nearest
    /// line on each axis independently. Snapping a whole rect instead moved the anchored corner
    /// too, and two nearby lines could take turns winning, which is what made the first drag
    /// jitter.
    static func snapPoint(_ point: NSPoint, targets: SnapTargets, threshold: CGFloat = 8,
                          stickyVertical: CGFloat? = nil, stickyHorizontal: CGFloat? = nil)
        -> (point: NSPoint, verticalGuide: CGFloat?, horizontalGuide: CGFloat?) {
        var result = point
        var vertical = stickyVertical.flatMap { sticky in
            abs(point.x - sticky) <= threshold * 2 ? sticky : nil
        }
        if vertical == nil {
            vertical = targets.verticals.filter { abs($0 - point.x) <= threshold }
                .min(by: { abs($0 - point.x) < abs($1 - point.x) })
        }
        var horizontal = stickyHorizontal.flatMap { sticky in
            abs(point.y - sticky) <= threshold * 2 ? sticky : nil
        }
        if horizontal == nil {
            horizontal = targets.horizontals.filter { abs($0 - point.y) <= threshold }
                .min(by: { abs($0 - point.y) < abs($1 - point.y) })
        }
        if let vertical = vertical { result.x = vertical }
        if let horizontal = horizontal { result.y = horizontal }
        return (result, vertical, horizontal)
    }

    /// Snapping for a rectangle being resized: only the edge under the pointer moves, so only
    /// that edge is matched (both edges would otherwise fight each other).
    static func snapResizing(_ rect: NSRect, handle: SelectionHandle,
                            targets: SnapTargets, threshold: CGFloat = 8,
                            stickyVertical: CGFloat? = nil, stickyHorizontal: CGFloat? = nil) -> Result {
        var result = Result(rect: rect, verticalGuide: nil, horizontalGuide: nil)
        if let sticky = stickyVertical, abs(rect.minX - sticky) <= threshold * 2 || abs(rect.maxX - sticky) <= threshold * 2 {
            let edge = handle.movesLeftEdge ? rect.minX : rect.maxX
            if abs(edge - sticky) <= threshold * 2 {
                if handle.movesLeftEdge {
                    result.rect.origin.x = sticky
                    result.rect.size.width = rect.maxX - sticky
                } else if handle.movesRightEdge {
                    result.rect.size.width = sticky - rect.minX
                }
                result.verticalGuide = sticky
            }
        }
        if let sticky = stickyHorizontal, abs(rect.minY - sticky) <= threshold * 2 || abs(rect.maxY - sticky) <= threshold * 2 {
            let edge = handle.movesTopEdge ? rect.maxY : rect.minY
            if abs(edge - sticky) <= threshold * 2 {
                if handle.movesBottomEdge {
                    result.rect.origin.y = sticky
                    result.rect.size.height = rect.maxY - sticky
                } else if handle.movesTopEdge {
                    result.rect.size.height = sticky - rect.minY
                }
                result.horizontalGuide = sticky
            }
        }
        if result.verticalGuide != nil || result.horizontalGuide != nil { return result }

        if handle.movesLeftEdge || handle.movesRightEdge {
            let edge = handle.movesLeftEdge ? rect.minX : rect.maxX
            if let target = targets.verticals
                .filter({ abs($0 - edge) <= threshold })
                .min(by: { abs($0 - edge) < abs($1 - edge) }) {
                if handle.movesLeftEdge {
                    result.rect.origin.x = target
                    result.rect.size.width = rect.maxX - target
                } else {
                    result.rect.size.width = target - rect.minX
                }
                result.verticalGuide = target
            }
        }
        if handle.movesTopEdge || handle.movesBottomEdge {
            let edge = handle.movesTopEdge ? rect.maxY : rect.minY
            if let target = targets.horizontals
                .filter({ abs($0 - edge) <= threshold })
                .min(by: { abs($0 - edge) < abs($1 - edge) }) {
                if handle.movesBottomEdge {
                    result.rect.origin.y = target
                    result.rect.size.height = rect.maxY - target
                } else {
                    result.rect.size.height = target - rect.minY
                }
                result.horizontalGuide = target
            }
        }
        return result
    }
}

/// Which part of the selection a drag is manipulating.
enum SelectionHandle: Equatable {
    case none
    case move
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeftEdge: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRightEdge: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTopEdge: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottomEdge: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    static func at(point: NSPoint, in rect: NSRect, tolerance: CGFloat = 6) -> SelectionHandle {
        let nearLeft = abs(point.x - rect.minX) <= tolerance
        let nearRight = abs(point.x - rect.maxX) <= tolerance
        let nearBottom = abs(point.y - rect.minY) <= tolerance
        let nearTop = abs(point.y - rect.maxY) <= tolerance
        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return rect.contains(point) ? .move : .none
        }
    }
}
