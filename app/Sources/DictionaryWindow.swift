import AppKit
import Carbon.HIToolbox

/// Container that lays out from its own bounds, so the window can be resized freely.
final class ActionPane: NSView {
    var layoutBlock: ((NSSize) -> Void)?
    var onCancel: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        layoutBlock?(bounds.size)
    }

    /// Esc travels the responder chain as `cancelOperation:`, which is the mechanism that
    /// actually works when the body text view holds focus. (The previous version relied on a
    /// hidden button's key equivalent and never fired.)
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘W is normally delivered by the File menu; this keeps the window closable even if
        // the menu is missing or the event is routed to the view first.
        if event.type == .keyDown,
           event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The small window that shows the full entry after pressing Return on a dictionary row.
///
/// Deliberately a real window rather than more palette rows: the entry is long (senses,
/// examples) and the point is to read it while writing something else.
final class DictionaryWindowController: NSObject {
    static let shared = DictionaryWindowController()

    private let window: NSWindow
    private let pane = ActionPane()
    private let headwordLabel = NSTextField(labelWithString: "")
    private let partOfSpeechLabel = NSTextField(labelWithString: "")
    private let phoneticsLabel = NSTextField(labelWithString: "")
    private let headerSeparator = NSBox()
    private let footerSeparator = NSBox()
    private let textView = NSTextView()
    private var bodyScroll = NSScrollView()
    private let copyButton = NSButton()
    private let openButton = NSButton()
    private let hintLabel = NSTextField(labelWithString: "Esc / ⌘W 关闭")
    private var entry: DictionaryEntry?
    private var previousApp: NSRunningApplication?

    private static let size = NSSize(width: 470, height: 400)

