import AppKit
import ApplicationServices
import Carbon.HIToolbox

// =============================================================================
// LaunchSpike — verifies the three assumptions the launcher design rests on:
//   A1. NSPanel with .nonactivatingPanel can take keyboard focus while the
//       previously frontmost app keeps its state (no activation steal).
//   A2. CGEvent Cmd+V lands in the restored frontmost app (snippet injection).
//   A3. Option+Space can be registered as a global hotkey by this process.
//
// Everything is written to a log file so the app can be launched via `open`
// (launchd as parent), which is required for TCC to attribute the
// Accessibility grant to this app rather than to the terminal.
// =============================================================================

// MARK: - Logging

private let logDirectory = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/LaunchSpike", isDirectory: true)
private let logFileURL = logDirectory.appendingPathComponent("spike.log")
private let isoFormatter = ISO8601DateFormatter()

func spikeLog(_ message: String) {
    let line = "[\(isoFormatter.string(from: Date()))] \(message)\n"
    try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: logFileURL) {
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) { handle.write(data) }
        try? handle.close()
    } else if let data = line.data(using: .utf8) {
        try? data.write(to: logFileURL)
    }
    FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
}

func describeFrontmost() -> String {
    guard let app = NSWorkspace.shared.frontmostApplication else { return "nil" }
    return "\(app.localizedName ?? "?") [\(app.bundleIdentifier ?? "?")] pid=\(app.processIdentifier)"
}

func describe(_ app: NSRunningApplication?) -> String {
    guard let app = app else { return "nil" }
    return "\(app.localizedName ?? "?") [\(app.bundleIdentifier ?? "?")] pid=\(app.processIdentifier)"
}

// MARK: - Carbon hotkey callback (must be a capture-free global function)

private func hotKeyHandler(_ callRef: EventHandlerCallRef?,
                          _ event: EventRef?,
                          _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event = event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let err = GetEventParameter(event,
                               EventParamName(kEventParamDirectObject),
                               EventParamType(typeEventHotKeyID),
                               nil,
                               MemoryLayout<EventHotKeyID>.size,
                               nil,
                               &hotKeyID)
    if err != noErr {
        spikeLog("hotkey fired but GetEventParameter failed err=\(err)")
        return noErr
    }
    spikeLog(">>> hotkey fired id=\(hotKeyID.id)")
    (NSApp.delegate as? AppDelegate)?.handleHotKey(id: hotKeyID.id)
    return noErr
}

