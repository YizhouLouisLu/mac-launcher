import AppKit

/// One watchlist row: name and code on the left, sparkline in the middle, price and change
/// on the right.
final class StockRowView: NSView {
    let nameLabel = NSTextField(labelWithString: "")
    let codeLabel = NSTextField(labelWithString: "")
    let priceLabel = NSTextField(labelWithString: "")
    let changeLabel = NSTextField(labelWithString: "")
    let sparkline = StockSparklineView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        codeLabel.textColor = .secondaryLabelColor
        priceLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        priceLabel.alignment = .right
        changeLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        changeLabel.alignment = .right
        for view in [nameLabel, codeLabel, sparkline, priceLabel, changeLabel] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func layout(width: CGFloat) {
        let height = bounds.height
        nameLabel.frame = NSRect(x: 14, y: height - 24, width: 150, height: 18)
        codeLabel.frame = NSRect(x: 14, y: height - 40, width: 150, height: 15)
        sparkline.frame = NSRect(x: 172, y: 8, width: 76, height: height - 16)
        priceLabel.frame = NSRect(x: width - 190, y: height - 24, width: 100, height: 18)
        changeLabel.frame = NSRect(x: width - 190, y: height - 41, width: 100, height: 16)
    }
}

/// The watchlist page: live quotes for every symbol plus the selected symbol's chart.
final class StockWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = StockWindowController()

    private let window: NSWindow
    private let pane = ActionPane()
    private let titleLabel = NSTextField(labelWithString: "自选股票")
    private let modeControl = NSSegmentedControl(labels: ["分时", "日K"], trackingMode: .selectOne, target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "自选为空 —— 在搜索框输入「st 关键词」搜索并回车加入")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let chart = StockChartView()
    private let removeButton = NSButton()
    private let hintLabel = NSTextField(labelWithString: "Esc / ⌘W 关闭 · Delete 移除")

    private var config = Config.load()
    private var symbols: [String] = []
    private var quotes: [String: StockQuote] = [:]
    private var trends: [String: StockTrend] = [:]
    private var dailyCache: [String: [KBar]] = [:]
    private var selectedSymbol: String?
    private var quoteTimer: Timer?
    private var chartTimer: Timer?
    private var refreshing = false
    private var previousApp: NSRunningApplication?

    private static let size = NSSize(width: 560, height: 470)

    override private init() {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: StockWindowController.size),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "自选股票"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 460, height: 380)
        buildUI()
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
                                               name: NSWindow.willCloseNotification, object: window)
    }

    // MARK: - presentation

    func show(symbol: String?) {
        config = Config.load()
        symbols = config.stockWatchlist
        if let symbol = symbol, config.isWatched(symbol) { selectedSymbol = symbol }
        if selectedSymbol == nil || !symbols.contains(selectedSymbol!) { selectedSymbol = symbols.first }

        previousApp = NSWorkspace.shared.frontmostApplication
        titleLabel.stringValue = "自选股票"
        reloadTable()
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        refreshEverything()
        startTimers()
        Log.write("stock window opened (\(symbols.count) watched)")
    }

    @objc private func close() {
        stopTimers()
        window.orderOut(nil)
        if let previous = previousApp, !previous.isTerminated {
            if #available(macOS 14.0, *) { previous.activate() }
            else { previous.activate(options: [.activateIgnoringOtherApps]) }
        }
        previousApp = nil
        Log.write("stock window closed")
    }

    @objc private func windowWillClose() { stopTimers() }

    // MARK: - data

    private func startTimers() {
        stopTimers()
        // Quotes every 5 s; charts every 60 s (minute bars do not change faster than that).
        // Outside trading hours the quote timer backs off instead of hammering a closed feed.
        let quoteInterval = tradingLooksLive() ? 5.0 : 60.0
        quoteTimer = Timer.scheduledTimer(withTimeInterval: quoteInterval, repeats: true) { [weak self] _ in
            self?.refreshQuotes()
        }
        chartTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshChart()
        }
        for timer in [quoteTimer, chartTimer] { RunLoop.main.add(timer!, forMode: .common) }
    }

    private func stopTimers() {
        quoteTimer?.invalidate(); quoteTimer = nil
        chartTimer?.invalidate(); chartTimer = nil
    }

    /// A quote whose timestamp is minutes old means the session is closed.
    private func tradingLooksLive() -> Bool {
        for quote in quotes.values where !quote.updated.isEmpty {
            let digits = quote.updated.filter { $0.isNumber }
            if digits.count >= 12, let hour = Int(digits.dropFirst(8).prefix(2)),
               let minute = Int(digits.dropFirst(10).prefix(2)) {
                let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
                let delta = abs((now.hour ?? 0) * 60 + (now.minute ?? 0) - (hour * 60 + minute))
                return delta <= 5
            }
        }
        return true
    }

    private func refreshEverything() {
        guard !refreshing else { return }
        refreshing = true
        let wanted = symbols
        let selected = selectedSymbol
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let quotes = StockQuotes.fetch(wanted)
            var trend: StockTrend?
            var bars: [KBar] = []
            if let selected = selected {
                trend = StockTrends.fetch(selected, maxAge: 10)
                bars = StockKLine.fetch(selected)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.quotes = quotes
                if let selected = selected {
                    if let trend = trend { self.trends[selected] = trend }
                    if !bars.isEmpty { self.dailyCache[selected] = bars }
                    self.chart.symbolName = selected
                    self.chart.trend = self.trends[selected]
                    self.chart.bars = self.dailyCache[selected] ?? []
                }
                self.refreshing = false
                self.reloadTable()
                self.updateStatus()
                Log.write("stock window data: \(quotes.count) quotes for \(wanted.count) symbols, trend points \(trend?.points.count ?? -1), bars \(bars.count)")
            }
        }
    }

    private func refreshQuotes() {
        let wanted = symbols
        guard !wanted.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let quotes = StockQuotes.fetch(wanted)
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard !quotes.isEmpty else { return }
                self.quotes = quotes
                self.reloadTable()
                self.updateStatus()
            }
        }
    }

    private func refreshChart() {
        guard let selected = selectedSymbol else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let trend = StockTrends.fetch(selected, maxAge: 30)
            var bars: [KBar] = []
            if self?.chart.mode == .daily { bars = StockKLine.fetch(selected) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let trend = trend {
                    self.trends[selected] = trend
                    if self.chart.mode == .intraday { self.chart.trend = trend }
                }
                if !bars.isEmpty {
                    self.dailyCache[selected] = bars
                    self.chart.bars = bars
                }
                self.updateStatus()
            }
        }
    }

    private func updateStatus() {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        let live = tradingLooksLive() ? "每 5 秒刷新" : "休市中，已降频至 60 秒"
        statusLabel.stringValue = "数据：腾讯行情 / 新浪联想 · 最后刷新 \(clock.string(from: Date())) · \(live) · 免费源可能有延迟，仅供参考"
    }

    // MARK: - table

    private func reloadTable() {
        table.reloadData()
        emptyLabel.isHidden = !symbols.isEmpty
        if let selected = selectedSymbol,
           let index = symbols.firstIndex(where: { $0.lowercased() == selected.lowercased() }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { symbols.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 50 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("stock")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? StockRowView)
            ?? StockRowView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: 50))
        cell.identifier = identifier
        let symbol = symbols[row]
        let name = quotes[symbol]?.name ?? trends[symbol]?.symbol ?? symbol
        let market = StockMarket(symbol: symbol)?.rawValue ?? ""
        cell.nameLabel.stringValue = name.isEmpty ? symbol : name
        cell.codeLabel.stringValue = "\(String(symbol.dropFirst(2))) · \(market)"
        if let quote = quotes[symbol] {
            cell.priceLabel.stringValue = quote.priceText
            cell.changeLabel.stringValue = quote.changeText
            let color: NSColor = quote.isUp ? .systemRed : .systemGreen
            cell.priceLabel.textColor = color
            cell.changeLabel.textColor = color
        } else {
            cell.priceLabel.stringValue = "—"
            cell.changeLabel.stringValue = "加载中…"
            cell.priceLabel.textColor = .secondaryLabelColor
            cell.changeLabel.textColor = .secondaryLabelColor
        }
        cell.sparkline.trend = trends[symbol]
        cell.layout(width: tableView.bounds.width)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < symbols.count else { return }
        let symbol = symbols[row]
        guard symbol != selectedSymbol else { return }
        selectedSymbol = symbol
        chart.symbolName = symbol
        chart.trend = trends[symbol]
        chart.bars = dailyCache[symbol] ?? []
        if dailyCache[symbol] == nil, chart.mode == .daily { refreshChart() }
        if trends[symbol] == nil { refreshChart() }
    }

    @objc private func modeChanged() {
        chart.mode = modeControl.selectedSegment == 1 ? .daily : .intraday
        if chart.mode == .daily, let selected = selectedSymbol, dailyCache[selected] == nil {
            refreshChart()
        }
    }

    @objc private func removeSelected() {
        guard let selected = selectedSymbol else { return }
        Config.setWatched(selected, watched: false)
        config = Config.load()
        symbols = config.stockWatchlist
        selectedSymbol = symbols.first
        quotes[selected] = nil
        trends[selected] = nil
        dailyCache[selected] = nil
        reloadTable()
        if let next = selectedSymbol {
            chart.symbolName = next
            chart.trend = trends[next]
            chart.bars = dailyCache[next] ?? []
        } else {
            chart.trend = nil
            chart.bars = []
        }
        Log.write("watchlist removed \(selected); \(symbols.count) left")
    }

    // MARK: - UI

    private func buildUI() {
        pane.frame = NSRect(origin: .zero, size: StockWindowController.size)
        pane.autoresizingMask = [.width, .height]

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        pane.addSubview(titleLabel)

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = 0
        pane.addSubview(modeControl)

        table.headerView = nil
        table.rowHeight = 50
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("stock")))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        pane.addSubview(scroll)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        pane.addSubview(emptyLabel)

        chart.mode = .intraday
        chart.wantsLayer = true
        chart.layer?.cornerRadius = 8
        chart.layer?.borderWidth = 1
        chart.layer?.borderColor = NSColor.separatorColor.cgColor
        pane.addSubview(chart)

        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        pane.addSubview(statusLabel)

        removeButton.title = "移除自选"
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        pane.addSubview(removeButton)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .right
        pane.addSubview(hintLabel)

        pane.onCancel = { [weak self] in self?.close() }
        pane.layoutBlock = { [weak self] size in
            guard let self = self else { return }
            let inset: CGFloat = 16
            let width = size.width - inset * 2
            let top: CGFloat = 36
            self.titleLabel.frame = NSRect(x: inset, y: top, width: 200, height: 22)
            self.modeControl.frame = NSRect(x: size.width - inset - 140, y: top - 2, width: 140, height: 26)
            let footerTop = size.height - 66
            // Whole rows only: a half-visible row at the bottom read as a rendering fault.
            let rowHeight: CGFloat = 50
            let tableHeight = max(rowHeight, (min(240, footerTop * 0.45) / rowHeight).rounded(.down) * rowHeight)
            self.scroll.frame = NSRect(x: inset, y: top + 34, width: width, height: tableHeight)
            self.emptyLabel.frame = NSRect(x: inset, y: top + 34 + tableHeight / 2 - 8, width: width, height: 16)
            self.chart.frame = NSRect(x: inset, y: top + 42 + tableHeight, width: width,
                                      height: max(90, footerTop - top - tableHeight - 52))
            self.statusLabel.frame = NSRect(x: inset, y: footerTop + 26, width: width, height: 15)
            self.removeButton.frame = NSRect(x: inset, y: footerTop + 2, width: 100, height: 24)
            self.hintLabel.frame = NSRect(x: size.width - inset - 260, y: footerTop + 6, width: 260, height: 16)
        }
        pane.layoutBlock?(pane.bounds.size)
        window.contentView = pane
        renderView = pane
    }

    /// The view the offscreen review renderer should draw.
    private(set) var renderView: NSView?

    // MARK: - review + regression

    func renderToPNG(path: String, symbol: String?, appearanceName: NSAppearance.Name,
                     mode: StockChartView.Mode = .intraday) {
        // Review tool only. Offscreen renders cannot rely on async delivery: in this process
        // the network callbacks landed minutes later and the pump drained nothing (measured:
        // "drawing with 0 quotes" after an 8 s wait, data at +8 min), so the caches are warmed
        // synchronously and the window is drawn from them. The real window path is unaffected
        // and does update asynchronously.
        let watched = Config.load().stockWatchlist
        symbols = watched
        selectedSymbol = symbol ?? watched.first
        if !watched.isEmpty { quotes = StockQuotes.fetch(watched, maxAge: 0) }
        if let selected = selectedSymbol {
            if let trend = StockTrends.fetch(selected, maxAge: 0) { trends[selected] = trend }
            let bars = StockKLine.fetch(selected)
            if !bars.isEmpty { dailyCache[selected] = bars }
            chart.symbolName = selected
            chart.trend = trends[selected]
            chart.bars = dailyCache[selected] ?? []
        }
        show(symbol: symbol)
        window.appearance = NSAppearance(named: appearanceName)
        chart.mode = mode
        modeControl.selectedSegment = mode == .daily ? 1 : 0
        if mode == .daily {
            chart.bars = dailyCache[selectedSymbol ?? ""] ?? chart.bars
        }
        updateStatus()
        Log.write("render stock window: drawing with \(quotes.count) quotes, \(symbols.count) symbols, trend \(chart.trend?.points.count ?? -1), bars \(chart.bars.count)")
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
        Log.write("rendered stock window (\(symbol ?? "watchlist")) to \(path)")
    }

    func selfTestEscape() -> Bool {
        show(symbol: nil)
        guard window.isVisible else { return false }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil,
                                     characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                     isARepeat: false, keyCode: 53)
        if let event = event { NSApp.sendEvent(event) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let closed = !window.isVisible
        let commandW = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: "w", charactersIgnoringModifiers: "w",
                                        isARepeat: false, keyCode: 13)
        var closedByW = false
        if let commandW = commandW {
            show(symbol: nil)
            _ = pane.performKeyEquivalent(with: commandW)
            closedByW = !window.isVisible
        }
        Log.write("stock window selftest: Esc closed=\(closed) ⌘W closed=\(closedByW)")
        return closed && closedByW
    }
}
