import AppKit

/// Live chart for one symbol. Two modes, both drawn by hand so there is no chart dependency:
/// intraday minute line (with the previous close as the baseline) and daily candles.
/// Colours follow the mainland convention — red is up, green is down.
final class StockChartView: NSView {
    enum Mode: Int { case intraday = 0, daily = 1 }

    var mode: Mode = .intraday { didSet { needsDisplay = true } }
    var trend: StockTrend? { didSet { needsDisplay = true } }
    var bars: [KBar] = [] { didSet { needsDisplay = true } }
    var symbolName: String = "" { didSet { needsDisplay = true } }

    private let upColor = NSColor.systemRed
    private let downColor = NSColor.systemGreen
    private let gridColor = NSColor.separatorColor.withAlphaComponent(0.5)
    private let inset = NSEdgeInsets(top: 14, left: 46, bottom: 20, right: 52)

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        switch mode {
        case .intraday: drawIntraday()
        case .daily: drawDaily()
        }
    }

    // MARK: - intraday

    private func drawIntraday() {
        guard let trend = trend, trend.points.count > 1 else {
            drawPlaceholder("暂无分时数据")
            return
        }
        let points = trend.points
        let baseline = trend.previousClose > 0 ? trend.previousClose : points[0].price
        var prices = points.map { $0.price }
        prices.append(baseline)
        guard let low = prices.min(), let high = prices.max(), high > low else {
            drawPlaceholder("暂无分时数据")
            return
        }
        let pad = (high - low) * 0.08
        let minPrice = low - pad, maxPrice = high + pad

        let plot = NSRect(x: inset.left, y: inset.bottom,
                          width: bounds.width - inset.left - inset.right,
                          height: bounds.height - inset.top - inset.bottom)
        guard plot.width > 10, plot.height > 10 else { return }

        // Session window: the axis covers the whole trading day so a half-finished session
        // does not stretch across the full width.
        let firstMinute = points.first?.minute ?? 570
        let lastMinute = max(points.last?.minute ?? 900, firstMinute + 1)
        func x(_ minute: Int) -> CGFloat {
            let span = CGFloat(max(lastMinute - firstMinute, 1))
            return plot.minX + CGFloat(minute - firstMinute) / span * plot.width
        }
        func y(_ price: Double) -> CGFloat {
            plot.minY + CGFloat((price - minPrice) / (maxPrice - minPrice)) * plot.height
        }

        // Previous close: dashed baseline and axis label.
        let baselineColor = NSColor.tertiaryLabelColor
        baselineColor.setStroke()
        let dash = NSBezierPath()
        dash.setLineDash([3, 3], count: 2, phase: 0)
        dash.move(to: NSPoint(x: plot.minX, y: y(baseline)))
        dash.line(to: NSPoint(x: plot.maxX, y: y(baseline)))
        dash.lineWidth = 1
        dash.stroke()

        gridColor.setStroke()
        for fraction in [0.0, 0.5, 1.0] {
            let line = NSBezierPath()
            let price = minPrice + (maxPrice - minPrice) * fraction
            line.move(to: NSPoint(x: plot.minX, y: y(price)))
            line.line(to: NSPoint(x: plot.maxX, y: y(price)))
            line.lineWidth = 0.5
            line.stroke()
        }

        let last = points[points.count - 1].price
        let color = last >= baseline ? upColor : downColor

        let path = NSBezierPath()
        path.move(to: NSPoint(x: x(points[0].minute), y: y(points[0].price)))
        for point in points.dropFirst() {
            path.line(to: NSPoint(x: x(point.minute), y: y(point.price)))
        }
        color.setStroke()
        path.lineWidth = 1.6
        path.stroke()

        // Translucent fill under the line.
        let fill = path.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: x(points[points.count - 1].minute), y: plot.minY))
        fill.line(to: NSPoint(x: x(points[0].minute), y: plot.minY))
        fill.close()
        color.withAlphaComponent(0.12).setFill()
        fill.fill()

        drawAxisLabels(minPrice: minPrice, maxPrice: maxPrice, baseline: baseline,
                       plot: plot, y: y, color: color, last: last)
    }

    private func drawAxisLabels(minPrice: Double, maxPrice: Double, baseline: Double,
                               plot: NSRect, y: (Double) -> CGFloat,
                               color: NSColor, last: Double) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        func label(_ text: String, at point: NSPoint, alignRight: Bool) {
            let size = (text as NSString).size(withAttributes: attributes)
            let x = alignRight ? point.x - size.width : point.x
            (text as NSString).draw(at: NSPoint(x: x, y: point.y - size.height / 2), withAttributes: attributes)
        }
        label(String(format: "%.2f", maxPrice), at: NSPoint(x: plot.maxX + 4, y: plot.maxY), alignRight: false)
        label(String(format: "%.2f", minPrice), at: NSPoint(x: plot.maxX + 4, y: plot.minY), alignRight: false)
        label(String(format: "%.2f", baseline), at: NSPoint(x: plot.maxX + 4, y: y(baseline)), alignRight: false)

        let percent = baseline > 0 ? (last / baseline - 1) * 100 : 0
        let changeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: color
        ]
        let changeText = String(format: "%@%.2f%%", percent >= 0 ? "+" : "", percent)
        let size = (changeText as NSString).size(withAttributes: changeAttributes)
        (changeText as NSString).draw(at: NSPoint(x: plot.maxX + 4, y: plot.maxY - size.height - 4),
                                      withAttributes: changeAttributes)
    }

    // MARK: - daily candles

    private func drawDaily() {
        guard bars.count > 1 else {
            drawPlaceholder("暂无日 K 数据")
            return
        }
        let visible = Array(bars.suffix(90))
        guard let low = visible.map({ $0.low }).min(),
              let high = visible.map({ $0.high }).max(), high > low else { return }

        let volumeHeight: CGFloat = 26
        let plot = NSRect(x: inset.left, y: inset.bottom + volumeHeight + 6,
                          width: bounds.width - inset.left - inset.right,
                          height: bounds.height - inset.top - inset.bottom - volumeHeight - 6)
        guard plot.width > 10, plot.height > 10 else { return }

        func y(_ price: Double) -> CGFloat {
            plot.minY + CGFloat((price - low) / (high - low)) * plot.height
        }
        let slot = plot.width / CGFloat(visible.count)
        let bodyWidth = max(1.5, slot * 0.62)

        gridColor.setStroke()
        for fraction in [0.0, 0.5, 1.0] {
            let line = NSBezierPath()
            let price = low + (high - low) * fraction
            line.move(to: NSPoint(x: plot.minX, y: y(price)))
            line.line(to: NSPoint(x: plot.maxX, y: y(price)))
            line.lineWidth = 0.5
            line.stroke()
        }

        let maxVolume = visible.map { $0.volume }.max() ?? 1
        for (index, bar) in visible.enumerated() {
            let centerX = plot.minX + slot * (CGFloat(index) + 0.5)
            let rising = bar.close >= bar.open
            let color = rising ? upColor : downColor
            color.setStroke()
            color.setFill()

            let wick = NSBezierPath()
            wick.move(to: NSPoint(x: centerX, y: y(bar.high)))
            wick.line(to: NSPoint(x: centerX, y: y(bar.low)))
            wick.lineWidth = 0.8
            wick.stroke()

            let top = y(max(bar.open, bar.close))
            let bottom = y(min(bar.open, bar.close))
            let body = NSRect(x: centerX - bodyWidth / 2, y: bottom,
                              width: bodyWidth, height: max(1, top - bottom))
            let bodyPath = NSBezierPath(rect: body)
            if rising {
                color.withAlphaComponent(0.9).setFill()
                bodyPath.fill()
            } else {
                bodyPath.fill()
            }

            let volumeBar = NSRect(x: centerX - bodyWidth / 2, y: inset.bottom - volumeHeight,
                                   width: bodyWidth,
                                   height: max(1, CGFloat(bar.volume / max(maxVolume, 1)) * (volumeHeight - 4)))
            color.withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: volumeBar).fill()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        ("\(visible.count) 个交易日  高 \(String(format: "%.2f", high))  低 \(String(format: "%.2f", low))" as NSString)
            .draw(at: NSPoint(x: plot.minX, y: bounds.height - 12), withAttributes: attributes)
    }

    private func drawPlaceholder(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                            y: (bounds.height - size.height) / 2),
                                withAttributes: attributes)
    }
}

/// Small line sparkline for a watchlist row.
final class StockSparklineView: NSView {
    var trend: StockTrend?
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let trend = trend, trend.points.count > 1 else { return }
        let prices = trend.points.map { $0.price }
        guard let low = prices.min(), let high = prices.max(), high > low else { return }
        let baseline = trend.previousClose > 0 ? trend.previousClose : prices[0]
        let color = prices[prices.count - 1] >= baseline ? NSColor.systemRed : NSColor.systemGreen
        let inset: CGFloat = 2
        let plot = bounds.insetBy(dx: inset, dy: inset)
        let step = plot.width / CGFloat(prices.count - 1)
        let path = NSBezierPath()
        for (index, price) in prices.enumerated() {
            let point = NSPoint(x: plot.minX + step * CGFloat(index),
                                y: plot.minY + CGFloat((price - low) / (high - low)) * plot.height)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        color.setStroke()
        path.lineWidth = 1.2
        path.stroke()
    }
}
