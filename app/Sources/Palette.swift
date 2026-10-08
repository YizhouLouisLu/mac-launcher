import AppKit

/// `NSRunningApplication.activate()` replaced the older options API in macOS 14.
private func activate(_ app: NSRunningApplication) {
    if #available(macOS 14.0, *) {
        app.activate()
    } else {
        app.activate(options: [.activateIgnoringOtherApps])
    }
}

final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Flipped container so layout code reads top-down.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Inset, rounded selection instead of AppKit's full-width bar.
final class PaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 8, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        (isEmphasized ? NSColor.controlAccentColor.withAlphaComponent(0.92)
                      : NSColor.controlAccentColor.withAlphaComponent(0.22)).setFill()
        path.fill()
    }
}

final class ResultCell: NSTableCellView {
    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    /// Right-aligned type hint (应用 / 文件 / 片段 / 命令 / 网页).
    let kindLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .systemFont(ofSize: 14.5, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11.5)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        kindLabel.font = .systemFont(ofSize: 10, weight: .medium)
        kindLabel.alignment = .right
        kindLabel.lineBreakMode = .byTruncatingTail
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(kindLabel)
        textField = titleLabel
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let height = bounds.height
        let iconSide: CGFloat = 30
        iconView.frame = NSRect(x: 16, y: (height - iconSide) / 2, width: iconSide, height: iconSide)
        let textX = iconView.frame.maxX + 13
        let badgeWidth: CGFloat = 46
        let badgeX = bounds.width - 16 - badgeWidth
        let width = max(0, badgeX - textX - 10)
        titleLabel.frame = NSRect(x: textX, y: height / 2 + 1, width: width, height: 18)
        subtitleLabel.frame = NSRect(x: textX, y: height / 2 - 16, width: width, height: 14)
        kindLabel.frame = NSRect(x: badgeX, y: (height - 13) / 2, width: badgeWidth, height: 13)
    }

    func configure(with item: Item, icon: NSImage?, kindText: String) {
        titleLabel.stringValue = item.title
        var detail = item.subtitle
        if item.running != nil { detail = "运行中 · " + detail }
        subtitleLabel.stringValue = detail
        iconView.image = icon
        kindLabel.stringValue = kindText
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    private func updateColors() {
        let emphasized = backgroundStyle == .emphasized
        titleLabel.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        subtitleLabel.textColor = emphasized
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.85)
            : NSColor.secondaryLabelColor
        kindLabel.textColor = emphasized
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.7)
            : NSColor.tertiaryLabelColor
    }
}

/// The Alfred-style palette: one search field above a result table.
///
/// Results are painted twice on purpose: applications come from the in-memory index
/// instantly, then Spotlight file hits are merged in when they arrive (~150–300 ms).
final class PaletteController: NSObject {
    static let panelWidth: CGFloat = 680
    static let fieldHeight: CGFloat = 58
    static let rowHeight: CGFloat = 46
    static let footerHeight: CGFloat = 26
    /// How long after borrowing the clipboard for a snippet we hand it back: long enough for
    /// the target application to service the Cmd+V, short enough that the user does not notice.
    static let clipboardRestoreDelay: TimeInterval = 0.4

    /// Height of the dictionary gloss strip under the search field, when shown.
    static let glossHeight: CGFloat = 34
    static let cornerRadius: CGFloat = 14
    static let maxVisibleRows = 8
    static let fileSearchDebounce = 0.15

    private let indexer: Indexer
    private let searcher = SpotlightSearcher()
    var config: Config
    /// Handles `.command` rows; set by the app delegate.
    var onCommand: ((String) -> Void)?

    /// The app to paste into. `previousApp` is what was frontmost when the palette
    /// opened; `lastOtherApp` tracks the most recent *other* app via workspace
    /// notifications, which is what makes the Dock-icon entry point work (clicking the
    /// Dock icon makes this process frontmost, so there is no "previous" app to read).
    private var lastOtherApp: NSRunningApplication?