    override private init() {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: DictionaryWindowController.size),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered,
                          defer: false)
        super.init()
        window.isReleasedWhenClosed = false      // same trap as the settings window
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden         // the headword is already the first line
        window.title = "词典"
        window.level = .floating                 // it is a reference while you write
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 360, height: 260)
        buildUI()
    }

    func show(word: String) {
        guard let entry = Dictionary.lookUp(word) else {
            NSSound.beep()
            return
        }
        self.entry = entry
        previousApp = NSWorkspace.shared.frontmostApplication

        let presentation = DictionaryPresentation(entry: entry)
        headwordLabel.stringValue = entry.headword
        phoneticsLabel.stringValue = entry.phonetics
        phoneticsLabel.isHidden = entry.phonetics.isEmpty
        partOfSpeechLabel.stringValue = presentation.partOfSpeech
        partOfSpeechLabel.isHidden = presentation.partOfSpeech.isEmpty
        textView.textStorage?.setAttributedString(presentation.body)

        resizeToFit(presentation)
        window.center()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        Log.write("dictionary window: \(entry.query) -> \(entry.headword) (\(entry.raw.count) chars)")
    }

    /// Fits the window to the entry: a one-line entry gets a small window instead of a big
    /// mostly empty one, and a long entry grows up to a limit before the body scrolls.
    private func resizeToFit(_ presentation: DictionaryPresentation) {
        let inset: CGFloat = 22
        let bodyWidth = max(200, window.frame.width - inset * 2)
        let measured = presentation.body.boundingRect(
            with: NSSize(width: bodyWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let bodyHeight = min(max(measured.height + 8, 34), 460)
        // Must match the layout below: body area = size.height - (top 38 + 92) - (footer 64).
        // Using a smaller constant left the last sense clipped by ~18 pt.
        let height = bodyHeight + 194
        var frame = window.frame
        frame.size = NSSize(width: frame.width, height: height)
        window.setFrame(frame, display: true)
        pane.layoutBlock?(NSSize(width: frame.width, height: height))
    }

    // MARK: - UI

    private func buildUI() {
        pane.frame = NSRect(origin: .zero, size: DictionaryWindowController.size)
        pane.autoresizingMask = [.width, .height]

        headwordLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        headwordLabel.lineBreakMode = .byTruncatingTail
        pane.addSubview(headwordLabel)

        partOfSpeechLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        partOfSpeechLabel.textColor = .controlAccentColor
        partOfSpeechLabel.alignment = .center
        partOfSpeechLabel.wantsLayer = true
        partOfSpeechLabel.layer?.cornerRadius = 4
        partOfSpeechLabel.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        pane.addSubview(partOfSpeechLabel)

        phoneticsLabel.font = .systemFont(ofSize: 12)
        phoneticsLabel.textColor = .secondaryLabelColor
        phoneticsLabel.lineBreakMode = .byWordWrapping
        phoneticsLabel.maximumNumberOfLines = 2
        phoneticsLabel.alignment = .right
        pane.addSubview(phoneticsLabel)

        headerSeparator.boxType = .separator
        pane.addSubview(headerSeparator)

        // Read-only but selectable: copying one sense out of an entry is a normal thing to do.
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        bodyScroll.hasVerticalScroller = true
        bodyScroll.drawsBackground = false
        bodyScroll.borderType = .noBorder
        bodyScroll.documentView = textView
        pane.addSubview(bodyScroll)

        footerSeparator.boxType = .separator
        pane.addSubview(footerSeparator)

        copyButton.title = "复制释义"
        copyButton.target = self
        copyButton.action = #selector(copyEntry)
        copyButton.bezelStyle = .rounded
        pane.addSubview(copyButton)

        openButton.title = "在词典 App 中打开"
        openButton.target = self
        openButton.action = #selector(openInDictionaryApp)
        openButton.bezelStyle = .rounded
        pane.addSubview(openButton)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .right
        pane.addSubview(hintLabel)

        pane.onCancel = { [weak self] in self?.close() }
        pane.layoutBlock = { [weak self] size in
            guard let self = self else { return }
            let inset: CGFloat = 22
            let width = size.width - inset * 2
            // Below the (transparent) title bar: with fullSizeContentView the content starts
            // under the traffic lights, which used to collide with the headword.
            let top: CGFloat = 38
            self.headwordLabel.frame = NSRect(x: inset, y: top, width: width, height: 32)
            self.partOfSpeechLabel.frame = NSRect(x: inset, y: top + 38, width: 74, height: 18)
            self.phoneticsLabel.frame = NSRect(x: inset + 82, y: top + 34, width: width - 82, height: 32)
            self.headerSeparator.frame = NSRect(x: inset, y: top + 80, width: width, height: 1)
            let footerTop = size.height - 52
            self.bodyScroll.frame = NSRect(x: inset, y: top + 92, width: width, height: max(30, footerTop - top - 104))
            self.footerSeparator.frame = NSRect(x: inset, y: footerTop, width: width, height: 1)
            self.copyButton.frame = NSRect(x: inset, y: footerTop + 12, width: 100, height: 28)
            self.openButton.frame = NSRect(x: inset + 108, y: footerTop + 12, width: 150, height: 28)
            self.hintLabel.frame = NSRect(x: size.width - inset - 200, y: footerTop + 18, width: 200, height: 16)
        }
        pane.layoutBlock?(pane.bounds.size)
        window.contentView = pane
        renderView = pane
    }

    /// The view the offscreen review renderer should draw.
    private(set) var renderView: NSView?

    @objc func close() {
        window.orderOut(nil)
        if let previous = previousApp, !previous.isTerminated {
            if #available(macOS 14.0, *) {
                previous.activate()
            } else {
                previous.activate(options: [.activateIgnoringOtherApps])
            }
        }
        previousApp = nil
    }

    @objc private func copyEntry() {
        guard let entry = entry else { return }
        let text = "\(entry.headword)  \(entry.phonetics)\n\(Dictionary.format(entry.body))"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copyButton.title = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.title = "复制释义"
        }
        Log.write("dictionary entry copied: \(entry.headword)")
    }

    @objc private func openInDictionaryApp() {
        guard let entry = entry else { return }
        let escaped = entry.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? entry.query
        guard let url = URL(string: "dict://\(escaped)") else { return }
        NSWorkspace.shared.open(url)
        Log.write("opened dictionary app for \(entry.query)")
    }

    // MARK: - regression check

    /// Sends a synthetic Esc and a synthetic ⌘W to the window and reports whether each one
    /// closed it. Runs in the app process (needs a real window), so it is wired to
    /// `--dictionary-selftest` rather than to a plain CLI mode.
    func selfTest(word: String) -> Bool {
        var passed = true
        for (name, keyCode, flags, characters) in [("Esc", UInt16(kVK_Escape), NSEvent.ModifierFlags(), "\u{1b}"),
                                                   ("⌘W", UInt16(kVK_ANSI_W), NSEvent.ModifierFlags.command, "w")] {
            show(word: word)
            guard window.isVisible else {
                Log.write("dictionary selftest: window did not open for \(name)")
                return false
            }
            guard let event = NSEvent.keyEvent(with: .keyDown,
                                               location: .zero,
                                               modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber,
                                               context: nil,
                                               characters: characters,
                                               charactersIgnoringModifiers: characters,
                                               isARepeat: false,
                                               keyCode: keyCode) else {
                Log.write("dictionary selftest: could not synthesize \(name)")
                return false
            }
            // Probe the three routes separately: knowing which one actually closes the
            // window is the difference between a fix and a guess.
            var closed = false
            show(word: word)
            let byView = window.contentView?.performKeyEquivalent(with: event) ?? false
            closed = !window.isVisible
            Log.write("dictionary selftest: \(name) view-level handled=\(byView) closed=\(closed)")

            if !closed {
                show(word: word)
                let byMenu = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
                closed = !window.isVisible
                Log.write("dictionary selftest: \(name) menu-level handled=\(byMenu) closed=\(closed)")
            }
            if !closed {
                show(word: word)
                NSApp.sendEvent(event)
                closed = !window.isVisible
                Log.write("dictionary selftest: \(name) via NSApp.sendEvent closed=\(closed)")
            }
            Log.write("dictionary selftest: \(name) -> \(closed ? "closed" : "STILL OPEN")")
            if !closed { passed = false }
        }
        return passed
    }

    // MARK: - review renderer

    func renderToPNG(path: String, word: String, appearanceName: NSAppearance.Name) {
        show(word: word)
        window.appearance = NSAppearance(named: appearanceName)
        guard let view = renderView else { return }
        view.display()
        view.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(view.bounds.width * scale),
                                         pixelsHigh: Int(view.bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        Log.write("rendered dictionary window for \(word) to \(path)")
    }
}
