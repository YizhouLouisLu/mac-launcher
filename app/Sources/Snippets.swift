import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// One reusable text snippet.
///
/// `keyword` is what the user types in the palette (for example `;sig`); `name` is the
/// human label and is searchable too. Both are matched, so either works.
struct Snippet: Codable {
    var keyword: String
    var name: String
    var content: String

    enum CodingKeys: String, CodingKey {
        case keyword, name, content
    }

    /// Every field is optional on disk so a hand-edited file cannot break startup.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyword = (try? container.decode(String.self, forKey: .keyword)) ?? ""
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        content = (try? container.decode(String.self, forKey: .content)) ?? ""
    }

    init(keyword: String, name: String, content: String) {
        self.keyword = keyword
        self.name = name
        self.content = content
    }

    /// Alfred's `{cursor}` marker, kept verbatim in the content so migrated snippets read
    /// the same as they did in Alfred.
    ///
    /// Returns the text to insert (marker removed) and how many characters followed the
    /// marker, which is how far the caret has to move back afterwards. Only the first
    /// marker is honoured, which matches how the snippets are written in practice.
    static func cursorSplit(_ content: String) -> (text: String, offsetFromEnd: Int) {
        guard let range = content.range(of: "{cursor}") else { return (content, 0) }
        let before = String(content[content.startIndex..<range.lowerBound])
        let after = String(content[range.upperBound...])
        return (before + after, after.count)
    }
}

/// Injects text into another application.
///
/// The recipe was verified by the earlier spike:
///   1. remember the target application (the one that was frontmost before the palette),
///   2. hide the palette and re-activate the target,
///   3. wait ~450 ms for focus to settle — posting earlier loses the keystroke,
///   4. put the text on the pasteboard and post Cmd+V through the HID event tap,
///   5. restore the previous clipboard content.
///
/// Caveat measured during the spike: Cmd+V is routed through the target's main menu, so an
/// application without an Edit menu will ignore it. The Unicode-typing fallback below
/// exists for that case (and for targets that reject synthetic key equivalents).
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show the Accessibility prompt. Returns the state after the call,
    /// which is usually still false: the user has to approve in System Settings.
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Result of an injection attempt, for logging and UI feedback.
    enum Outcome {
        case pasted
        case typedFallback
        case refusedNoPermission
        case noTarget
    }

    static func paste(_ text: String,
                      into target: NSRunningApplication?,
                      fallbackToTyping: Bool = true,
                      completion: @escaping (Outcome) -> Void) {
        guard isTrusted else {
            Log.write("paste refused: Accessibility permission is not granted")
            completion(.refusedNoPermission)
            return
        }
        guard let target = target, !target.isTerminated else {
            Log.write("paste refused: no target application was recorded")
            completion(.noTarget)
            return
        }

        let pasteboard = NSPasteboard.general
        // Snapshot everything (not just the plain-text flavour): an image, a file reference or
        // several items used to come back as an empty clipboard.
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ownership = pasteboard.changeCount
        Log.write("paste: clipboard borrowed (was \(snapshot.summary))")

        activate(target)
        Log.write("paste: activating \(target.localizedName ?? "?") and waiting for focus")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            postCommandV(to: target)
            Log.write("paste: posted Cmd+V to \(target.localizedName ?? "?")")

            DispatchQueue.main.asyncAfter(deadline: .now() + PaletteController.clipboardRestoreDelay) {
                snapshot.restore(to: pasteboard, ifUnchangedSince: ownership)
                completion(.pasted)
            }
        }
    }

    /// Posts Cmd+V. The HID tap is the normal path; a failing target can be addressed
    /// directly by pid as well, which is why both are logged distinctly.
    private static func postCommandV(to target: NSRunningApplication) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else {
            Log.write("paste: could not create the Cmd+V events")
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// Types the text as Unicode key events. Independent of the pasteboard and of the
    /// target's menu bindings, which makes it the safe fallback for stubborn targets.
    static func typeText(_ text: String, completion: @escaping () -> Void) {
        guard isTrusted, let source = CGEventSource(stateID: .combinedSessionState) else {
            completion()
            return
        }
        for character in text {
            var unit = character.utf16.first ?? 0
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            // This SDK replaced the CGEventKeyboardSetUnicodeString C function with the
            // CGEvent instance method.
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(12_000)
        }
        completion()
    }

    private static func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// Posts `count` backspaces, used to remove a typed keyword before replacing it.
    static func postBackspaces(count: Int) {
        guard isTrusted, count > 0, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false) else { continue }
            // Clear modifiers explicitly: the combined session state still reports Cmd as
            // held right after a synthetic Cmd+V, which would turn these into shortcuts.
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(3_000)
        }
    }

    /// Types text without touching the clipboard.
    ///
    /// Uses whole-string injection: one event pair carries the entire text. Measured on
    /// this machine, `post` costs ~3 ms per call, so per-character typing costs 2N calls
    /// (61 ms for 10 characters, ~600 ms for a 30-character snippet) while a single pair
    /// is effectively free. `typePerCharacter` is kept for comparison and as a fallback
    /// for targets that only honour the first character of an event.
    static func typeTextInPlace(_ text: String) {
        typePerCharacter(text)
    }

    /// One event pair per character; slower, but tolerant of odd targets.
    static func typePerCharacter(_ text: String) {
        guard isTrusted, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for codeUnit in text.utf16 {
            var unit = codeUnit
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(1_000)
        }
    }

    /// Moves the caret left, used to honour Alfred's `{cursor}` marker after pasting.
    static func postLeftArrows(count: Int) {
        guard isTrusted, count > 0, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_LeftArrow), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_LeftArrow), keyDown: false) else { continue }
            // Without clearing the flags the caret jumps to the start of the line instead:
            // the session still reports Cmd as held after the synthetic Cmd+V.
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(1_000)
        }
    }

    /// Posts the whole string in a single key event pair.
    ///
    /// Event posting costs roughly 10 ms per call on this machine, so the number of calls
    /// dominates latency; one pair instead of one pair per character is the difference
    /// between ~600 ms and ~20 ms for a 30-character snippet.
    static func postWholeString(_ text: String) {
        guard isTrusted, !text.isEmpty, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        var units = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        down.flags = []
        up.flags = []
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Pastes into whatever is frontmost right now: no re-activation and no settle delay,
    /// because expansion happens in an application that already has focus.
    static func pasteInPlace(_ text: String) {
        guard isTrusted else { return }
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ownership = pasteboard.changeCount

        if let source = CGEventSource(stateID: .combinedSessionState),
           let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
           let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) {
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + PaletteController.clipboardRestoreDelay) {
            snapshot.restore(to: pasteboard, ifUnchangedSince: ownership)
        }
    }
}