    private let panel: PalettePanel
    private let effectView = NSVisualEffectView()
    private let content = FlippedView()
    private let searchIcon = NSImageView()
    private let separator = NSBox()
    private let emptyLabel = NSTextField(labelWithString: "没有匹配的结果")
    private let glossStrip = FlippedView()
    private let glossWordLabel = NSTextField(labelWithString: "")
    private let glossBodyLabel = NSTextField(labelWithString: "")
    private var glossVisible = false
    /// Stock rows live apart from the app/file results so the async refresh can
    /// replace them without disturbing the merged list underneath.
    private var stockItems: [Item] = []
    private var stockSearchGeneration = 0
    /// True while Up/Down are stepping through query history instead of rows.
    private var browsingHistory = false
    private let footerLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "↑↓ 选择   ↵ 打开   ⎋ 关闭")
    private let searchField = NSTextField()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var results: [Item] = []
    private var appResults: [Item] = []
    private var pendingQuery: String?
    private var lastSearchedQuery: String?
    private var previousApp: NSRunningApplication?
    private var iconCache: [String: NSImage] = [:]

    init(indexer: Indexer, config: Config) {
        self.indexer = indexer
        self.config = config
        self.panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: PaletteController.panelWidth, height: PaletteController.fieldHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        // Clicking anywhere outside the palette (another app, the desktop, the menu bar)
        // makes the panel resign key; that is the signal to dismiss it. Until now the only
        // way out was Esc.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(panelDidResignKey),
                                               name: NSWindow.didResignKeyNotification,
                                               object: panel)
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                         selector: #selector(applicationDidActivate(_:)),
                                                         name: NSWorkspace.didActivateApplicationNotification,
                                                         object: nil)
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastOtherApp = app
        }
    }

    @objc private func panelDidResignKey() {
        guard panel.isVisible else { return }
        Log.write("palette resigned key (focus moved elsewhere) -> hiding")
        hide(restoringFocus: false)
    }

    /// Regression check for the dismiss-on-click-elsewhere path: `resignKey()` first, and if
    /// AppKit does not post the notification in this synthetic setting, the notification is
    /// posted directly so at least the observer wiring is covered.
    func selfTestResignKey() -> (resigned: Bool, notified: Bool, hidden: Bool) {
        show()
        guard panel.isVisible else { return (false, false, false) }
        panel.resignKey()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        if !panel.isVisible { return (true, true, true) }

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        return (true, false, !panel.isVisible)
    }

    // MARK: - setup

    private func configurePanel() {
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Translucent and rounded: the window itself is transparent, so all that shows is
        // the material with its rounded corners and hairline border.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false

        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = PaletteController.cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 1
        effectView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        panel.contentView = effectView

        content.frame = NSRect(x: 0, y: 0, width: PaletteController.panelWidth, height: PaletteController.fieldHeight)
        content.autoresizingMask = [.width, .height]
        effectView.addSubview(content)

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.imageScaling = .scaleProportionallyDown
        content.addSubview(searchIcon)

        searchField.font = .systemFont(ofSize: 21)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.placeholderString = "搜索应用、文件、片段、引擎…"
        searchField.delegate = self
        searchField.cell?.usesSingleLineMode = true
        content.addSubview(searchField)

        separator.boxType = .separator
        content.addSubview(separator)

        // Brief gloss under the search field: shown while a single English word is typed.
        glossStrip.isHidden = true
        glossWordLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        glossWordLabel.lineBreakMode = .byTruncatingTail
        glossBodyLabel.font = .systemFont(ofSize: 12)
        glossBodyLabel.textColor = .secondaryLabelColor
        glossBodyLabel.lineBreakMode = .byTruncatingTail
        glossStrip.addSubview(glossWordLabel)
        glossStrip.addSubview(glossBodyLabel)
        content.addSubview(glossStrip)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = PaletteController.panelWidth
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = PaletteController.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        scrollView.frame = NSRect(x: 0, y: PaletteController.fieldHeight, width: PaletteController.panelWidth, height: 0)
        scrollView.autoresizingMask = [.width]
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = tableView
        content.addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        content.addSubview(emptyLabel)

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .tertiaryLabelColor
        content.addSubview(footerLabel)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .right
        content.addSubview(hintLabel)
    }

    // MARK: - show / hide

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible {
            hide(restoringFocus: true)
        } else {
            show()
        }
    }

    func show() {
        let current = NSWorkspace.shared.frontmostApplication
        if let current = current, current.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = current
            lastOtherApp = current
        } else {
            // Opened from the Dock or reopened while already active: fall back to the last
            // app that was activated before us.
            previousApp = lastOtherApp
        }
        searchField.stringValue = ""
        browsingHistory = false
        QueryHistory.shared.stopBrowsing()
        pendingQuery = nil
        lastSearchedQuery = nil
        // Re-overlay live running state: an app started after our launch is otherwise
        // never marked running, and quit mode only lists running applications.
        indexer.refreshRunningState()
        reloadResults()
        positionOnActiveScreen()

        // Verified recipe from the spike: an accessory app must still be activated,
        // otherwise the non-activating panel loses key status after ~150 ms.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)

        Log.write("palette shown: previous=\(previousApp?.localizedName ?? "nil") rows=\(results.count) key=\(panel.isKeyWindow)")
    }

    func hide(restoringFocus: Bool) {
        panel.orderOut(nil)
        pendingQuery = nil
        if restoringFocus, let previous = previousApp, !previous.isTerminated {
            if #available(macOS 14.0, *) {
                previous.activate()
            } else {
                previous.activate(options: [.activateIgnoringOtherApps])
            }
        }
        previousApp = nil
        Log.write("palette hidden (restoreFocus=\(restoringFocus))")
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.maxY - size.height - visible.height * 0.18))
    }

    private func updatePanelSize() {
        let rows = max(1, min(results.count, PaletteController.maxVisibleRows))
        let gloss = glossVisible ? PaletteController.glossHeight : 0
        let height = PaletteController.fieldHeight
            + gloss
            + CGFloat(rows) * PaletteController.rowHeight
            + PaletteController.footerHeight
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: PaletteController.panelWidth, height: height)
        frame.origin.y = top - height
        panel.setFrame(frame, display: true)

        let width = PaletteController.panelWidth
        let fieldHeight = PaletteController.fieldHeight
        // Set the container frame explicitly: relying on the autoresizing mask left it at
        // its old height, so everything below the field was clipped away.
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        searchIcon.frame = NSRect(x: 20, y: (fieldHeight - 22) / 2, width: 22, height: 22)
        searchField.frame = NSRect(x: 50, y: (fieldHeight - 28) / 2, width: width - 70, height: 28)
        separator.frame = NSRect(x: 0, y: fieldHeight + gloss - 1, width: width, height: 1)
        glossStrip.frame = NSRect(x: 0, y: fieldHeight, width: width, height: gloss)
        // Strip-local coordinates: using the panel's y here pushed the labels down into the
        // first result row (caught by the offscreen render, not by reading the code).
        glossWordLabel.frame = NSRect(x: 20, y: (gloss - 20) / 2, width: 150, height: 20)
        glossBodyLabel.frame = NSRect(x: 178, y: (gloss - 18) / 2, width: width - 198, height: 18)
        let listHeight = CGFloat(rows) * PaletteController.rowHeight
        scrollView.frame = NSRect(x: 0, y: fieldHeight + gloss, width: width, height: listHeight)
        emptyLabel.frame = NSRect(x: 0, y: fieldHeight + gloss + listHeight / 2 - 9, width: width, height: 18)
        footerLabel.frame = NSRect(x: 18, y: height - PaletteController.footerHeight + 6, width: width / 2, height: 14)
        hintLabel.frame = NSRect(x: width / 2, y: height - PaletteController.footerHeight + 6, width: width / 2 - 18, height: 14)
        tableView.tableColumns.first?.width = width
    }

    // MARK: - offscreen rendering (UI review)

    /// Renders the panel to a PNG so the layout can be reviewed without Screen Recording
    /// permission. The material itself cannot be reproduced offscreen (there is nothing
    /// behind the window to blur), so the backing is made opaque for the shot only.
    func renderToPNG(path: String, query: String, appearanceName: NSAppearance.Name) {
        // The field editor, when active, is the source of truth for the displayed text, so
        // the query goes through it; setting only the control's value left it blank.
        if let editor = searchField.currentEditor() as? NSTextView {
            editor.string = query
            editor.selectedRange = NSRange(location: (query as NSString).length, length: 0)
        } else {
            searchField.stringValue = query
        }
        reloadResults()
        updatePanelSize()
        content.layoutSubtreeIfNeeded()

        effectView.blendingMode = .withinWindow
        effectView.material = .hudWindow
        panel.appearance = NSAppearance(named: appearanceName)
        effectView.appearance = NSAppearance(named: appearanceName)
        content.appearance = NSAppearance(named: appearanceName)
        // No layer-backed backdrop here: with a layer background on the container the
        // top-level labels (search text, footer) were not drawn by cacheDisplay, which made
        // the review shots lie. The PNG keeps transparency and is composited for viewing.
        content.wantsLayer = false
        content.layer?.backgroundColor = nil
        content.layoutSubtreeIfNeeded()

        // Render the inner container rather than the effect view: drawing through the
        // material view skipped its own subviews (search text, footer), so the shots lied.
        let view: NSView = content
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(view.bounds.width * scale),
                                         pixelsHigh: Int(view.bounds.height * scale),
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return }
        rep.size = view.bounds.size
        // A real display pass rather than cacheDisplay: the latter skipped the container's
        // own labels (search text, footer), which made the review shots untrustworthy.
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            view.displayIgnoringOpacity(view.bounds, in: context)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        Log.write("rendered palette \(Int(view.bounds.width))x\(Int(view.bounds.height)) to \(path) "
                  + "[content=\(Int(content.bounds.width))x\(Int(content.bounds.height)) "
                  + "rows=\(results.count) emptyHidden=\(emptyLabel.isHidden) "
                  + "scroll=\(Int(scrollView.frame.height)) footerY=\(Int(footerLabel.frame.minY))]")
    }

    // MARK: - results

    private func reloadResults() {
        let query = searchField.stringValue
        refreshGloss(for: query)
        appResults = indexer.searchApps(rawQuery: query, config: config)
        stockItems = cachedStockItems(for: query)
        results = withStocks(appResults)
        refreshTable()
        scheduleFileSearch(for: query)
        scheduleStockSearch(for: query)
    }

    /// Stock rows sit under the top action row (a web search the user asked for), never above it.
    private func withStocks(_ base: [Item]) -> [Item] {
        guard !stockItems.isEmpty else { return base }
        var result = base
        let keepOnTop = base.prefix { $0.kind == .webSearch }.count
        result.insert(contentsOf: stockItems, at: min(keepOnTop, result.count))
        return result
    }

    /// Cache-only stock rows: the main thread must never wait on the network, so this shows
    /// what is already known and the background refresh corrects it a moment later.
    private func cachedStockItems(for query: String) -> [Item] {
        guard let term = Indexer.stockQuery(for: query) else { return [] }
        guard !term.isEmpty else { return [Indexer.watchlistItem(count: config.stockWatchlist.count)] }
        guard let hits = StockSearch.cachedSuggest(term), !hits.isEmpty else { return [] }
        let quotes = StockQuotes.cached(hits.map { $0.code }, maxAge: 30)
        return Indexer.stockItems(hits: hits, quotes: quotes)
    }

    /// Debounced background lookup: suggest (to resolve names/pinyin/codes) then one batch
    /// quote request for the prices shown in the dropdown.
    private func scheduleStockSearch(for query: String) {
        guard let term = Indexer.stockQuery(for: query) else {
            if !stockItems.isEmpty { stockItems = [] }
            return
        }
        stockSearchGeneration += 1
        let generation = stockSearchGeneration
        guard !term.isEmpty else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + PaletteController.fileSearchDebounce) { [weak self] in
            guard let self = self, self.stockSearchGeneration == generation else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let hits = StockSearch.suggest(term)
                let quotes = StockQuotes.fetch(hits.map { $0.code })
                let items = Indexer.stockItems(hits: hits, quotes: quotes)
                DispatchQueue.main.async {
                    // `self` is already unwrapped by the outer guard; rebinding it here would
                    // be a conditional binding on a non-optional (compiler error).
                    guard self.stockSearchGeneration == generation,
                          Indexer.stockQuery(for: self.searchField.stringValue) == term else { return }
                    self.stockItems = items
                    self.results = self.withStocks(self.appResults)
                    self.refreshTable()
                    Log.write("stock search \"\(term)\": \(hits.count) hits, \(quotes.count) quotes")
                }
            }
        }
    }

    /// Spotlight is a separate process (~150–300 ms) so it is debounced and its results
    /// are dropped when the query moved on.
    private func scheduleFileSearch(for query: String) {
        let trimmed = query.trimmed()
        pendingQuery = trimmed.isEmpty ? nil : trimmed
        guard !trimmed.isEmpty, !Indexer.quitMode(for: trimmed) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + PaletteController.fileSearchDebounce) { [weak self] in
            guard let self = self, self.pendingQuery == trimmed else { return }
            // A later keystroke can schedule a second timer for the same text; only the
            // first one should spawn mdfind.
            guard self.lastSearchedQuery != trimmed else { return }
            self.lastSearchedQuery = trimmed
            self.searcher.search(query: trimmed,
                                 folders: self.config.effectiveSearchFolders,
                                 limit: Indexer.fileCandidateLimit) { [weak self] paths in
                // The searcher calls back on its own queue; UI work belongs on main.
                DispatchQueue.main.async {
                    guard let self = self, self.pendingQuery == trimmed else { return }
                    let merged = self.indexer.merge(rawQuery: trimmed,
                                                    apps: self.appResults,
                                                    filePaths: paths,
                                                    config: self.config)
                    self.results = self.withStocks(merged)
                    self.refreshTable()
                    Log.write("file search \"\(trimmed)\": \(paths.count) spotlight hits, \(merged.count) merged rows")
                }
            }
        }
    }

    /// Looks the query up in the system dictionary and shows the brief gloss. Cheap enough
    /// to run per keystroke (measured 2–3 ms) and silent when there is no entry.
    private func refreshGloss(for query: String) {
        let parsed = Indexer.parse(query)
        var entry: DictionaryEntry?
        if parsed.dictionaryPrefix, !parsed.query.isEmpty {
            entry = Dictionary.lookUp(parsed.query)
        } else if Dictionary.isCandidate(parsed.query) {
            entry = Dictionary.lookUp(parsed.query)
        }
        if let entry = entry {
            glossWordLabel.stringValue = entry.headword
            glossBodyLabel.stringValue = entry.phonetics.isEmpty
                ? entry.brief
                : "\(entry.phonetics)   ·   \(entry.brief)"
            glossStrip.isHidden = false
            glossVisible = true
        } else {
            glossWordLabel.stringValue = ""
            glossBodyLabel.stringValue = ""
            glossStrip.isHidden = true
            glossVisible = false
        }
    }

    private func refreshTable() {
        tableView.reloadData()
        emptyLabel.isHidden = !results.isEmpty
        var footer = results.isEmpty ? "" : "\(results.count) 个结果"
        if searchField.stringValue.trimmed().isEmpty, QueryHistory.shared.hasEntries {
            footer += footer.isEmpty ? "↑ 调出上一次查询" : "  ·  ↑ 调出上一次查询"
        }
        footerLabel.stringValue = footer
        if results.isEmpty {
            tableView.deselectAll(nil)
        } else {
            let keep = min(max(tableView.selectedRow, 0), results.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: keep), byExtendingSelection: false)
            tableView.scrollRowToVisible(keep)
        }
        updatePanelSize()
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let current = tableView.selectedRow
        let base = current < 0 ? -1 : current
        let next = max(0, min(results.count - 1, base + delta))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private var selectedItem: Item? {
        let row = tableView.selectedRow
        guard row >= 0, row < results.count else { return nil }
        return results[row]
    }

    @objc private func rowDoubleClicked() {
        perform(selectedItem, forceQuit: false)
    }

    private func perform(_ item: Item?, forceQuit: Bool) {
        guard let item = item else {
            NSSound.beep()
            return
        }
        QueryHistory.shared.record(searchField.stringValue)
        let shouldQuit = forceQuit || Indexer.quitMode(for: searchField.stringValue)
        // The paste target is whoever was frontmost before the palette; hide() clears it.
        let pasteTarget = previousApp
        hide(restoringFocus: false)

        if let content = item.snippetContent {
            guard Paster.isTrusted else {
                NSSound.beep()
                Log.write("snippet refused: Accessibility not granted; opening System Settings")
                Paster.requestTrust()
                Paster.openAccessibilitySettings()
                return
            }
            Log.write("snippet \"\(item.title)\" (\(content.count) chars) -> \(pasteTarget?.localizedName ?? "frontmost app")")
            Paster.paste(content, into: pasteTarget) { outcome in
                Log.write("snippet outcome: \(outcome)")
            }
            return
        }

        if item.kind == .stock {
            let target = item.url.flatMap { $0.hasPrefix("stock://") ? String($0.dropFirst(8)) : nil }
            if let target = target, target != "watchlist" {
                let watchlist = Config.setWatched(target, watched: true)
                config = Config.load()          // keep in step with what is now on disk
                Log.write("watchlist add \(target) (now \(watchlist.count): \(watchlist.joined(separator: ",")))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    StockWindowController.shared.show(symbol: target)
                }
            } else {
                Log.write("opening watchlist window")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    StockWindowController.shared.show(symbol: nil)
                }
            }
            return
        }

        if item.kind == .dictionary {
            let word = item.url.flatMap { $0.hasPrefix("dict://") ? String($0.dropFirst(7)) : nil } ?? item.title
            Log.write("dictionary window requested for \(word)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                DictionaryWindowController.shared.show(word: word)
            }
            return
        }

        if let urlString = item.url, let url = URL(string: urlString) {
            Log.write("open url: \(urlString)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSWorkspace.shared.open(url)
            }
            return
        }

        if let command = item.command {
            Log.write("command selected: \(command)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.onCommand?(command)
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if shouldQuit {
                guard let app = item.running else {
                    NSSound.beep()
                    Log.write("cannot quit \(item.title): it is not running")
                    return
                }
                Log.write("quit requested: \(item.title) pid=\(app.processIdentifier)")
                if !app.terminate() {
                    NSSound.beep()
                    Log.write("terminate() refused for \(item.title); leaving it to its own save prompt")
                }
            } else if let running = item.running {
                Log.write("activate: \(item.title) pid=\(running.processIdentifier)")
                if #available(macOS 14.0, *) {
                    running.activate()
                } else {
                    running.activate(options: [.activateIgnoringOtherApps])
                }
            } else if item.kind == .application {
                // Launch with activation so the app really comes to the foreground: a
                // plain open() left it behind the palette we had just activated.
                let url = URL(fileURLWithPath: item.path)
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                Log.write("launch application: \(item.path)")
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                    if let error = error {
                        Log.write("launch failed for \(item.path): \(error)")
                        NSSound.beep()
                        return
                    }
                    guard let app = app else { return }
                    Log.write("launched \(item.title) pid=\(app.processIdentifier); activating")
                    activate(app)
                    // A second nudge, because activation right after launch can race.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        if !app.isActive { activate(app) }
                    }
                }
            } else {
                Log.write("open: \(item.path)")
                if !NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) {
                    NSSound.beep()
                    Log.write("open failed: \(item.path)")
                }
            }
        }
    }

    private func icon(for item: Item) -> NSImage? {
        if item.kind == .snippet || item.kind == .webSearch || item.kind == .command
            || item.kind == .dictionary || item.kind == .stock {
            let key = "__\(item.kind.rawValue)__"
            if let cached = iconCache[key] { return cached }
            let symbolName: String
            switch item.kind {
            case .snippet: symbolName = "doc.on.clipboard"
            case .webSearch: symbolName = "globe"
            case .dictionary: symbolName = "character.book.closed"
            case .stock: symbolName = "chart.line.uptrend.xyaxis"
            default: symbolName = "command"
            }
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage()
            image.size = NSSize(width: 28, height: 28)
            iconCache[key] = image
            return image
        }
        if let cached = iconCache[item.path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: item.path)
        image.size = NSSize(width: 28, height: 28)
        iconCache[item.path] = image
        return image
    }
}

