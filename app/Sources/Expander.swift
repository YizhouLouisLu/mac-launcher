import AppKit
import Carbon.HIToolbox

/// Expands snippet keywords in place while the user types in any application.
///
/// Deliberate safety rules:
///  * the event monitor is **listen-only**: the user's keystrokes are never swallowed or
///    rewritten on the way in — expansion happens after the fact, by deleting the typed
///    keyword and pasting the replacement;
///  * only keywords that begin with a non-alphanumeric character (`;mail`) auto-expand.
///    A plain-word keyword such as `sig` would fire in the middle of ordinary prose, so
///    it stays usable in the palette but is never expanded automatically;
///  * expansion is abandoned if the frontmost application changed while the keyword was
///    being typed, or if the palette itself is open;
///  * nothing happens inside secure input fields, because macOS does not deliver those
///    events to global monitors at all.
final class SnippetExpander {
    private var snippets: [Snippet] = []
    private var buffer = ""
    private var bufferApp: NSRunningApplication?
    private var monitor: Any?
    private var pending: DispatchWorkItem?

    /// Set by the app delegate: expansion must not fire while the palette is open.
    var isPaletteVisible: () -> Bool = { false }
    /// "type" (Unicode key events, no clipboard) or "paste" (clipboard + Cmd+V).
    var injectionMode: String = "type"

    private static let expansionDelay: TimeInterval = 0.09
    private static let bufferLimit = 64

    var isRunning: Bool { monitor != nil }

    // MARK: - pure matching (exercised by --expand-test)

    /// Keywords eligible for auto-expansion: non-empty and starting with a symbol.
    static func expandable(_ snippets: [Snippet]) -> [Snippet] {
        snippets.filter { snippet in
            guard let first = snippet.keyword.first else { return false }
            return !first.isLetter && !first.isNumber
        }
    }

    /// The snippet whose keyword ends the buffer, preferring the longest keyword.
    static func match(snippets: [Snippet], buffer: String) -> Snippet? {
        expandable(snippets)
            .filter { !$0.keyword.isEmpty && buffer.hasSuffix($0.keyword) }
            .sorted { $0.keyword.count > $1.keyword.count }
            .first
    }

    // MARK: - live monitor

    func start(snippets: [Snippet]) {
        self.snippets = snippets
        stop()
        guard Paster.isTrusted else {
            Log.write("auto-expansion not started: Accessibility permission is not granted")
            return
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handle(event)
        }
        Log.write("auto-expansion started for \(SnippetExpander.expandable(snippets).count) keyword(s) of \(snippets.count)")
    }

    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        pending?.cancel()
        pending = nil
        buffer = ""
    }

    func updateSnippets(_ snippets: [Snippet]) {
        self.snippets = snippets
        buffer = ""
    }

    // MARK: - key handling

    private func handle(_ event: NSEvent) {
        // Command/Control combinations are shortcuts, not typing.
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            buffer = ""
            return
        }

        switch event.keyCode {
        case 51: // delete: keep the buffer consistent with what is on screen
            if !buffer.isEmpty { buffer.removeLast() }
            return
        case 36, 48, 53, 76: // return, tab, escape, enter
            buffer = ""
            return
        default:
            break
        }

        guard let characters = event.characters, !characters.isEmpty,
              let scalar = characters.unicodeScalars.first, scalar.value >= 32 else {
            buffer = ""
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        if bufferApp?.processIdentifier != frontmost?.processIdentifier {
            buffer = ""
            bufferApp = frontmost
        }
        buffer.append(characters)
        if buffer.count > SnippetExpander.bufferLimit {
            buffer = String(buffer.suffix(SnippetExpander.bufferLimit))
        }

        guard let snippet = SnippetExpander.match(snippets: snippets, buffer: buffer) else { return }
        scheduleExpansion(of: snippet)
    }

    private func scheduleExpansion(of snippet: Snippet) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.expand(snippet) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SnippetExpander.expansionDelay, execute: work)
    }

    private func expand(_ snippet: Snippet) {
        guard !isPaletteVisible() else { return }
        guard buffer.hasSuffix(snippet.keyword) else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == bufferApp?.processIdentifier else {
            Log.write("expansion abandoned: frontmost application changed")
            buffer = ""
            return
        }

        buffer = ""
        let started = Date()
        let (text, backoff) = Snippet.cursorSplit(snippet.content)
        // Newlines cannot be delivered as Unicode key events to Electron editors (VS Code
        // ignores them, collapsing the snippet onto one line), while a clipboard paste
        // inserts them literally. So multiline snippets always take the paste path and
        // single-line ones keep the fast typing path.
        let mode = text.contains("\n") ? "paste" : injectionMode
        Log.write("expanding \(snippet.keyword) -> \(text.count) chars (caret back \(backoff), mode \(mode)) in \(bufferApp?.localizedName ?? "?")")

        Paster.postBackspaces(count: snippet.keyword.count)

        if mode == "paste" {
            // Clipboard path: the paste resolves asynchronously, so the caret nudge waits.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                Paster.pasteInPlace(text)
                guard backoff > 0 else {
                    Log.write("expansion complete in \(Int(Date().timeIntervalSince(started) * 1000))ms (paste)")
                    return
                }
                let settle = min(0.5, 0.12 + 0.005 * Double(text.count))
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                    Paster.postLeftArrows(count: backoff)
                    Log.write("expansion complete in \(Int(Date().timeIntervalSince(started) * 1000))ms (paste)")
                }
            }
        } else if mode == "whole" {
            // One event pair carries the whole string: fastest, but Electron-based editors
            // have been observed dropping such events, which then leaves the caret nudge
            // walking back through the user's existing text. Opt in only where it works.
            Paster.postWholeString(text)
            if backoff > 0 { Paster.postLeftArrows(count: backoff) }
            Log.write("expansion complete in \(Int(Date().timeIntervalSince(started) * 1000))ms (whole)")
        } else {
            // Typing path: one event pair per character. Slower than "whole" but reliable
            // everywhere, because every character is a separate, ordinary key event.
            let t0 = Date()
            Paster.postBackspaces(count: 0)
            Paster.typePerCharacter(text)
            let t1 = Date()
            if backoff > 0 { Paster.postLeftArrows(count: backoff) }
            let t2 = Date()
            Log.write("expansion phases: type=\(Int(t1.timeIntervalSince(t0) * 1000))ms arrows=\(Int(t2.timeIntervalSince(t0) * 1000))ms total=\(Int(Date().timeIntervalSince(started) * 1000))ms (type)")
        }
    }
}
