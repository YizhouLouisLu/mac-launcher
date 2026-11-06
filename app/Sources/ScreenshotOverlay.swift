import AppKit

/// The overlay: a frozen screen, a draggable region whose edges snap to window borders, guide
/// lines, a size readout and a small toolbar. Coordinates are AppKit's (y grows upward).
final class ScreenshotOverlayView: NSView {
    enum Outcome {
        case cancelled
        case copied(CGImage)
        case saved(CGImage)
    }

    var onFinish: ((Outcome) -> Void)?

    private let frozen: CGImage?
    private let screen: NSScreen
    private let targets: SnapTargets
    private var selection: NSRect = .zero
    private var dragOrigin: NSPoint = .zero
    private var dragStartSelection: NSRect = .zero
    private var handle: SelectionHandle = .none
    /// True while dragging out a brand-new selection: then only the free corner snaps.
    private var isFreshDrag = false
    private var stickyVertical: CGFloat?
    private var stickyHorizontal: CGFloat?
    private var verticalGuide: CGFloat?
    private var horizontalGuide: CGFloat?
    private var cursor: NSPoint = .zero
    private var buttons: [(title: String, action: Outcome)] = []
    private var buttonRects: [NSRect] = []

    init(screen: NSScreen, frozen: CGImage?) {
        self.screen = screen
        self.frozen = frozen
        self.targets = SnapTargets.forScreen(screen, includeWindows: frozen != nil)
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Exposed for the command-line drag regression test.
    var debugSelection: NSRect { selection }

    func setSelection(_ rect: NSRect) {
        selection = rect
        needsDisplay = true
    }

    private var pixelScale: CGFloat {
        guard let frozen = frozen, bounds.width > 0 else { return screen.backingScaleFactor }
        return CGFloat(frozen.width) / bounds.width
    }

    // MARK: - drawing

    override func draw(_ dirtyRect: NSRect) {
        if let frozen = frozen {
            NSImage(cgImage: frozen, size: bounds.size).draw(in: bounds)
            NSColor.black.withAlphaComponent(0.45).setFill()
            bounds.fill()
        } else {
            NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
            bounds.fill()
        }

        if selection.width >= 1, selection.height >= 1 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            if let frozen = frozen {
                NSImage(cgImage: frozen, size: bounds.size).draw(in: bounds)
            } else {
                NSColor.controlBackgroundColor.setFill()
                selection.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            drawGuides()
            drawSelectionChrome()
        }
        drawReadout()
        drawToolbar()
        drawCrosshair()
    }

    private func drawGuides() {
        guard verticalGuide != nil || horizontalGuide != nil else { return }
        let path = NSBezierPath()
        path.setLineDash([4, 4], count: 2, phase: 0)
        path.lineWidth = 1
        if let x = verticalGuide {
            path.move(to: NSPoint(x: x, y: bounds.minY))
            path.line(to: NSPoint(x: x, y: bounds.maxY))
        }
        if let y = horizontalGuide {
            path.move(to: NSPoint(x: bounds.minX, y: y))
            path.line(to: NSPoint(x: bounds.maxX, y: y))
        }
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }

    private func drawSelectionChrome() {
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: selection)
        border.lineWidth = 1.5
        border.stroke()

        // Rule-of-thirds hints, faint, like Snipaste's grid.
        NSColor.controlAccentColor.withAlphaComponent(0.25).setStroke()
        let thirds = NSBezierPath()
        thirds.lineWidth = 0.5
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
            thirds.move(to: NSPoint(x: selection.minX + selection.width * fraction, y: selection.minY))
            thirds.line(to: NSPoint(x: selection.minX + selection.width * fraction, y: selection.maxY))
            thirds.move(to: NSPoint(x: selection.minX, y: selection.minY + selection.height * fraction))
            thirds.line(to: NSPoint(x: selection.maxX, y: selection.minY + selection.height * fraction))
        }
        thirds.stroke()