// MARK: - field delegate

extension PaletteController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        // A real keystroke ends history browsing; setting the field from history does not
        // come through here, so the flag stays true while stepping.
        browsingHistory = false
        QueryHistory.shared.stopBrowsing()
        reloadResults()
    }

    /// Puts a history entry (or the empty string) into the field and refreshes.
    private func recall(_ query: String) {
        searchField.stringValue = query
        browsingHistory = !query.isEmpty
        if query.isEmpty { QueryHistory.shared.stopBrowsing() }
        reloadResults()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            // Up on an empty field (or while already browsing) recalls what was run before,
            // the way Alfred does; with text in the field it keeps moving the row selection.
            let wantsHistory = browsingHistory || searchField.stringValue.trimmed().isEmpty
            if wantsHistory {
                if let recalled = QueryHistory.shared.stepBack() {
                    recall(recalled)
                    return true
                }
                // Already at the oldest entry (or no history at all): consume the key rather
                // than silently moving the row selection while the field is empty.
                if browsingHistory { return true }
            }
            moveSelection(-1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            if browsingHistory {
                let next = QueryHistory.shared.stepForward()
                recall(next)
                return true
            }
            moveSelection(1)
            return true
        case #selector(NSResponder.cancelOperation(_:)): // Esc
            hide(restoringFocus: true)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            let isCommand = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            perform(selectedItem, forceQuit: isCommand)
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            return true // keep Tab inside the palette
        default:
            return false
        }
    }
}

// MARK: - table

extension PaletteController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    /// Short type hint shown at the right edge of a row.
    private func kindText(for kind: ItemKind) -> String {
        switch kind {
        case .runningApp, .application: return "应用"
        case .file: return "文件"
        case .folder: return "文件夹"
        case .snippet: return "片段"
        case .command: return "命令"
        case .webSearch: return "网页"
        case .dictionary: return "词典"
        case .stock: return "股票"
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("result")
        var cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ResultCell
        if cell == nil {
            cell = ResultCell(frame: NSRect(x: 0, y: 0, width: PaletteController.panelWidth, height: PaletteController.rowHeight))
            cell?.identifier = identifier
        }
        let item = results[row]
        cell?.configure(with: item, icon: icon(for: item), kindText: kindText(for: item.kind))
        return cell
    }
}
