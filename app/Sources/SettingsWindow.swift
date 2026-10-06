import AppKit

/// The settings window: a tabbed editor for snippets and for search engines.
///
/// Opened from the palette (type `snippets`) or from the app menu. Edits are kept in
/// memory until Save, which writes `config.json`, mirrors it to iCloud, and asks the app
/// delegate to re-apply the configuration — so a saved snippet or engine is live
/// immediately, with no restart.
/// Container for one settings tab. Frames are computed in `layout()` from the pane's real
/// bounds: the tab view gives its content area 736x420 (not the 756x452 originally assumed),
/// which silently clipped the bottom row of controls of every tab.
final class SettingsPane: NSView {
    var layoutBlock: ((NSSize) -> Void)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        layoutBlock?(bounds.size)
    }
}

final class SettingsWindowController: NSObject {
    private var config: Config
    private var snippets: [Snippet] = []
    private var engines: [SearchEngine] = []
    private var selectedIndex: Int?
    /// Which snippet the field values currently belong to. Committing against
    /// `selectedIndex` instead of this wrote the *previous* form into the newly
    /// selected snippet — with the empty startup form that erased snippet 0.
    private var formIndex: Int?
    private var isProgrammaticSelection = false
    private var selectedEngineIndex: Int?
    private var engineFormIndex: Int?
    /// Extra top-level folders searched in addition to (or instead of) the home directory.
    private var scopeFolders: [String] = []
    private var selectedScopeIndex: Int?
    private var dirty = false

    /// Called after a successful save so the app can hot-apply the new configuration. The
    /// return value is an optional warning to show (for example a hotkey that another app
    /// already owns), because a silently dead shortcut is worse than a visible complaint.
    var onSave: ((Config) -> String?)?

    private let window: NSWindow
    private let tabs = NSTabView()
    private let snippetTable = NSTableView()
    private let engineTable = NSTableView()
    private let keywordField = NSTextField()
    private let nameField = NSTextField()
    private let contentTextView = NSTextView()
    private let engineKeywordField = NSTextField()
    private let engineNameField = NSTextField()
    private let engineURLField = NSTextField()
    private let expandCheckbox = NSButton(checkboxWithTitle: "在任意 App 里自动展开（仅符号开头的关键词）", target: nil, action: nil)
    private let previewLabel = NSTextField(labelWithString: "")
    private let enginePreviewLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let removeSnippetButton = NSButton()
    private let removeEngineButton = NSButton()
    private let scopeTable = NSTableView()
    private let homeCheckbox = NSButton(checkboxWithTitle: "搜索整个家目录（推荐：文件散布在各处时仍能找到）", target: nil, action: nil)
    private let scopeHelpLabel = NSTextField(labelWithString: "")
    private let removeScopeButton = NSButton()
    private let snippetFilterField = NSTextField()
    /// Rows currently shown in the snippet list, after filtering: a filter has to keep a
    /// mapping back to the real index, otherwise editing a row edits the wrong snippet.
    private var visibleSnippetIndices: [Int] = []
    private let hotKeyRecorder = HotKeyRecorderView()
    private let hotKeyNoteLabel = NSTextField(labelWithString: "")
    private let dockCheckbox = NSButton(checkboxWithTitle: "在 Dock 中显示图标", target: nil, action: nil)
    private let maxResultsStepper = NSStepper()
    private let maxResultsLabel = NSTextField(labelWithString: "")
    private var recordedHotKey = "option+space"
    private var recordedMaxResults = 12

    /// The size the tab view actually gives its content area (measured, not assumed).
    private static let paneSize = NSSize(width: 736, height: 420)
    private static let listWidth: CGFloat = 300
    private static let formX: CGFloat = 336
    private static let formWidth: CGFloat = 384