// MARK: - Custom panel / field

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SpikeField: NSTextField {
    var onEscape: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: KeyPanel!
    private var field: SpikeField!
    private var statusItem: NSStatusItem?
    private var previousApp: NSRunningApplication?
    private var hotKeyRefs: [EventHotKeyRef?] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        spikeLog("=================== LAUNCH ===================")
        spikeLog("bundleID=\(Bundle.main.bundleIdentifier ?? "nil")")
        spikeLog("executable=\(Bundle.main.executablePath ?? "?")")
        spikeLog("macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        spikeLog("AXIsProcessTrusted=\(AXIsProcessTrusted())")
        spikeLog("activationPolicy=\(NSApp.activationPolicy().rawValue) (0=regular,1=accessory,2=prohibited)")
        spikeLog("frontmost at launch=\(describeFrontmost())")

        buildPanel()
        installStatusItem()
        registerHotKeys()
        requestAccessibilityIfNeeded()

        spikeLog("READY. Test A3 (hotkey): press Option+Space.")
        spikeLog("READY. Test A1/A2 (panel + injection): focus TextEdit, press the hotkey, type, press Enter.")
    }

    // MARK: accessibility

    private func requestAccessibilityIfNeeded() {
        if AXIsProcessTrusted() {
            spikeLog("accessibility: ALREADY TRUSTED")
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trustedNow = AXIsProcessTrustedWithOptions(options)
        spikeLog("accessibility: prompt requested, trustedNow=\(trustedNow)")
    }

    // MARK: panel

    private func buildPanel() {
        let size = NSSize(width: 640, height: 64)
        panel = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.nonactivatingPanel, .borderless],
                         backing: .buffered,
                         defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .windowBackgroundColor
        panel.isOpaque = true
        panel.hasShadow = true
        panel.isMovable = false

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        field = SpikeField(frame: NSRect(x: 18, y: 20, width: size.width - 36, height: 24))
        field.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        field.font = .systemFont(ofSize: 18)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "spike: type, Enter = inject snippet, Esc = cancel"
        field.target = self
        field.action = #selector(performPaste)
        field.onEscape = { [weak self] in
            spikeLog("escape pressed -> hide")
            self?.hidePanel()
        }
        container.addSubview(field)
        panel.contentView = container

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                        y: visible.maxY - size.height - 140))
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "SPIKE"
        let menu = NSMenu()
        let showItem = NSMenuItem(title: "Show panel", action: #selector(menuShow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    @objc private func menuShow() {
        showPanel(activating: false)
    }

    func handleHotKey(id: UInt32) {
        switch id {
        case 1: showPanel(activating: false) // ideal path
        case 2: showPanel(activating: true)  // guaranteed-focus fallback
        default: spikeLog("unknown hotkey id=\(id)")
        }
    }

    func showPanel(activating: Bool) {
        let current = NSWorkspace.shared.frontmostApplication
        if let current = current, current.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = current
        }
        spikeLog("showPanel activating=\(activating) previousApp=\(describe(previousApp))")
        field.stringValue = ""
        if activating {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        spikeLog("  +0ms: NSApp.isActive=\(NSApp.isActive) panel.isKeyWindow=\(panel.isKeyWindow) frontmost=\(describeFrontmost())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            spikeLog("  +150ms: NSApp.isActive=\(NSApp.isActive) panel.isKeyWindow=\(self.panel.isKeyWindow) frontmost=\(describeFrontmost())")
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
        spikeLog("hidden: frontmost=\(describeFrontmost())")
    }

    // MARK: injection

    @objc func performPaste() {
        let text = "LaunchSpike-OK \(isoFormatter.string(from: Date()))"
        spikeLog("action Enter: text=\"\(text)\" typed=\"\(field.stringValue)\"")
        spikeLog("  pre-hide: frontmost=\(describeFrontmost()) AXtrusted=\(AXIsProcessTrusted())")

        let pasteboard = NSPasteboard.general
        let savedClipboard = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let target = previousApp
        panel.orderOut(nil)
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }

        if let target = target, !target.isTerminated {
            let ok = target.activate(options: [.activateIgnoringOtherApps])
            spikeLog("  activate target \(describe(target)) ok=\(ok)")
        } else {
            spikeLog("  WARNING: no valid target app recorded; injecting into whatever is frontmost")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            spikeLog("  +400ms: frontmost=\(describeFrontmost())")
            let posted = self.postCommandV()
            spikeLog("  posted Cmd+V viaHID=\(posted)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                pasteboard.clearContents()
                if let saved = savedClipboard {
                    pasteboard.setString(saved, forType: .string)
                    spikeLog("  clipboard restored")
                } else {
                    spikeLog("  clipboard cleared (no previous content)")
                }
            }
        }
    }

    private func postCommandV() -> Bool {
        guard AXIsProcessTrusted() else {
            spikeLog("  postCommandV: REFUSED, process is not AX-trusted")
            return false
        }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else {
            spikeLog("  postCommandV: CGEvent creation failed")
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: hotkey registration (A3)

    private func registerHotKeys() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(),
                                               hotKeyHandler,
                                               1,
                                               &eventType,
                                               nil,
                                               nil)
        spikeLog("InstallEventHandler status=\(installStatus)")

        registerHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), id: 1, label: "Option+Space")
        registerHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | controlKey), id: 2, label: "Control+Option+Space")
    }

    private func registerHotKey(keyCode: UInt32, modifiers: UInt32, id: UInt32, label: String) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C53504B), id: id) // 'LSPK'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        hotKeyRefs.append(ref)
        let meaning: String
        switch status {
        case noErr:
            meaning = "OK"
        case OSStatus(eventHotKeyExistsErr):
            meaning = "FAILED — key already registered by another process (hotkey conflict)"
        default:
            meaning = "FAILED rawStatus=\(status)"
        }
        spikeLog("RegisterEventHotKey \(label) (id=\(id)) -> \(meaning)")
    }
}

// MARK: - entry point

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