        let size: CGFloat = 7
        NSColor.white.setFill()
        NSColor.controlAccentColor.setStroke()
        for center in handleCenters() {
            let rect = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            path.fill()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func handleCenters() -> [NSPoint] {
        [NSPoint(x: selection.minX, y: selection.minY),
         NSPoint(x: selection.midX, y: selection.minY),
         NSPoint(x: selection.maxX, y: selection.minY),
         NSPoint(x: selection.maxX, y: selection.midY),
         NSPoint(x: selection.maxX, y: selection.maxY),
         NSPoint(x: selection.midX, y: selection.maxY),
         NSPoint(x: selection.minX, y: selection.maxY),
         NSPoint(x: selection.minX, y: selection.midY)]
    }

    private func drawReadout() {
        let scale = pixelScale
        let text: String
        if selection.width >= 1, selection.height >= 1 {
            text = "\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded())) px"
                + "   (\(Int(selection.width)) × \(Int(selection.height)) pt)"
        } else {
            text = "拖动选择区域 · 边缘自动吸附窗口 · Esc 取消"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        // Above the selection by default; when there is no room up there, sit just above the
        // toolbar. The first render put both below the selection and they overlapped.
        let toolbarHeight: CGFloat = 30
        let toolbarY = max(bounds.minY + 10, selection.minY - toolbarHeight - 14)
        var origin = NSPoint(x: selection.minX, y: selection.maxY + 10)
        if origin.y + size.height + 8 > bounds.maxY {
            origin.y = min(selection.minY - size.height - 8, toolbarY - size.height - 8)
        }
        origin.x = min(max(bounds.minX + 8, origin.x), bounds.maxX - size.width - 16)
        let box = NSRect(x: origin.x - 8, y: origin.y - 5, width: size.width + 16, height: size.height + 10)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    private func drawToolbar() {
        let scale = pixelScale
        buttons = []
        let entries: [(String, Outcome)] = [
            ("复制 ⌘C", .copied(croppedImage() ?? placeholderImage())),
            ("保存 ⌘S", .saved(croppedImage() ?? placeholderImage())),
            ("取消 Esc", .cancelled)
        ]
        buttons = entries
        buttonRects = []

        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        var totalWidth: CGFloat = 0
        let sizes = entries.map { entry -> NSSize in
            let size = (entry.0 as NSString).size(withAttributes: [.font: font])
            totalWidth += size.width + 26
            return size
        }
        totalWidth += CGFloat(max(0, entries.count - 1)) * 8

        var x = selection.width >= 1
            ? min(selection.minX, bounds.maxX - totalWidth - 12)
            : (bounds.midX - totalWidth / 2)
        x = max(bounds.minX + 12, x)
        let y: CGFloat = selection.height >= 1
            ? max(bounds.minY + 14, selection.minY - 44)
            : bounds.midY + 40

        for (index, entry) in entries.enumerated() {
            let width = sizes[index].width + 26
            let rect = NSRect(x: x, y: y, width: width, height: 30)
            buttonRects.append(rect)
            NSColor.black.withAlphaComponent(0.7).setFill()
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            path.fill()
            NSColor.white.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 1
            path.stroke()
            let textOrigin = NSPoint(x: rect.minX + 13, y: rect.midY - sizes[index].height / 2)
            (entry.0 as NSString).draw(at: textOrigin, withAttributes: [
                .font: font, .foregroundColor: NSColor.white
            ])
            x += width + 8
        }
        _ = scale
    }

    private func drawCrosshair() {
        guard cursor != .zero, selection.width < 1 else { return }
        NSColor.white.withAlphaComponent(0.7).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 0.5
        path.move(to: NSPoint(x: bounds.minX, y: cursor.y))
        path.line(to: NSPoint(x: bounds.maxX, y: cursor.y))
        path.move(to: NSPoint(x: cursor.x, y: bounds.minY))
        path.line(to: NSPoint(x: cursor.x, y: bounds.maxY))
        path.stroke()
    }

    private func placeholderImage() -> CGImage {
        // Only used when the clipboard/export has nothing to work with (never in practice).
        frozen ?? NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!.cgImage!
    }

    // MARK: - crop

    func croppedImage() -> CGImage? {
        guard let frozen = frozen, selection.width >= 1, selection.height >= 1 else { return nil }
        let scaleX = CGFloat(frozen.width) / bounds.width
        let scaleY = CGFloat(frozen.height) / bounds.height
        // CGImage origin is top-left, the view's is bottom-left.
        let pixelRect = CGRect(x: selection.minX * scaleX,
                               y: (bounds.height - selection.maxY) * scaleY,
                               width: selection.width * scaleX,
                               height: selection.height * scaleY)
        return frozen.cropping(to: pixelRect.integral)
    }

    // MARK: - mouse

    override func mouseDown(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)

        for (index, rect) in buttonRects.enumerated() where rect.contains(cursor) {
            guard index < buttons.count else { continue }
            onFinish?(buttons[index].action)
            return
        }

        handle = SelectionHandle.at(point: cursor, in: selection)
        // The grab point must be recorded on *every* mouse down. It used to be set only when
        // starting a fresh selection, so grabbing inside an existing one reused the previous
        // drag's origin and the box teleported to the cursor (reported by the user).
        dragOrigin = cursor
        isFreshDrag = false
        if handle == .none {
            selection = NSRect(origin: cursor, size: .zero)
            handle = .bottomLeft   // dragging out a fresh box moves its lower-left corner
            isFreshDrag = true
        }
        stickyVertical = nil
        stickyHorizontal = nil
        dragStartSelection = selection
        updateCursor()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        var rect = dragStartSelection

        switch handle {
        case .none, .move:
            let delta = NSPoint(x: cursor.x - dragOrigin.x, y: cursor.y - dragOrigin.y)
            let candidate = NSRect(x: dragStartSelection.minX + delta.x,
                                   y: dragStartSelection.minY + delta.y,
                                   width: dragStartSelection.width,
                                   height: dragStartSelection.height)
            let snapped = SnapEngine.snap(candidate, targets: targets,
                                          stickyVertical: stickyVertical,
                                          stickyHorizontal: stickyHorizontal)
            rect = snapped.rect
            verticalGuide = snapped.verticalGuide
            horizontalGuide = snapped.horizontalGuide
            stickyVertical = snapped.verticalGuide
            stickyHorizontal = snapped.horizontalGuide
        case .bottomLeft:
            if isFreshDrag {
                // Snap the free corner only; the anchor corner must not move, otherwise the
                // box twitches as the cursor moves by a pixel.
                let snapped = SnapEngine.snapPoint(cursor, targets: targets,
                                                   stickyVertical: stickyVertical,
                                                   stickyHorizontal: stickyHorizontal)
                stickyVertical = snapped.verticalGuide
                stickyHorizontal = snapped.horizontalGuide
                let corner = snapped.point
                rect = NSRect(x: min(corner.x, dragOrigin.x), y: min(corner.y, dragOrigin.y),
                              width: abs(corner.x - dragOrigin.x), height: abs(corner.y - dragOrigin.y))
                verticalGuide = snapped.verticalGuide
                horizontalGuide = snapped.horizontalGuide
            } else {
                let x = min(cursor.x, dragOrigin.x), y = min(cursor.y, dragOrigin.y)
                rect = NSRect(x: x, y: y,
                              width: abs(cursor.x - dragOrigin.x), height: abs(cursor.y - dragOrigin.y))
                let snapped = SnapEngine.snap(rect, targets: targets,
                                              stickyVertical: stickyVertical,
                                              stickyHorizontal: stickyHorizontal)
                rect = snapped.rect
                verticalGuide = snapped.verticalGuide
                horizontalGuide = snapped.horizontalGuide
            }
        default:
            switch handle {
            case .left: rect.size.width = max(1, dragStartSelection.maxX - cursor.x); rect.origin.x = cursor.x
            case .right: rect.size.width = max(1, cursor.x - dragStartSelection.minX)
            case .bottom: rect.size.height = max(1, dragStartSelection.maxY - cursor.y); rect.origin.y = cursor.y
            case .top: rect.size.height = max(1, cursor.y - dragStartSelection.minY)
            case .topLeft:
                rect.size.width = max(1, dragStartSelection.maxX - cursor.x); rect.origin.x = cursor.x
                rect.size.height = max(1, cursor.y - dragStartSelection.minY)
            case .topRight:
                rect.size.width = max(1, cursor.x - dragStartSelection.minX)
                rect.size.height = max(1, cursor.y - dragStartSelection.minY)
            case .bottomLeft:
                rect.size.width = max(1, dragStartSelection.maxX - cursor.x); rect.origin.x = cursor.x
                rect.size.height = max(1, dragStartSelection.maxY - cursor.y); rect.origin.y = cursor.y
            case .bottomRight:
                rect.size.width = max(1, cursor.x - dragStartSelection.minX)
                rect.size.height = max(1, dragStartSelection.maxY - cursor.y); rect.origin.y = cursor.y
            default: break
            }
            let snapped = SnapEngine.snapResizing(rect, handle: handle, targets: targets,
                                                  stickyVertical: stickyVertical,
                                                  stickyHorizontal: stickyHorizontal)
            rect = snapped.rect
            verticalGuide = snapped.verticalGuide
            horizontalGuide = snapped.horizontalGuide
            stickyVertical = snapped.verticalGuide
            stickyHorizontal = snapped.horizontalGuide
        }

        selection = clamped(rect)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        verticalGuide = nil
        horizontalGuide = nil
        stickyVertical = nil
        stickyHorizontal = nil
        isFreshDrag = false
        if selection.width < 4 || selection.height < 4 {
            selection = .zero
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        updateCursor()
        needsDisplay = true
    }

    /// Cursor feedback, as Snipaste does it: crosshair outside, open hand inside, resize
    /// arrows on the edges.
    private func updateCursor() {
        switch SelectionHandle.at(point: cursor, in: selection) {
        case .move: NSCursor.openHand.set()
        case .left, .right: NSCursor.resizeLeftRight.set()
        case .top, .bottom: NSCursor.resizeUpDown.set()
        case .topLeft, .bottomRight: NSCursor.crosshair.set()
        case .topRight, .bottomLeft: NSCursor.crosshair.set()
        case .none: NSCursor.crosshair.set()
        }
    }

    private func clamped(_ rect: NSRect) -> NSRect {
        var result = rect
        result.origin.x = max(bounds.minX, min(result.origin.x, bounds.maxX - 1))
        result.origin.y = max(bounds.minY, min(result.origin.y, bounds.maxY - 1))
        result.size.width = min(result.width, bounds.maxX - result.origin.x)
        result.size.height = min(result.height, bounds.maxY - result.origin.y)
        return result
    }

    // MARK: - keyboard

    override func keyDown(with event: NSEvent) {
        // 53 = Esc, 123/124/125/126 = arrows.
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let resizing = event.modifierFlags.contains(.option)
        switch Int(event.keyCode) {
        case 53:
            onFinish?(.cancelled)
        case 36, 76:                                    // Return / keypad Enter
            copyOrFinish()
        case 123, 124, 125, 126:
            guard selection.width >= 1 else { return }
            var rect = selection
            let vertical: CGFloat = Int(event.keyCode) == 126 ? step : (Int(event.keyCode) == 125 ? -step : 0)
            let horizontal: CGFloat = Int(event.keyCode) == 124 ? step : (Int(event.keyCode) == 123 ? -step : 0)
            if resizing {
                rect.size.width = max(4, rect.width + horizontal)
                rect.size.height = max(4, rect.height + vertical)
            } else {
                rect.origin.x += horizontal
                rect.origin.y += vertical
            }
            selection = clamped(rect)
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let character = event.charactersIgnoringModifiers?.lowercased()
        if event.modifierFlags.contains(.command), character == "c" {
            copyOrFinish()
            return true
        }
        if event.modifierFlags.contains(.command), character == "s" {
            guard let image = croppedImage() else { return true }
            onFinish?(.saved(image))
            return true
        }
        if event.keyCode == 53 {
            onFinish?(.cancelled)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func copyOrFinish() {
        guard let image = croppedImage() else {
            Log.write("screenshot copy ignored: selection too small")
            return
        }
        onFinish?(.copied(image))
    }
}
