import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let indexer = Indexer()
    var config = Config()
    private let expander = SnippetExpander()
    private var permissionTimer: Timer?
    private lazy var settings = SettingsWindowController(config: config)
    private lazy var palette = PaletteController(indexer: indexer, config: config)
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("=== MacLauncher starting (pid \(ProcessInfo.processInfo.processIdentifier)) ===")

        // Fine-grained step logging: a LaunchServices launch once hung silently
        // between two steps, so each one is attributable from the log alone.
        Log.write("step: single-instance check")
        if exitIfAlreadyRunning() { return }

        Log.write("step: loading local config")
        config = Config.load()

        Log.write("step: activation policy (showInDock=\(config.showInDock))")
        applyActivationPolicy()
        applyDockIcon()

        // Touch the palette now so its workspace observer starts tracking which app was
        // frontmost. A lazily created controller would miss that notification and then
        // have no paste target when the palette is opened from the Dock.
        palette.config = config

        Log.write("step: installing status item")
        installStatusItem()
        installMainMenu()

        Log.write("step: building app index")
        indexer.buildApps()
        indexer.updateSnippets(config.snippets)

        Log.write("step: starting snippet auto-expansion")
        expander.isPaletteVisible = { [weak self] in self?.palette.isVisible ?? false }
        expander.injectionMode = config.snippetInjection
        if config.autoExpandSnippets {
            expander.start(snippets: config.snippets)
            if !expander.isRunning {
                // Granting Accessibility does not restart the app, so poll until it appears.
                watchForAccessibilityPermission()
            }
        } else {
            Log.write("auto-expansion disabled by config")
        }

        Log.write("step: wiring palette commands and the snippet editor")
        palette.onCommand = { [weak self] command in
            guard let self = self else { return }
            switch command {
            case "snippets":
                self.settings.updateConfig(self.config)
                self.settings.show()
            case "reload":
                self.reloadIndex()
            default:
                Log.write("unknown command: \(command)")
            }
        }
        settings.onSave = { [weak self] updated -> String? in
            guard let self = self else { return nil }
            self.config = updated
            self.palette.config = updated
            self.indexer.updateSnippets(updated.snippets)
            self.expander.updateSnippets(updated.snippets)
            self.applyActivationPolicy()

            // Re-register the global hotkey so a changed shortcut works without a restart.
            let ok = HotKeyManager.shared.register(spec: updated.hotKey) { [weak self] in
                self?.togglePalette()
            }
            Log.write("configuration hot-applied (hotkey \(updated.hotKey): \(ok ? "ready" : "FAILED"))")
            guard ok else {
                return "已保存，但热键 \(HotKey.display(spec: updated.hotKey)) 注册失败：可能已被其他 App 占用"
            }
            return nil
        }
        // File search is delegated to Spotlight on demand; nothing enumerates folders
        // here, which is what used to block startup forever.

        Log.write("step: registering hotkey")
        let registered = HotKeyManager.shared.register(spec: config.hotKey) { [weak self] in
            self?.togglePalette()
        }
        Log.write("hotkey \(config.hotKey): \(registered ? "ready" : "FAILED (see above)")")

        Log.write("step: checking Accessibility permission for snippet pasting")
        if Paster.isTrusted {
            Log.write("accessibility: granted (snippet pasting available)")
        } else {
            Log.write("accessibility: NOT granted — approve the system prompt, or use the status menu item 'Accessibility settings…'")
            Paster.requestTrust()
        }

        Log.write("step: reconciling the shared iCloud config in the background")
        Config.reconcileShared(local: config) { [weak self] shared in
            guard let self = self else { return }
            self.config = shared
            self.palette.config = shared
            self.indexer.updateSnippets(shared.snippets)
            self.expander.updateSnippets(shared.snippets)
            self.settings.updateConfig(shared)
            self.applyActivationPolicy()
        }

        if let index = CommandLine.arguments.firstIndex(of: "--render-settings"),
           index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            let tab = (index + 2 < CommandLine.arguments.count) ? Int(CommandLine.arguments[index + 2]) ?? 0 : 0
            let appearance: NSAppearance.Name = CommandLine.arguments.contains("--light") ? .aqua : .darkAqua
            settings.updateConfig(config)
            settings.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.settings.renderToPNG(path: path, appearanceName: appearance, tabIndex: tab)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            }
        } else if let index = CommandLine.arguments.firstIndex(of: "--render-palette"),
           index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            let query = (index + 2 < CommandLine.arguments.count) ? CommandLine.arguments[index + 2] : ""
            let appearance: NSAppearance.Name = CommandLine.arguments.contains("--light") ? .aqua : .darkAqua
            togglePalette()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.palette.renderToPNG(path: path, query: query, appearanceName: appearance)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            }
        } else if CommandLine.arguments.contains("--settings-selftest") {
            runSettingsSelfTest()
        } else {
            Log.write("startup complete")
        }
    }

    /// Right-clicking the Dock icon is the one entry point that the notch cannot hide.
    /// Quitting is the one action that leaves the user with a dead launcher, and ⌘Q is easy
    /// to hit while the settings window is open. So it asks first, and on confirmation takes
    /// the LaunchAgent down too — otherwise launchd (KeepAlive) would bring it straight back.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.messageText = "退出 MacLauncher？"
        alert.informativeText = "退出后热键与片段自动展开都会停止，需要重新打开 App 才能恢复。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/com.luyizhou.maclauncher"]
        try? process.run()
        process.waitUntilExit()
        Log.write("quit requested: launch agent booted out, terminating")
        return .terminateNow
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSnippetSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let paletteItem = NSMenuItem(title: "显示面板", action: #selector(showPaletteFromMenu), keyEquivalent: "")
        paletteItem.target = self
        menu.addItem(paletteItem)
        return menu
    }

    /// Regression check for the snippet editor: open → close → reopen. This used to abort
    /// the process, because a window created in code is released when closed and the
    /// second open then messaged a deallocated window.
    private func runSettingsSelfTest() {
        Log.write("settings selftest: opening")
        settings.updateConfig(config)
        settings.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            Log.write("settings selftest: closing")
            self.settings.closeForSelfTest()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Log.write("settings selftest: reopening")
                self.settings.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    Log.write("settings selftest: PASSED (reopen did not crash)")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Accessory by default (no Dock icon, no menu-bar takeover). `showInDock` is the
    /// escape hatch for a menu bar too crowded to show the status item.
    private func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = config.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            Log.write("activation policy set to \(policy == .regular ? "regular (Dock icon visible)" : "accessory (no Dock icon)")")
        }
    }

    /// Toggling Accessibility in System Settings does not restart the app, so poll until
    /// the permission appears and then start expansion without requiring a relaunch.
    private func watchForAccessibilityPermission() {
        guard permissionTimer == nil else { return }
        Log.write("waiting for Accessibility permission (checked every 3 s)")
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            guard Paster.isTrusted else { return }
            timer.invalidate()
            self.permissionTimer = nil
            Log.write("accessibility granted while running")
            if self.config.autoExpandSnippets {
                self.expander.start(snippets: self.config.snippets)
            }
        }
    }

    /// The bundle ships no `.icns`, so the Dock would show the generic application
    /// icon. Drawing the same SF Symbol used by the status item keeps the two entry
    /// points recognisable without an icon file. A real `.icns` is P1 polish.
    private func applyDockIcon() {
        guard let symbol = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "MacLauncher") else {
            return
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 128, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let tinted = symbol.withSymbolConfiguration(configuration) else { return }

        let size = NSSize(width: 256, height: 256)
        let icon = NSImage(size: size)
        icon.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 58, yRadius: 58).fill()
        tinted.draw(in: NSRect(x: 48, y: 48, width: 160, height: 160),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0)
        icon.unlockFocus()
        NSApp.applicationIconImage = icon
        Log.write("dock icon set from SF Symbol 'magnifyingglass'")
    }

    /// A second instance cannot register the same hotkey, so refuse to start.
    private func exitIfAlreadyRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != ownPID
        }
        guard let other = others.first else { return false }
        Log.write("another instance is already running (pid \(other.processIdentifier)); exiting")
        NSApp.terminate(nil)
        return true
    }

    /// Clicking the Dock icon (or re-opening from Finder) opens the palette, so the
    /// `showInDock` escape hatch gives a visible way in when the menu bar hides us.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        palette.config = config
        palette.show()
        return false
    }

    /// A real main menu matters in `showInDock` mode: without an Edit menu the search
    /// field cannot paste, and the menu bar would be empty while the app is active.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MacLauncher",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let showItem = NSMenuItem(title: "Show palette", action: #selector(showPaletteFromMenu), keyEquivalent: "")
        showItem.target = self
        appMenu.addItem(showItem)
        let snippetSettingsItem = NSMenuItem(title: "Snippet settings…", action: #selector(showSnippetSettings), keyEquivalent: ",")
        snippetSettingsItem.target = self
        appMenu.addItem(snippetSettingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MacLauncher",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
        Log.write("main menu installed (App + Edit)")
    }

    // MARK: - palette

    func togglePalette() {
        palette.config = config
        Log.write("hotkey fired: apps=\(indexer.apps.count)")
        palette.toggle()
    }

    // MARK: - status item

    @objc private func showPaletteFromMenu() {
        togglePalette()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // An SF Symbol reads better than a text glyph and is more likely to render.
            if let image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "MacLauncher") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "ML"
            }
        } else {
            Log.write("status item has NO button — the menu bar entry cannot be shown")
        }

        let menu = NSMenu()

        let showItem = NSMenuItem(title: "Show palette", action: #selector(showPaletteFromMenu), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let reloadItem = NSMenuItem(title: "Reload app index", action: #selector(reloadIndex), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        let configItem = NSMenuItem(title: "Open config in editor", action: #selector(openConfig), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)

        let logItem = NSMenuItem(title: "Reveal log", action: #selector(revealLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        let permissionItem = NSMenuItem(title: "Accessibility settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)

        let snippetsItem = NSMenuItem(title: "Snippet settings…", action: #selector(showSnippetSettings), keyEquivalent: "")
        snippetsItem.target = self
        menu.addItem(snippetsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit MacLauncher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        Log.write("status item installed; local config \(AppPaths.localConfigURL.path)")

        // A status item on a crowded notched menu bar still has a button but gets no
        // on-screen window. This check makes that difference visible in the log.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak item] in
            guard let button = item?.button else {
                Log.write("status item check: button is nil")
                return
            }
            let window = button.window
            var screenInfo = "no-screen"
            if let screen = window?.screen {
                // auxiliaryTopLeft/RightArea bracket the notch; an item placed inside the
                // gap is on screen but physically invisible behind the cutout.
                screenInfo = "screenFrame=\(screen.frame) auxLeft=\(String(describing: screen.auxiliaryTopLeftArea)) auxRight=\(String(describing: screen.auxiliaryTopRightArea))"
            }
            Log.write("status item check: windowFrame=\(window?.frame ?? .zero) visible=\(window?.isVisible ?? false) level=\(window?.level.rawValue ?? -1) \(screenInfo)")
        }
    }

    @objc private func reloadIndex() {
        config = Config.load()
        indexer.buildApps()
        indexer.updateSnippets(config.snippets)
        expander.updateSnippets(config.snippets)
        applyActivationPolicy()
    }

    @objc private func openConfig() {
        let local = AppPaths.localConfigURL
        if !FileManager.default.fileExists(atPath: local.path) {
            Config.write(config, to: local)
        }
        NSWorkspace.shared.open(local)
    }

    @objc private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.logURL])
    }

    @objc private func openAccessibilitySettings() {
        Paster.openAccessibilitySettings()
    }

    @objc private func showSnippetSettings() {
        settings.updateConfig(config)
        settings.show()
    }
}
