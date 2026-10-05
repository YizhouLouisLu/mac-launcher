import AppKit
import Carbon.HIToolbox

/// A click-to-record control: click it, press a combination, and it reports the spec.
///
/// While recording, the app's own global hotkey is suspended (through
/// `onRecordingChanged`): Carbon swallows a registered combination before any view sees it,
/// so without that the user could never re-record the shortcut that is currently active.
final class HotKeyRecorderView: NSView {
    var onCapture: ((String) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private(set) var spec: String = "option+space"
    private(set) var isRecording = false
    private var pendingModifiers: NSEvent.ModifierFlags = []

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func setSpec(_ newSpec: String) {
        spec = newSpec
        needsDisplay = true
    }

    func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        pendingModifiers = []
        window?.makeFirstResponder(self)
        onRecordingChanged?(true)
        needsDisplay = true
    }

    private func endRecording() {
        isRecording = false
        pendingModifiers = []
        onRecordingChanged?(false)
        needsDisplay = true
    }

    // MARK: - events

    override func mouseDown(with event: NSEvent) {
        beginRecording()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }
        if Int(event.keyCode) == kVK_Escape {
            endRecording()
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let captured = HotKey.spec(keyCode: Int(event.keyCode), modifiers: modifiers) else {
            NSSound.beep()
            return
        }
        spec = captured
        endRecording()
        onCapture?(captured)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        pendingModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { endRecording() }
        return true
    }

    // MARK: - drawing

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        outline.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        outline.lineWidth = isRecording ? 2 : 1
        outline.stroke()

        let text: String
        if isRecording {
            text = pendingModifiers.isEmpty
                ? "按下组合键（Esc 取消）"
                : HotKey.display(keyCode: nil, modifiers: modifierBits(pendingModifiers)) + " …"
        } else {
            text = HotKey.display(spec: spec)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: max(8, (bounds.width - size.width) / 2),
                             y: max(0, (bounds.height - size.height) / 2))
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    private func modifierBits(_ flags: NSEvent.ModifierFlags) -> Int {
        var bits = 0
        if flags.contains(.control) { bits |= controlKey }
        if flags.contains(.option) { bits |= optionKey }
        if flags.contains(.shift) { bits |= shiftKey }
        if flags.contains(.command) { bits |= cmdKey }
        return bits
    }
}