    init(config: Config) {
        self.config = config
        self.snippets = config.snippets
        self.engines = config.engines
        self.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered,
                               defer: false)
        super.init()
        // A window created in code is released when closed by default, so reopening the
        // editor after closing it messaged a deallocated window and aborted the process.
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildUI()
        reloadFromConfig(config)
    }

    // MARK: - public

    func show() {
        reloadFromConfig(config)
        window.center()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        Log.write("settings window opened (\(snippets.count) snippets, \(engines.count) engines)")
    }

    func updateConfig(_ config: Config) {
        self.config = config
        if !dirty { reloadFromConfig(config) }
    }

    /// Used by the app's `--settings-selftest` regression check.
    func closeForSelfTest() {
        window.close()
    }

    /// Renders one tab of the window to a PNG, so the layout can be reviewed without
    /// Screen Recording permission (the same trick the palette review uses).
    func renderToPNG(path: String, appearanceName: NSAppearance.Name, tabIndex: Int) {
        window.appearance = NSAppearance(named: appearanceName)
        if tabIndex >= 0 && tabIndex < tabs.numberOfTabViewItems {
            tabs.selectTabViewItem(at: tabIndex)
        }
        // Render the selected tab's own view, not the window content view: cacheDisplay on
        // a window's content view skipped its plain controls (labels, checkboxes, steppers)
        // and produced a nearly empty picture. Same lesson as the palette review shots.
        guard let view = tabs.selectedTabViewItem?.view ?? window.contentView,
              view.bounds.width > 1 else {
            Log.write("render settings: nothing to render")
            return
        }
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
        Log.write("rendered settings tab \(tabIndex) \(Int(view.bounds.width))x\(Int(view.bounds.height)) to \(path)")
    }

    /// Replaces the in-memory lists from a configuration without touching the file.
    private func reloadFromConfig(_ config: Config) {
        self.config = config
        snippets = config.snippets
        engines = config.engines
        expandCheckbox.state = config.autoExpandSnippets ? .on : .off
        dirty = false
        snippetFilterField.stringValue = ""
        engineTable.reloadData()
        visibleSnippetIndices = Array(snippets.indices)
        snippetTable.reloadData()
        if snippets.isEmpty {
            selectedIndex = nil
            loadForm(nil)
        } else {
            select(min(selectedIndex ?? 0, snippets.count - 1))
        }
        if engines.isEmpty {
            selectedEngineIndex = nil
            loadEngineForm(nil)
        } else {
            selectEngine(min(selectedEngineIndex ?? 0, engines.count - 1))
        }
        scopeFolders = config.searchFolders
        homeCheckbox.state = config.searchHomeFolder ? .on : .off
        scopeTable.reloadData()
        selectedScopeIndex = scopeFolders.isEmpty ? nil : min(selectedScopeIndex ?? 0, scopeFolders.count - 1)
        if let index = selectedScopeIndex {
            scopeTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        refreshScopeHelp()
        recordedHotKey = config.hotKey
        hotKeyRecorder.setSpec(recordedHotKey)
        dockCheckbox.state = config.showInDock ? .on : .off
        recordedMaxResults = config.maxResults
        maxResultsStepper.integerValue = config.maxResults
        maxResultsLabel.stringValue = "\(config.maxResults)"
        refreshHotKeyNote()
        statusLabel.stringValue = ""
    }

    // MARK: - UI construction

    private func buildUI() {
        window.title = "MacLauncher 设置"
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: 780, height: 560))
        container.autoresizingMask = [.width, .height]

        tabs.frame = NSRect(x: 12, y: 54, width: 756, height: 466)
        tabs.autoresizingMask = [.width, .height]

        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "通用"
        generalTab.view = buildGeneralPane()
        let snippetTab = NSTabViewItem(identifier: "snippets")
        snippetTab.label = "片段"
        snippetTab.view = buildSnippetPane()
        let engineTab = NSTabViewItem(identifier: "engines")
        engineTab.label = "搜索引擎"
        engineTab.view = buildEnginePane()
        let scopeTab = NSTabViewItem(identifier: "scope")
        scopeTab.label = "搜索范围"
        scopeTab.view = buildScopePane()
        tabs.addTabViewItem(generalTab)
        tabs.addTabViewItem(snippetTab)
        tabs.addTabViewItem(engineTab)
        tabs.addTabViewItem(scopeTab)
        container.addSubview(tabs)

        let saveButton = NSButton(title: "保存", target: self, action: #selector(save))
        saveButton.frame = NSRect(x: 680, y: 14, width: 88, height: 30)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = [.command]
        container.addSubview(saveButton)

        let revertButton = NSButton(title: "放弃修改", target: self, action: #selector(revert))
        revertButton.frame = NSRect(x: 578, y: 14, width: 96, height: 30)
        revertButton.bezelStyle = .rounded
        container.addSubview(revertButton)

        statusLabel.frame = NSRect(x: 16, y: 20, width: 550, height: 18)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        container.addSubview(statusLabel)

        window.contentView = container
        updateFormEnabled()
        updateEngineFormEnabled()
    }

    private func buildSnippetPane() -> NSView {
        let pane = SettingsPane(frame: NSRect(origin: .zero, size: SettingsWindowController.paneSize))

        snippetTable.addTableColumn(makeColumn(width: SettingsWindowController.listWidth))
        snippetTable.headerView = nil
        snippetTable.rowHeight = 26
        snippetTable.dataSource = self
        snippetTable.delegate = self

        let addButton = NSButton(title: "＋", target: self, action: #selector(addSnippet))
        addButton.frame = NSRect(x: 16, y: 404, width: 44, height: 26)
        addButton.bezelStyle = .rounded
        pane.addSubview(addButton)

        removeSnippetButton.title = "－"
        removeSnippetButton.target = self
        removeSnippetButton.action = #selector(removeSnippet)
        removeSnippetButton.frame = NSRect(x: 66, y: 404, width: 44, height: 26)
        removeSnippetButton.bezelStyle = .rounded
        pane.addSubview(removeSnippetButton)

        let formX = SettingsWindowController.formX
        let formW = SettingsWindowController.formWidth

        pane.addSubview(label("关键词（自动展开只对符号开头生效）", x: formX, y: 16, width: 200))
        keywordField.frame = NSRect(x: formX, y: 34, width: 200, height: 24)
        keywordField.delegate = self
        keywordField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        pane.addSubview(keywordField)

        pane.addSubview(label("名称（也会参与面板搜索）", x: formX + 212, y: 16, width: formW - 212))
        nameField.frame = NSRect(x: formX + 212, y: 34, width: formW - 212, height: 24)
        nameField.delegate = self
        pane.addSubview(nameField)

        pane.addSubview(label("内容（可用 {cursor} 标记展开后光标的位置）", x: formX, y: 70, width: formW))

        contentTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        contentTextView.isRichText = false
        contentTextView.delegate = self
        contentTextView.autoresizingMask = [.width, .height]
        let contentScroll = NSScrollView(frame: NSRect(x: formX, y: 90, width: formW, height: 240))
        contentScroll.autoresizingMask = [.width, .height]
        contentScroll.hasVerticalScroller = true
        contentScroll.borderType = .bezelBorder
        contentScroll.documentView = contentTextView
        pane.addSubview(contentScroll)

        previewLabel.frame = NSRect(x: formX, y: 338, width: formW, height: 34)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.font = .systemFont(ofSize: 11)
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 2
        pane.addSubview(previewLabel)

        expandCheckbox.target = self
        expandCheckbox.action = #selector(toggleExpansion)
        pane.addSubview(expandCheckbox)

        snippetFilterField.placeholderString = "筛选片段（关键词 / 名称 / 内容）"
        snippetFilterField.font = .systemFont(ofSize: 12)
        snippetFilterField.delegate = self
        snippetFilterField.frame = NSRect(x: 16, y: 16, width: SettingsWindowController.listWidth, height: 24)
        pane.addSubview(snippetFilterField)

        let listScroll = makeListScroll(for: snippetTable)
        pane.addSubview(listScroll)
        pane.layoutBlock = { size in
            let bottom = size.height
            listScroll.frame = NSRect(x: 16, y: 46, width: SettingsWindowController.listWidth, height: max(60, bottom - 102))
            addButton.frame = NSRect(x: 16, y: bottom - 44, width: 44, height: 26)
            self.removeSnippetButton.frame = NSRect(x: 66, y: bottom - 44, width: 44, height: 26)
            let contentHeight = max(80, bottom - 250)
            contentScroll.frame = NSRect(x: formX, y: 90, width: formW, height: contentHeight)
            self.previewLabel.frame = NSRect(x: formX, y: 96 + contentHeight, width: formW, height: 34)
            self.expandCheckbox.frame = NSRect(x: formX, y: 134 + contentHeight, width: formW, height: 20)
        }
        pane.layoutBlock?(pane.bounds.size)

        return pane
    }

    private func buildEnginePane() -> NSView {
        let pane = SettingsPane(frame: NSRect(origin: .zero, size: SettingsWindowController.paneSize))

        engineTable.addTableColumn(makeColumn(width: SettingsWindowController.listWidth))
        engineTable.headerView = nil
        engineTable.rowHeight = 26
        engineTable.dataSource = self
        engineTable.delegate = self

        let addButton = NSButton(title: "＋", target: self, action: #selector(addEngine))
        addButton.frame = NSRect(x: 16, y: 404, width: 44, height: 26)
        addButton.bezelStyle = .rounded
        pane.addSubview(addButton)

        removeEngineButton.title = "－"
        removeEngineButton.target = self
        removeEngineButton.action = #selector(removeEngine)
        removeEngineButton.frame = NSRect(x: 66, y: 404, width: 44, height: 26)
        removeEngineButton.bezelStyle = .rounded
        pane.addSubview(removeEngineButton)

        let formX = SettingsWindowController.formX
        let formW = SettingsWindowController.formWidth

        pane.addSubview(label("在面板里输入「关键词 空格 内容」即可用该引擎搜索", x: formX, y: 16, width: formW))

        pane.addSubview(label("关键词", x: formX, y: 40, width: 120))
        engineKeywordField.frame = NSRect(x: formX, y: 58, width: 120, height: 24)
        engineKeywordField.delegate = self
        engineKeywordField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        pane.addSubview(engineKeywordField)

        pane.addSubview(label("名称", x: formX + 132, y: 40, width: formW - 132))
        engineNameField.frame = NSRect(x: formX + 132, y: 58, width: formW - 132, height: 24)
        engineNameField.delegate = self
        pane.addSubview(engineNameField)

        pane.addSubview(label("搜索 URL（用 {query} 表示查询词的位置）", x: formX, y: 94, width: formW))
        engineURLField.frame = NSRect(x: formX, y: 112, width: formW, height: 24)
        engineURLField.delegate = self
        engineURLField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pane.addSubview(engineURLField)

        enginePreviewLabel.frame = NSRect(x: formX, y: 146, width: formW, height: 90)
        enginePreviewLabel.textColor = .secondaryLabelColor
        enginePreviewLabel.font = .systemFont(ofSize: 11)
        enginePreviewLabel.lineBreakMode = .byWordWrapping
        enginePreviewLabel.maximumNumberOfLines = 6
        pane.addSubview(enginePreviewLabel)

        let listScroll = makeListScroll(for: engineTable)
        pane.addSubview(listScroll)
        pane.layoutBlock = { size in
            listScroll.frame = NSRect(x: 16, y: 16, width: SettingsWindowController.listWidth, height: max(80, size.height - 72))
            addButton.frame = NSRect(x: 16, y: size.height - 44, width: 44, height: 26)
            self.removeEngineButton.frame = NSRect(x: 66, y: size.height - 44, width: 44, height: 26)
        }
        pane.layoutBlock?(pane.bounds.size)

        return pane
    }

    private func buildGeneralPane() -> NSView {
        let pane = SettingsPane(frame: NSRect(origin: .zero, size: SettingsWindowController.paneSize))
        let formX = SettingsWindowController.formX
        let formW = SettingsWindowController.formWidth

        pane.addSubview(label("全局热键（点击方框后按下想要的组合，Esc 取消）", x: formX, y: 16, width: formW))

        hotKeyRecorder.frame = NSRect(x: formX, y: 38, width: 260, height: 34)
        hotKeyRecorder.setSpec(recordedHotKey)
        hotKeyRecorder.onCapture = { [weak self] spec in
            guard let self = self else { return }
            self.recordedHotKey = spec
            self.markDirty()
            self.refreshHotKeyNote()
        }
        // Carbon consumes a registered combination before any view can see it, so the running
        // hotkey has to step aside while a new one is being recorded.
        hotKeyRecorder.onRecordingChanged = { recording in
            if recording {
                HotKeyManager.shared.suspend()
            } else {
                HotKeyManager.shared.resume()
            }
        }
        pane.addSubview(hotKeyRecorder)

        let resetButton = NSButton(title: "恢复默认", target: self, action: #selector(resetHotKey))
        resetButton.frame = NSRect(x: formX + 270, y: 41, width: 96, height: 28)
        resetButton.bezelStyle = .rounded
        pane.addSubview(resetButton)

        hotKeyNoteLabel.frame = NSRect(x: formX, y: 80, width: formW, height: 34)
        hotKeyNoteLabel.font = .systemFont(ofSize: 11)
        hotKeyNoteLabel.textColor = .secondaryLabelColor
        hotKeyNoteLabel.lineBreakMode = .byWordWrapping
        hotKeyNoteLabel.maximumNumberOfLines = 3
        pane.addSubview(hotKeyNoteLabel)

        dockCheckbox.target = self
        dockCheckbox.action = #selector(toggleDock)
        dockCheckbox.frame = NSRect(x: formX, y: 132, width: formW, height: 20)
        pane.addSubview(dockCheckbox)
        pane.addSubview(label("菜单栏图标在有刘海的屏幕上可能被系统隐藏，Dock 图标是更可靠的入口。",
                             x: formX, y: 156, width: formW))

        pane.addSubview(label("面板最多显示的结果数", x: formX, y: 198, width: 200))
        maxResultsLabel.frame = NSRect(x: formX + 210, y: 196, width: 60, height: 18)
        maxResultsLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        pane.addSubview(maxResultsLabel)
        maxResultsStepper.minValue = 6
        maxResultsStepper.maxValue = 30
        maxResultsStepper.increment = 1
        maxResultsStepper.valueWraps = false
        maxResultsStepper.target = self
        maxResultsStepper.action = #selector(maxResultsChanged)
        maxResultsStepper.frame = NSRect(x: formX + 262, y: 192, width: 19, height: 24)
        pane.addSubview(maxResultsStepper)

        pane.addSubview(label("改动保存后立即生效，无需重启（热键除外：热键会当场重新注册）。",
                             x: formX, y: 240, width: formW))

        return pane
    }

    private func buildScopePane() -> NSView {
        let pane = SettingsPane(frame: NSRect(origin: .zero, size: SettingsWindowController.paneSize))
        let formX = SettingsWindowController.formX
        let formW = SettingsWindowController.formWidth

        homeCheckbox.target = self
        homeCheckbox.action = #selector(toggleHomeFolder)
        homeCheckbox.frame = NSRect(x: formX, y: 16, width: formW, height: 20)
        pane.addSubview(homeCheckbox)

        pane.addSubview(label("额外目录（外置卷、其他盘、协作目录等）", x: formX, y: 48, width: formW))

        scopeTable.addTableColumn(makeColumn(width: SettingsWindowController.listWidth))
        scopeTable.headerView = nil
        scopeTable.rowHeight = 26
        scopeTable.dataSource = self
        scopeTable.delegate = self
        let scrollView = NSScrollView(frame: NSRect(x: formX, y: 68, width: formW, height: 150))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = scopeTable
        pane.addSubview(scrollView)

        let addButton = NSButton(title: "添加目录…", target: self, action: #selector(addScopeFolder))
        addButton.frame = NSRect(x: formX, y: 226, width: 110, height: 28)
        addButton.bezelStyle = .rounded
        pane.addSubview(addButton)

        removeScopeButton.title = "移除"
        removeScopeButton.target = self
        removeScopeButton.action = #selector(removeScopeFolder)
        removeScopeButton.frame = NSRect(x: formX + 118, y: 226, width: 80, height: 28)
        removeScopeButton.bezelStyle = .rounded
        pane.addSubview(removeScopeButton)

        let effectiveLabel = label("实际生效的范围（被上级目录覆盖的项会自动跳过）", x: formX, y: 268, width: formW)
        pane.addSubview(effectiveLabel)

        scopeHelpLabel.frame = NSRect(x: formX, y: 288, width: formW, height: 150)
        scopeHelpLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        scopeHelpLabel.textColor = .secondaryLabelColor
        scopeHelpLabel.lineBreakMode = .byWordWrapping
        scopeHelpLabel.maximumNumberOfLines = 12
        pane.addSubview(scopeHelpLabel)

        pane.layoutBlock = { size in
            let listHeight = max(70, size.height - 68 - 200)
            scrollView.frame = NSRect(x: formX, y: 68, width: formW, height: listHeight)
            addButton.frame = NSRect(x: formX, y: 76 + listHeight, width: 110, height: 28)
            self.removeScopeButton.frame = NSRect(x: formX + 118, y: 76 + listHeight, width: 80, height: 28)
            effectiveLabel.frame = NSRect(x: formX, y: 116 + listHeight, width: formW, height: 16)
            self.scopeHelpLabel.frame = NSRect(x: formX, y: 136 + listHeight,
                                          width: formW, height: max(40, size.height - 146 - listHeight))
        }
        pane.layoutBlock?(pane.bounds.size)

        return pane
    }

    private func makeColumn(width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cell"))
        column.width = width
        return column
    }

    private func makeListScroll(for table: NSTableView) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 16, width: SettingsWindowController.listWidth, height: 380))
        scrollView.autoresizingMask = [.height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = table
        return scrollView
    }

    private func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(x: x, y: y, width: width, height: 16)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }

    // MARK: - snippet list and form

    private func select(_ index: Int) {
        guard snippets.indices.contains(index) else { return }
        isProgrammaticSelection = true
        selectedIndex = index
        if let row = visibleSnippetIndices.firstIndex(of: index) {
            snippetTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        loadForm(snippets[index])
        isProgrammaticSelection = false
    }

    /// Rebuilds the visible snippet rows from the filter text. Matches keyword, name or
    /// content, because with a few dozen snippets scrolling to find one is the real cost.
    private func refreshSnippetFilter(selecting index: Int? = nil) {
        let needle = snippetFilterField.stringValue.trimmed().lowercased()
        if needle.isEmpty {
            visibleSnippetIndices = Array(snippets.indices)
        } else {
            visibleSnippetIndices = snippets.indices.filter { candidate in
                let snippet = snippets[candidate]
                return snippet.keyword.lowercased().contains(needle)
                    || snippet.name.lowercased().contains(needle)
                    || snippet.content.lowercased().contains(needle)
            }
        }
        snippetTable.reloadData()
        isProgrammaticSelection = true
        // Move the form in step with the highlight: the selection callback is suppressed
        // here, so nothing else would keep the two consistent.
        if let index = index, let row = visibleSnippetIndices.firstIndex(of: index) {
            snippetTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            selectedIndex = index
            loadForm(snippets[index])
        } else if !visibleSnippetIndices.isEmpty {
            let preferred = selectedIndex.flatMap { visibleSnippetIndices.firstIndex(of: $0) } ?? 0
            let mapped = visibleSnippetIndices[preferred]
            snippetTable.selectRowIndexes(IndexSet(integer: preferred), byExtendingSelection: false)
            selectedIndex = mapped
            loadForm(snippets[mapped])
        } else {
            selectedIndex = nil
            loadForm(nil)
        }
        isProgrammaticSelection = false
        updateFormEnabled()
    }

    private func loadForm(_ snippet: Snippet?) {
        formIndex = snippet == nil ? nil : selectedIndex
        keywordField.stringValue = snippet?.keyword ?? ""
        nameField.stringValue = snippet?.name ?? ""
        contentTextView.string = snippet?.content ?? ""
        updateFormEnabled()
        refreshPreview()
    }

    private func updateFormEnabled() {
        let hasSelection = selectedIndex != nil
        keywordField.isEnabled = hasSelection
        nameField.isEnabled = hasSelection
        contentTextView.isEditable = hasSelection
        removeSnippetButton.isEnabled = hasSelection
    }

    private func refreshPreview() {
        guard selectedIndex != nil else {
            previewLabel.stringValue = "← 选择或新建一个片段"
            return
        }
        let (text, backoff) = Snippet.cursorSplit(contentTextView.string)
        let rendered = text
            .replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\t", with: "⇥")
        let caret = backoff > 0 ? "  ·  光标回退 \(backoff) 字符" : ""
        var prefix = ""
        if let first = keywordField.stringValue.first, first.isLetter || first.isNumber {
            prefix = "⚠️ 关键词不以符号开头，不会自动展开；"
        }
        previewLabel.stringValue = "\(prefix)展开为「\(rendered)」\(caret)"
    }

    private func markDirty() {
        dirty = true
        statusLabel.stringValue = "有未保存的修改"
    }

    /// Writes the edited fields of the selected snippet back into the in-memory list.
    private func commitFields() {
        guard let index = formIndex, snippets.indices.contains(index) else { return }
        snippets[index] = Snippet(keyword: keywordField.stringValue.trimmed(),
                                  name: nameField.stringValue,
                                  content: contentTextView.string)
        refreshPreview()
    }

    @objc private func addSnippet() {
        commitFields()
        snippets.append(Snippet(keyword: ";new", name: "新片段", content: ""))
        markDirty()
        snippetFilterField.stringValue = ""      // a new row may not match the current filter
        refreshSnippetFilter(selecting: snippets.count - 1)
        select(snippets.count - 1)
        window.makeFirstResponder(keywordField)
    }

    @objc private func removeSnippet() {
        guard let index = selectedIndex, snippets.indices.contains(index) else { return }
        let snippet = snippets[index]
        let alert = NSAlert()
        alert.messageText = "删除片段「\(snippet.name.isEmpty ? snippet.keyword : snippet.name)」？"
        alert.informativeText = "保存后生效；未保存前可以用「放弃修改」撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        snippets.remove(at: index)
        markDirty()
        selectedIndex = snippets.isEmpty ? nil : min(index, snippets.count - 1)
        refreshSnippetFilter(selecting: selectedIndex)
        if snippets.isEmpty {
            selectedIndex = nil
            loadForm(nil)
        } else {
            select(min(index, snippets.count - 1))
        }
    }

    @objc private func toggleExpansion() {
        config.autoExpandSnippets = (expandCheckbox.state == .on)
        markDirty()
    }

    // MARK: - engine list and form

    private func selectEngine(_ index: Int) {
        guard engines.indices.contains(index) else { return }
        selectedEngineIndex = index
        engineTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        loadEngineForm(engines[index])
    }

    private func loadEngineForm(_ engine: SearchEngine?) {
        engineFormIndex = engine == nil ? nil : selectedEngineIndex
        engineKeywordField.stringValue = engine?.keyword ?? ""
        engineNameField.stringValue = engine?.name ?? ""
        engineURLField.stringValue = engine?.urlTemplate ?? ""
        updateEngineFormEnabled()
        refreshEnginePreview()
    }

    private func updateEngineFormEnabled() {
        let hasSelection = selectedEngineIndex != nil
        engineKeywordField.isEnabled = hasSelection
        engineNameField.isEnabled = hasSelection
        engineURLField.isEnabled = hasSelection
        removeEngineButton.isEnabled = hasSelection
    }

    private func refreshEnginePreview() {
        guard selectedEngineIndex != nil else {
            enginePreviewLabel.stringValue = "← 选择或新建一个搜索引擎"
            return
        }
        let template = engineURLField.stringValue
        var notes: [String] = []
        if !template.lowercased().hasPrefix("http") {
            notes.append("⚠️ URL 不像 http(s) 链接")
        }
        // The two modes are a property of the template, so say which one this engine is.
        let mode: String
        let sample: String
        if template.contains("{query}") {
            mode = "搜索模式：面板输入「\(engineKeywordField.stringValue) 关键词」才会搜索"
            sample = template.replacingOccurrences(of: "{query}", with: "test%20query")
        } else {
            mode = "直达模式：面板输入「\(engineKeywordField.stringValue)」直接打开该网页"
            sample = template
        }
        enginePreviewLabel.stringValue = (notes + [mode, "示例：\(sample)"]).joined(separator: "\n")
    }

    /// Writes the edited fields of the selected engine back into the in-memory list.
    private func commitEngineFields() {
        guard let index = engineFormIndex, engines.indices.contains(index) else { return }
        engines[index] = SearchEngine(keyword: engineKeywordField.stringValue.trimmed(),
                                      name: engineNameField.stringValue,
                                      urlTemplate: engineURLField.stringValue.trimmed())
        refreshEnginePreview()
    }

    @objc private func addEngine() {
        commitEngineFields()
        engines.append(SearchEngine(keyword: "x", name: "新引擎",
                                    urlTemplate: "https://example.com/search?q={query}"))
        markDirty()
        engineTable.reloadData()
        selectEngine(engines.count - 1)
        window.makeFirstResponder(engineKeywordField)
    }

    @objc private func removeEngine() {
        guard let index = selectedEngineIndex, engines.indices.contains(index) else { return }
        let engine = engines[index]
        let alert = NSAlert()
        alert.messageText = "删除搜索引擎「\(engine.name.isEmpty ? engine.keyword : engine.name)」？"
        alert.informativeText = "保存后生效；未保存前可以用「放弃修改」撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        engines.remove(at: index)
        markDirty()
        engineTable.reloadData()
        if engines.isEmpty {
            selectedEngineIndex = nil
            loadEngineForm(nil)
        } else {
            selectEngine(min(index, engines.count - 1))
        }
    }

    // MARK: - general

    @objc private func resetHotKey() {
        recordedHotKey = "option+space"
        hotKeyRecorder.setSpec(recordedHotKey)
        markDirty()
        refreshHotKeyNote()
    }

    @objc private func toggleDock() {
        markDirty()
    }

    @objc private func maxResultsChanged() {
        recordedMaxResults = maxResultsStepper.integerValue
        maxResultsLabel.stringValue = "\(recordedMaxResults)"
        markDirty()
    }

    private func refreshHotKeyNote() {
        var notes = ["当前：\(HotKey.display(spec: recordedHotKey))"]
        if let warning = HotKey.conflictWarning(spec: recordedHotKey) {
            notes.append("⚠️ \(warning)")
        }
        hotKeyNoteLabel.stringValue = notes.joined(separator: "　·　")
    }

    // MARK: - search scope

    @objc private func toggleHomeFolder() {
        markDirty()
        refreshScopeHelp()
    }

    @objc private func addScopeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.prompt = "添加"
        panel.message = "选择要纳入搜索的目录（可多选）"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.path
            guard !scopeFolders.contains(where: { $0.expandedPath == path }) else { continue }
            scopeFolders.append(path)
        }
        markDirty()
        scopeTable.reloadData()
        refreshScopeHelp()
        if !scopeFolders.isEmpty {
            selectedScopeIndex = scopeFolders.count - 1
            scopeTable.selectRowIndexes(IndexSet(integer: scopeFolders.count - 1), byExtendingSelection: false)
        }
    }

    @objc private func removeScopeFolder() {
        guard let index = selectedScopeIndex, scopeFolders.indices.contains(index) else { return }
        scopeFolders.remove(at: index)
        markDirty()
        scopeTable.reloadData()
        selectedScopeIndex = scopeFolders.isEmpty ? nil : min(index, scopeFolders.count - 1)
        refreshScopeHelp()
    }

    /// Shows what will actually be searched, including which entries the parent scope makes
    /// redundant — silently ignoring a folder the user just added would be worse than saying so.
    private func refreshScopeHelp() {
        var preview = config
        preview.searchFolders = scopeFolders
        preview.searchHomeFolder = homeCheckbox.state == .on
        let effective = preview.effectiveSearchFolders
        let home = NSHomeDirectory()

        var lines: [String] = []
        for folder in effective {
            let note = folder == home ? "   （整个家目录）" : ""
            lines.append("✓ \(SettingsWindowController.abbreviate(folder))\(note)")
        }
        for folder in scopeFolders where !effective.contains(folder.expandedPath) {
            lines.append("· \(SettingsWindowController.abbreviate(folder.expandedPath))   （已被上级目录覆盖，跳过）")
        }
        for folder in scopeFolders where !FileManager.default.fileExists(atPath: folder.expandedPath) {
            lines.append("⚠️ \(SettingsWindowController.abbreviate(folder.expandedPath))   （路径不存在）")
        }
        if effective.contains("/") {
            lines.append("⚠️ 范围包含整个磁盘，搜索会明显变慢")
        }
        lines.append("")
        lines.append("按文件名匹配，忽略大小写与变音符号；缓存、容器、node_modules 等已自动排除。")
        scopeHelpLabel.stringValue = lines.joined(separator: "\n")
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: - save / revert

    @objc private func revert() {
        reloadFromConfig(Config.load())
        statusLabel.stringValue = "已放弃修改"
    }

    @objc private func save() {
        commitFields()
        commitEngineFields()

        // Scope validation: an empty scope would silently find no files at all.
        var uniqueScopes: [String] = []
        for folder in scopeFolders.map({ $0.expandedPath }) where !uniqueScopes.contains(folder) {
            uniqueScopes.append(folder)
        }
        scopeFolders = uniqueScopes
        let searchHome = homeCheckbox.state == .on
        if scopeFolders.isEmpty && !searchHome {
            statusLabel.stringValue = "保存失败：搜索范围为空，将搜不到任何文件"
            NSSound.beep()
            return
        }

        var seen = Set<String>()
        var duplicates: [String] = []
        for snippet in snippets {
            let key = snippet.keyword.lowercased()
            if key.isEmpty { continue }
            if !seen.insert(key).inserted { duplicates.append(snippet.keyword) }
        }
        if !duplicates.isEmpty {
            statusLabel.stringValue = "保存失败：片段关键词重复 \(Set(duplicates).sorted().joined(separator: ", "))"
            NSSound.beep()
            return
        }
        let emptySnippetKeywords = snippets.filter { $0.keyword.trimmed().isEmpty }.count
        if emptySnippetKeywords > 0 {
            statusLabel.stringValue = "保存失败：有 \(emptySnippetKeywords) 个片段缺少关键词"
            NSSound.beep()
            return
        }
        var seenEngines = Set<String>()
        var duplicateEngines: [String] = []
        for engine in engines {
            let key = engine.keyword.lowercased()
            if key.isEmpty { continue }
            if !seenEngines.insert(key).inserted { duplicateEngines.append(engine.keyword) }
        }
        if !duplicateEngines.isEmpty {
            statusLabel.stringValue = "保存失败：引擎关键词重复 \(Set(duplicateEngines).sorted().joined(separator: ", "))"
            NSSound.beep()
            return
        }
        let brokenEngines = engines.filter { $0.keyword.trimmed().isEmpty || $0.urlTemplate.trimmed().isEmpty }
        if !brokenEngines.isEmpty {
            statusLabel.stringValue = "保存失败：有 \(brokenEngines.count) 个引擎缺少关键词或 URL"
            NSSound.beep()
            return
        }

        guard HotKey.parse(spec: recordedHotKey) != nil else {
            statusLabel.stringValue = "保存失败：热键无效（必须包含至少一个修饰键）"
            NSSound.beep()
            return
        }

        config.snippets = snippets
        config.engines = engines
        config.searchFolders = scopeFolders
        config.searchHomeFolder = searchHome
        config.hotKey = recordedHotKey
        config.showInDock = (dockCheckbox.state == .on)
        config.maxResults = max(1, recordedMaxResults)
        config.autoExpandSnippets = (expandCheckbox.state == .on)
        Config.write(config, to: AppPaths.localConfigURL)
        Config.mirrorToShared(config)
        dirty = false
        let summary = "已保存 \(snippets.count) 个片段、\(engines.count) 个引擎、"
            + "\(config.effectiveSearchFolders.count) 个搜索范围"
        Log.write("settings saved: \(snippets.count) snippets, \(engines.count) engines, "
                  + "scopes=\(config.effectiveSearchFolders.joined(separator: " ")), "
                  + "hotkey=\(config.hotKey), maxResults=\(config.maxResults), "
                  + "showInDock=\(config.showInDock), autoExpand=\(config.autoExpandSnippets)")
        // A hotkey another application already owns is reported here rather than silently
        // leaving the user with a shortcut that does nothing.
        statusLabel.stringValue = onSave?(config) ?? summary
    }
}

// MARK: - window

extension SettingsWindowController: NSWindowDelegate {
    /// Closing with unsaved edits used to discard them silently.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "有未保存的修改"
        alert.informativeText = "关闭窗口会丢弃这些修改（片段、引擎、搜索范围、热键）。"
        alert.addButton(withTitle: "关闭并丢弃")
        alert.addButton(withTitle: "返回编辑")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - tables

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === engineTable { return engines.count }
        if tableView === scopeTable { return scopeFolders.count }
        return visibleSnippetIndices.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 4, y: 0, width: SettingsWindowController.listWidth - 8, height: 20)

        if tableView === scopeTable {
            guard scopeFolders.indices.contains(row) else { return label }
            let folder = scopeFolders[row]
            let display = SettingsWindowController.abbreviate(folder.expandedPath)
            let exists = FileManager.default.fileExists(atPath: folder.expandedPath)
            label.stringValue = exists ? display : "\(display)   ⚠️ 不存在"
            return label
        }
        if tableView === engineTable {
            guard engines.indices.contains(row) else { return label }
            let engine = engines[row]
            label.stringValue = engine.name.isEmpty ? engine.keyword : "\(engine.keyword)   \(engine.name)"
            return label
        }
        guard visibleSnippetIndices.indices.contains(row) else { return label }
        let snippet = snippets[visibleSnippetIndices[row]]
        label.stringValue = snippet.name.isEmpty ? snippet.keyword : "\(snippet.keyword)   \(snippet.name)"
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let table = notification.object as? NSTableView
        if table === scopeTable {
            selectedScopeIndex = scopeTable.selectedRow >= 0 ? scopeTable.selectedRow : nil
            return
        }
        let isEngineTable = table === engineTable
        let row = isEngineTable ? engineTable.selectedRow : snippetTable.selectedRow
        guard row >= 0 else { return }

        if isEngineTable {
            guard engines.indices.contains(row) else { return }
            commitEngineFields()
            selectedEngineIndex = row
            loadEngineForm(engines[row])
        } else {
            guard !isProgrammaticSelection else { return }
            guard visibleSnippetIndices.indices.contains(row) else { return }
            commitFields()                      // writes to the snippet the form came from
            let index = visibleSnippetIndices[row]
            guard snippets.indices.contains(index) else { return }
            selectedIndex = index
            loadForm(snippets[index])
        }
    }
}

// MARK: - text editing

extension SettingsWindowController: NSTextFieldDelegate, NSTextViewDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === snippetFilterField {
            refreshSnippetFilter()
            return                      // filtering the view is not a config change
        }
        if field === engineKeywordField || field === engineNameField || field === engineURLField {
            commitEngineFields()
            engineTable.reloadData()
        } else {
            commitFields()
            snippetTable.reloadData()
        }
        markDirty()
    }

    func textDidChange(_ notification: Notification) {
        commitFields()
        markDirty()
    }
}
