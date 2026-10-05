import AppKit
import Carbon.HIToolbox

/// The key catalog shared by the spec parser, the recorder and the display formatter.
///
/// One table for all three means a recorded shortcut and a hand-written config spec can
/// never disagree about what a name means.
enum HotKeyKey {
    /// name -> virtual key code
    static let byName: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space, "spacebar": kVK_Space, "return": kVK_Return, "enter": kVK_Return,
        "tab": kVK_Tab, "escape": kVK_Escape, "esc": kVK_Escape,
        "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
        "minus": kVK_ANSI_Minus, "-": kVK_ANSI_Minus,
        "equal": kVK_ANSI_Equal, "=": kVK_ANSI_Equal,
        "leftbracket": kVK_ANSI_LeftBracket, "[": kVK_ANSI_LeftBracket,
        "rightbracket": kVK_ANSI_RightBracket, "]": kVK_ANSI_RightBracket,
        "backslash": kVK_ANSI_Backslash, "\\": kVK_ANSI_Backslash,
        "semicolon": kVK_ANSI_Semicolon, ";": kVK_ANSI_Semicolon,
        "quote": kVK_ANSI_Quote, "'": kVK_ANSI_Quote,
        "comma": kVK_ANSI_Comma, ",": kVK_ANSI_Comma,
        "period": kVK_ANSI_Period, ".": kVK_ANSI_Period,
        "slash": kVK_ANSI_Slash, "/": kVK_ANSI_Slash,
        "grave": kVK_ANSI_Grave, "`": kVK_ANSI_Grave,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "down": kVK_DownArrow, "up": kVK_UpArrow,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12
    ]

    /// key code -> canonical spec name (first name wins, so the dictionary above is ordered)
    static let nameByCode: [Int: String] = {
        var result: [Int: String] = [:]
        for (name, code) in byName where result[code] == nil {
            if name == "spacebar" || name == "enter" || name == "esc" || name == "backspace"
                || name == "-" || name == "=" || name == "[" || name == "]" || name == "\\"
                || name == ";" || name == "'" || name == "," || name == "." || name == "/" || name == "`" {
                continue
            }
            result[code] = name
        }
        return result
    }()

    /// Symbols for the on-screen display, not for the config file.
    static let symbols: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`"
    ]
}

/// Parsing and formatting of a hotkey spec such as `option+space` or `ctrl+shift+k`.
enum HotKey {
    static func modifierValue(_ part: String) -> Int? {
        switch part {
        case "cmd", "command", "meta", "super": return cmdKey
        case "opt", "option", "alt": return optionKey
        case "ctrl", "control": return controlKey
        case "shift": return shiftKey
        default: return nil
        }
    }

    /// At least one modifier is required: a bare key registered globally would swallow that
    /// key in every application, which is never what someone means to configure.
    static func parse(spec: String) -> (keyCode: Int, modifiers: Int)? {
        let parts = spec.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var modifiers = 0
        var keyCode: Int?
        for part in parts {
            if let modifier = modifierValue(part) {
                modifiers |= modifier
                continue
            }
            if let code = HotKeyKey.byName[part] {
                keyCode = code
                continue
            }
            return nil
        }
        guard let code = keyCode, modifiers != 0 else { return nil }
        return (code, modifiers)
    }

    /// Canonical spec for a captured combination, or nil when the key is not in the catalog.
    static func spec(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> String? {
        guard let name = HotKeyKey.nameByCode[keyCode] else { return nil }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        guard !parts.isEmpty else { return nil }
        parts.append(name)
        return parts.joined(separator: "+")
    }

    static func describe(keyCode: Int, modifiers: Int) -> String {
        var parts: [String] = []
        if modifiers & controlKey != 0 { parts.append("ctrl") }
        if modifiers & optionKey != 0 { parts.append("option") }
        if modifiers & shiftKey != 0 { parts.append("shift") }
        if modifiers & cmdKey != 0 { parts.append("cmd") }
        parts.append(HotKeyKey.nameByCode[keyCode] ?? "key\(keyCode)")
        return parts.joined(separator: "+")
    }

    /// Pretty form for the UI: `⌥Space`, `⌃⌥K`.
    static func display(spec: String) -> String {
        guard let parsed = parse(spec: spec) else { return spec }
        return display(keyCode: parsed.keyCode, modifiers: parsed.modifiers)
    }

    static func display(keyCode: Int?, modifiers: Int) -> String {
        var text = ""
        if modifiers & controlKey != 0 { text += "⌃" }
        if modifiers & optionKey != 0 { text += "⌥" }
        if modifiers & shiftKey != 0 { text += "⇧" }
        if modifiers & cmdKey != 0 { text += "⌘" }
        guard let keyCode = keyCode else { return text }
        let symbol = HotKeyKey.symbols[keyCode]
            ?? HotKeyKey.nameByCode[keyCode].map { $0.count == 1 ? $0.uppercased() : $0.capitalized }
            ?? "?"
        return text + symbol
    }

    /// Known collisions, surfaced in the UI instead of silently losing to another app.
    static func conflictWarning(spec: String) -> String? {
        guard let parsed = parse(spec: spec) else {
            return "无法识别该组合（必须包含至少一个修饰键，且按键需受支持）"
        }
        let normalized = describe(keyCode: parsed.keyCode, modifiers: parsed.modifiers)
        let known: [String: String] = [
            "cmd+space": "与 Spotlight 默认热键冲突",
            "ctrl+space": "与「切换输入法」冲突",
            "cmd+tab": "与 App 切换冲突（系统保留）",
            "cmd+q": "与「退出应用」冲突",
            "cmd+shift+3": "与屏幕截图冲突",
            "cmd+shift+4": "与屏幕截图冲突",
            "cmd+shift+5": "与屏幕录制冲突",
            "option+space": "与 Alfred 默认热键相同（若还装着 Alfred 会互抢）"
        ]
        return known[normalized]
    }
}

/// Registers one Carbon global hotkey. Carbon hotkeys need no Accessibility
/// permission, which is why P0 runs with zero permissions.
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerInstalled = false
    private var action: (() -> Void)?
    private var lastSpec: String?

    private init() {}

    @discardableResult
    func register(spec: String, action: @escaping () -> Void) -> Bool {
        self.action = action
        installEventHandlerIfNeeded()

        guard let parsed = HotKey.parse(spec: spec) else {
            Log.write("hotkey spec \"\(spec)\" not understood; falling back to option+space")
            return register(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), label: "option+space")
        }
        return register(keyCode: UInt32(parsed.keyCode), modifiers: UInt32(parsed.modifiers), label: spec)
    }

    /// Frees the combination while the recorder captures a new one.
    func suspend() {
        if let existing = hotKeyRef {
            UnregisterEventHotKey(existing)
            hotKeyRef = nil
            Log.write("hotkey suspended")
        }
    }

    /// Restores whatever was last registered successfully.
    func resume() {
        guard let spec = lastSpec else { return }
        register(spec: spec, action: action ?? {})
    }

    private func register(keyCode: UInt32, modifiers: UInt32, label: String) -> Bool {
        if let existing = hotKeyRef {
            UnregisterEventHotKey(existing)
            hotKeyRef = nil
        }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D4C4E43), id: 1) // 'MLNC'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
            lastSpec = label
            Log.write("hotkey registered: \(label)")
            return true
        }
        if status == eventHotKeyExistsErr {
            Log.write("hotkey \(label) FAILED: already registered by another app")
        } else {
            Log.write("hotkey \(label) FAILED: status=\(status)")
        }
        return false
    }

    fileprivate func fire() { action?() }

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                        hotKeyEventHandler,
                                        1,
                                        &eventType,
                                        nil,
                                        nil)
        Log.write("InstallEventHandler status=\(status)")
        eventHandlerInstalled = (status == noErr)
    }
}

private func hotKeyEventHandler(_ callRef: EventHandlerCallRef?,
                               _ event: EventRef?,
                               _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    HotKeyManager.shared.fire()
    return noErr
}
