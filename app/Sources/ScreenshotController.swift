import AppKit
import Carbon.HIToolbox

/// A borderless window refuses key status by default, so `makeKeyAndOrderFront` and
/// `makeFirstResponder` silently do nothing and every keyboard shortcut is lost while mouse
/// clicks still work. This subclass is what makes Esc/⌘C/⌘S/arrows reach the overlay.
final class ScreenshotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Snipaste-style screenshot overlay: the screen is frozen, a region is dragged out with edges
/// snapping to window borders, and the result can be copied (⌘C) or saved (⌘S).
final class ScreenshotController: NSObject {
    static let shared = ScreenshotController()

    private var window: NSWindow?
    private var view: ScreenshotOverlayView?
    private var previousApp: NSRunningApplication?
    /// Set by `finish`, so the self-test can assert what the overlay actually did.
    private(set) var lastOutcome: String?

    private override init() { super.init() }

    var isActive: Bool { window != nil }

    func begin(preselect: NSRect? = nil) {
        guard window == nil else { return }
        guard requirePermission() else { return }

        let mouse = NSEvent.mouseLocation
        let screen = ScreenCapture.screen(containing: mouse)
        guard let image = ScreenCapture.image(of: screen) else {
            reportCaptureFailure()
            return
        }

        let overlay = ScreenshotOverlayView(screen: screen, frozen: image)
        overlay.onFinish = { [weak self] outcome in
            self?.finish(outcome)
        }
        overlay.frame = NSRect(origin: .zero, size: screen.frame.size)

        let panel = ScreenshotPanel(contentRect: screen.frame,
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false          // the old settings-window trap
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.acceptsMouseMovedEvents = true
        panel.contentView = overlay

        previousApp = NSWorkspace.shared.frontmostApplication
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(overlay)
        NSCursor.crosshair.push()
        window = panel
        view = overlay
        if let preselect = preselect { overlay.setSelection(preselect) }
        Log.write("screenshot overlay opened on \(Int(screen.frame.width))x\(Int(screen.frame.height)) "
                  + "(permitted=\(ScreenCapture.isPermitted), keyWindow=\(panel.isKeyWindow), "
                  + "firstResponder=\(String(describing: panel.firstResponder.map { type(of: $0) })))")
    }

    private func finish(_ outcome: ScreenshotOverlayView.Outcome) {
        guard let panel = window, let overlay = view else { return }
        window = nil
        view = nil
        NSCursor.pop()
        panel.orderOut(nil)
        // Merely hiding the panel left it (and its full-screen backing store) alive in AppKit's
        // window registry: five open/close cycles grew RSS by ~148 MB each. Closing it — with
        // isReleasedWhenClosed = false so nothing double-frees — and dropping the content view
        // releases the window's pixels and the frozen capture with it.
        panel.contentView = nil
        panel.close()

        switch outcome {
        case .cancelled:
            lastOutcome = "cancelled"
            Log.write("screenshot cancelled")
        case .copied(let image):
            lastOutcome = "copied \(image.width)x\(image.height)"
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([NSImage(cgImage: image, size: .zero)])
            Log.write("screenshot copied \(image.width)x\(image.height) px")
        case .saved(let image):
            save(image)
        }

        if let previous = previousApp, !previous.isTerminated {
            if #available(macOS 14.0, *) { previous.activate() }
            else { previous.activate(options: [.activateIgnoringOtherApps]) }
        }
        previousApp = nil
    }

    private func save(_ image: CGImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        panel.nameFieldStringValue = "截图 \(formatter.string(from: Date())).png"
        let folder = Config.load().screenshotSaveFolder.expandedPath
        panel.directoryURL = URL(fileURLWithPath: folder)
        panel.canCreateDirectories = true
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            Log.write("screenshot save cancelled")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: url)
            Log.write("screenshot saved to \(url.path)")
        } catch {
            Log.write("screenshot save FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - permission

    private func requirePermission() -> Bool {
        if ScreenCapture.isPermitted { return true }
        Log.write("screenshot refused: Screen Recording permission missing")
        ScreenCapture.requestPermission()
        let alert = NSAlert()
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText = """
            截图要读取屏幕内容，macOS 要求单独授予「屏幕录制」权限。

            打开 系统设置 → 隐私与安全性 → 屏幕录制，勾选 MacLauncher，然后重新按 ⌥J。
            """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        return false
    }

    private func reportCaptureFailure() {
        Log.write("screenshot capture returned nil")
        let alert = NSAlert()
        alert.messageText = "截图失败"
        alert.informativeText = "无法读取屏幕内容。请确认已在 系统设置 → 隐私与安全性 → 屏幕录制 中勾选 MacLauncher。"
        alert.runModal()
    }

    // MARK: - regression self-test

    /// Drives the overlay with synthetic key events and reports what happened. This is the
    /// test for the borderless-window bug: before `ScreenshotPanel` the window never became
    /// key, so no key event arrived and both checks failed while the mouse still worked.
    func selfTest() -> Bool {
        let pasteboard = NSPasteboard.general
        let clipboardBefore = PasteboardSnapshot.capture(pasteboard)
        var passed = true

        func pump(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }

        func key(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent? {
            guard let panel = window else { return nil }
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: panel.windowNumber, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: keyCode)
        }

        // 1) 窗口必须是 key，否则任何键盘都不可能出现
        begin(preselect: NSRect(x: 100, y: 200, width: 320, height: 220))
        pump(0.6)
        let becameKey = window?.isKeyWindow ?? false
        Log.write("screenshot selftest: keyWindow=\(becameKey)")
        if !becameKey { passed = false }

        // 2) Esc 应取消
        if let event = key("\u{1b}", keyCode: 53, flags: []) {
            NSApp.sendEvent(event)
            pump(0.4)
        }
        let escaped = (lastOutcome == "cancelled")
        Log.write("screenshot selftest: Esc -> \(lastOutcome ?? "无动作")")
        if !escaped { passed = false }

        // 3) ⌘C 应把选区图像写进剪贴板
        lastOutcome = nil
        begin(preselect: NSRect(x: 100, y: 200, width: 320, height: 220))
        pump(0.6)
        if let event = key("c", keyCode: 8, flags: .command) {
            _ = window?.contentView?.performKeyEquivalent(with: event)
            pump(0.4)
        }
        let copied = (lastOutcome?.hasPrefix("copied") ?? false)
        // The copy path writes an NSImage, which publishes TIFF (not PNG) — the first version
        // of this assertion looked for .png and reported a false failure.
        let hasImage = NSPasteboard.general.data(forType: .tiff) != nil
            || NSPasteboard.general.data(forType: .png) != nil
        Log.write("screenshot selftest: ⌘C -> \(lastOutcome ?? "无动作"), 剪贴板有图像=\(hasImage)")
        if !copied || !hasImage { passed = false }

        // 剪贴板回到测试前的内容
        _ = clipboardBefore.restore(to: pasteboard, ifUnchangedSince: pasteboard.changeCount)
        Log.write("screenshot selftest: \(passed ? "PASSED" : "FAILED")")
        return passed
    }

    /// Used by the memory profile to close the overlay without user input.
    func cancelForProfile() { finish(.cancelled) }

    // MARK: - benchmark

    /// Measures the cost of one drag step with real drawing, so the rendering optimisations
    /// have a before/after number instead of an assertion.
    func benchmark(steps: Int) {
        begin(preselect: NSRect(x: 200, y: 200, width: 400, height: 300))
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard let panel = window, let overlay = view else {
            print("benchmark: overlay did not open")
            return
        }
        let start = Date()
        let cpuStart = ProcessInfo.processInfo.systemUptime
        for step in 0..<steps {
            let offset = CGFloat(step % 40) * 4
            let point = NSPoint(x: 260 + offset, y: 260 + offset)
            if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: panel.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) {
                overlay.mouseDown(with: down)
            }
            for sub in 1...3 {
                let moving = NSPoint(x: point.x + CGFloat(sub) * 5, y: point.y + CGFloat(sub) * 3)
                if let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: moving,
                                                 modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: panel.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1) {
                    overlay.mouseDragged(with: drag)
                }
                // `panel.displayIfNeeded()` did not actually draw the view (900 draws in 0 ms),
                // so force the drawing synchronously and count that.
                overlay.display()
            }
            if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: panel.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 1) {
                overlay.mouseUp(with: up)
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        _ = cpuStart
        print(String(format: "benchmark: %d 步 / %d 次绘制，用时 %.0f ms，平均 %.2f ms/绘制",
                     steps, steps * 3, elapsed * 1000, elapsed * 1000 / Double(steps * 3)))
        Log.write(String(format: "screenshot benchmark: %.0f ms for %d draws (%.2f ms/draw)",
                         elapsed * 1000, steps * 3, elapsed * 1000 / Double(steps * 3)))
        self.finish(.cancelled)
    }

    // MARK: - review renderer

    /// Offscreen render of the overlay chrome (no frozen desktop, so a review shot does not
    /// carry the screen's content). Used by `--render-screenshot`.
    func renderToPNG(path: String, selection: NSRect, appearanceName: NSAppearance.Name) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let overlay = ScreenshotOverlayView(screen: screen, frozen: nil)
        overlay.frame = NSRect(origin: .zero, size: screen.frame.size)
        overlay.appearance = NSAppearance(named: appearanceName)
        overlay.setSelection(selection)
        overlay.display()
        overlay.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(overlay.bounds.width * scale),
                                         pixelsHigh: Int(overlay.bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = overlay.bounds.size
        overlay.cacheDisplay(in: overlay.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        Log.write("rendered screenshot overlay to \(path)")
    }
}
