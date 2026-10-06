import Foundation

// MARK: - model

enum StockMarket: String {
    case aShare = "A股"
    case hongKong = "港股"
    case unitedStates = "美股"

    init?(symbol: String) {
        let prefix = symbol.prefix(2).lowercased()
        switch prefix {
        case "sh", "sz": self = .aShare
        case "hk": self = .hongKong
        case "us": self = .unitedStates
        default: return nil
        }
    }
}

struct StockSymbol: Equatable {
    /// Market-prefixed code as the feeds use it: `sh600519`, `hk00700`, `usAAPL`.
    let code: String
    let name: String

    var market: StockMarket { StockMarket(symbol: code) ?? .aShare }
    var plainCode: String { String(code.dropFirst(2)) }
}

struct StockQuote {
    let symbol: String
    let name: String
    let price: Double
    let previousClose: Double
    let open: Double
    let high: Double
    let low: Double
    /// Raw timestamp from the feed ("20260930161458" or "2026/10/05 16:08:09").
    let updated: String

    /// Computed rather than read from a fixed field: the change/percent positions differ
    /// between A-shares, Hong Kong and US rows.
    var change: Double { price - previousClose }
    var changePercent: Double { previousClose > 0 ? (price / previousClose - 1) * 100 : 0 }
    var isUp: Bool { change >= 0 }

    var priceText: String { String(format: "%.2f", price) }
    var changeText: String { String(format: "%@%.2f  %@%.2f%%", isUp ? "+" : "", change, isUp ? "+" : "", changePercent) }
}

struct TrendPoint {
    let minute: Int          // minutes since midnight, from HHMM
    let price: Double
    let volume: Double
}

struct StockTrend {
    let symbol: String
    let date: String
    let previousClose: Double
    let points: [TrendPoint]
}

struct KBar {
    let date: String
    let open: Double
    let close: Double
    let high: Double
    let low: Double
    let volume: Double
}

// MARK: - decoding helpers

/// Sina and Tencent serve GBK/GB18030; Foundation needs the raw encoding constant.
private func gb18030(_ data: Data) -> String? {
    let encoding = CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
    return String(data: data, encoding: String.Encoding(rawValue: encoding))
}

private func httpData(_ url: String, referer: String? = nil, timeout: TimeInterval = 6) -> Data? {
    guard let parsed = URL(string: url) else { return nil }
    var request = URLRequest(url: parsed)
    request.timeoutInterval = timeout
    if let referer = referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
    request.setValue("MacLauncher/0.1", forHTTPHeaderField: "User-Agent")

    let semaphore = DispatchSemaphore(value: 0)
    var result: Data?
    URLSession.shared.dataTask(with: request) { data, _, _ in
        result = data
        semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + timeout + 2)
    return result
}

// MARK: - search (Sina suggest)

/// Symbol lookup through Sina's suggest endpoint: matches codes, Chinese names and pinyin
/// initials (`gzmt` → 贵州茅台), in 60–190 ms measured.
enum StockSearch {
    private static var cache: [String: (hits: [StockSymbol], at: Date)] = [:]
    private static let lock = NSLock()

    /// Cache-only read used by the main-thread path: the palette must never block on a
    /// network call, so it renders whatever is already known and the background refresh
    /// corrects it a moment later.
    static func cachedSuggest(_ query: String, maxAge: TimeInterval = 60) -> [StockSymbol]? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = cache[query.trimmed().lowercased()],
              Date().timeIntervalSince(entry.at) <= maxAge else { return nil }
        return entry.hits
    }

    static func suggest(_ query: String, limit: Int = 6) -> [StockSymbol] {
        let trimmed = query.trimmed()
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let data = httpData("https://suggest3.sinajs.cn/suggest/type=11,12,31,41&key=\(encoded)"),
              let text = gb18030(data),
              let start = text.firstIndex(of: "\""), let end = text.lastIndex(of: "\"")
        else { return [] }

        let body = String(text[text.index(after: start)..<end])
        var results: [StockSymbol] = []
        var seen = Set<String>()
        for hit in body.split(separator: ";") {
            let fields = hit.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5 else { continue }
            // A-shares arrive already prefixed (`sh600519`); Hong Kong and US arrive as bare
            // codes whose market is only implied by the numeric type field (measured:
            // 31 = HK `00700`, 41 = US `aapl`). Field 4 is the display name — field 0 is the
            // code itself when the query was a code, which is why names must come from 4.
            let type = fields[1]
            let raw = fields[2].lowercased()
            let symbol: String
            switch type {
            case "11", "12": symbol = fields[3].lowercased()
            case "31": symbol = "hk" + raw
            case "41": symbol = "us" + raw.uppercased()
            default: continue
            }
            guard StockMarket(symbol: symbol) != nil, seen.insert(symbol).inserted else { continue }
            let name = fields[4].isEmpty ? fields[0] : fields[4]
            results.append(StockSymbol(code: symbol, name: name))
            if results.count >= limit { break }
        }
        lock.lock()
        if cache.count > 100 { cache.removeAll() }
        cache[trimmed.lowercased()] = (results, Date())
        lock.unlock()
        return results
    }
}

// MARK: - quotes (Tencent batch)

enum StockQuotes {
    private static var cache: [String: (quote: StockQuote, at: Date)] = [:]
    private static let lock = NSLock()

    /// The feed's own spelling: US tickers must be uppercase (`usAAPL`) while A-share and
    /// Hong Kong codes are lowercase. Sending the wrong case returns an empty row — measured:
    /// `q=usaapl` yields nothing.
    static func wireSymbol(_ symbol: String) -> String {
        let trimmed = symbol.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("us") {
            return "us" + trimmed.dropFirst(2).uppercased()
        }
        return trimmed.lowercased()
    }

    /// The cache and the wire format disagree on case — US tickers must be sent as `usAAPL`
    /// but callers may hand us `usaapl`; keys are therefore compared lowercased. Getting this
    /// wrong silently dropped every US row while A-shares looked fine.
    static func cached(_ symbols: [String], maxAge: TimeInterval) -> [String: StockQuote] {
        lock.lock(); defer { lock.unlock() }
        var fresh: [String: StockQuote] = [:]
        for symbol in symbols {
            if let entry = cache[symbol.lowercased()], Date().timeIntervalSince(entry.at) <= maxAge {
                fresh[symbol] = entry.quote
            }
        }
        return fresh
    }

    /// One request for every symbol (A-shares, Hong Kong and US quotes come back together).
    static func fetch(_ symbols: [String], maxAge: TimeInterval = 2) -> [String: StockQuote] {
        guard !symbols.isEmpty else { return [:] }
        var result = cached(symbols, maxAge: maxAge)
        let missing = symbols.filter { result[$0] == nil }
        guard !missing.isEmpty else { return result }

        let joined = missing.map(StockQuotes.wireSymbol).joined(separator: ",")
        guard let data = httpData("https://qt.gtimg.cn/q=\(joined)"), let text = gb18030(data) else {
            return result
        }
        // Parsed quotes are keyed lowercase, then handed back under the caller's spelling.
        var parsed: [String: StockQuote] = [:]
        for line in text.split(separator: ";") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let symbol = line[line.startIndex..<equals].replacingOccurrences(of: "v_", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let payload = line[line.index(after: equals)...]
            let fields = payload.replacingOccurrences(of: "\"", with: "")
                .split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            guard fields.count > 33,
                  let price = Double(fields[3]), price > 0 || fields[3] == "0",
                  let previousClose = Double(fields[4])
            else { continue }
            // The timestamp position differs per market, so find it by shape.
            let updated = fields.first { $0.contains(":") && ($0.contains("-") || $0.contains("/")) } ?? ""
            let quote = StockQuote(symbol: symbol,
                                   name: fields[1],
                                   price: price,
                                   previousClose: previousClose,
                                   open: Double(fields[5]) ?? 0,
                                   high: Double(fields[33]) ?? 0,
                                   low: Double(fields[34]) ?? 0,
                                   updated: updated)
            store(quote)
            parsed[symbol] = quote
        }
        for symbol in missing {
            if let quote = parsed[symbol.lowercased()] { result[symbol] = quote }
        }
        return result
    }

    private static func store(_ quote: StockQuote) {
        lock.lock()
        cache[quote.symbol.lowercased()] = (quote, Date())
        lock.unlock()
    }
}

// MARK: - intraday trend (Tencent minute series)

enum StockTrends {
    private static var cache: [String: (trend: StockTrend, at: Date)] = [:]
    private static let lock = NSLock()

    static func cached(_ symbol: String, maxAge: TimeInterval) -> StockTrend? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = cache[symbol], Date().timeIntervalSince(entry.at) <= maxAge else { return nil }
        return entry.trend
    }

    /// Minute bars for the current session: `"0930 1239.53 161 19956433.00"` is
    /// `HHMM price volume amount`. The same response carries the full quote, which supplies
    /// the previous close used as the chart baseline.
    static func fetch(_ symbol: String, maxAge: TimeInterval = 60) -> StockTrend? {
        if let cached = cached(symbol, maxAge: maxAge) { return cached }
        guard let data = httpData("https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=\(symbol)"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = (root["data"] as? [String: Any])?[symbol] as? [String: Any],
              let series = payload["data"] as? [String: Any]
        else { return nil }

        let rawBars = (series["data"] as? [String]) ?? []
        var points: [TrendPoint] = []
        for bar in rawBars {
            let parts = bar.split(separator: " ").map(String.init)
            guard parts.count >= 3, parts[0].count == 4,
                  let hour = Int(parts[0].prefix(2)), let minute = Int(parts[0].suffix(2)),
                  let price = Double(parts[1]) else { continue }
            points.append(TrendPoint(minute: hour * 60 + minute,
                                     price: price,
                                     volume: Double(parts[2]) ?? 0))
        }
        guard !points.isEmpty else { return nil }

        var previousClose = 0.0
        if let quoteRoot = payload["qt"] as? [String: Any],
           let fields = quoteRoot[symbol] as? [String], fields.count > 4 {
            previousClose = Double(fields[4]) ?? 0
        }
        let trend = StockTrend(symbol: symbol,
                               date: series["date"] as? String ?? "",
                               previousClose: previousClose,
                               points: points)
        lock.lock()
        cache[symbol] = (trend, Date())
        lock.unlock()
        return trend
    }
}

// MARK: - daily candles (Tencent, forward adjusted)

enum StockKLine {
    /// Tencent's forward-adjusted daily series is wrong for US tickers — it returned exactly
    /// two bars, one of them from 2011 — so US rows come from Sina instead (full history,
    /// JSON keyed by d/o/h/l/c/v). Hong Kong works on Tencent (Sina's HK service answers
    /// "Service not valid").
    static func fetch(_ symbol: String, days: Int = 60) -> [KBar] {
        if StockMarket(symbol: symbol) == .unitedStates {
            return fetchUS(symbol, days: days)
        }
        return fetchTencent(symbol, days: days)
    }

    private static func fetchUS(_ symbol: String, days: Int) -> [KBar] {
        let ticker = String(symbol.dropFirst(2)).uppercased()
        guard let data = httpData("https://stock.finance.sina.com.cn/usstock/api/jsonp.php/var%20_x/US_MinKService.getDailyK?symbol=\(ticker)&___qn=3", timeout: 10),
              let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]")
        else { return [] }
        let json = String(text[start...end])
        guard let rows = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        let bars: [KBar] = rows.compactMap { row in
            guard let date = row["d"] as? String,
                  let open = Double("\(row["o"] ?? "")"), let close = Double("\(row["c"] ?? "")"),
                  let high = Double("\(row["h"] ?? "")"), let low = Double("\(row["l"] ?? "")")
            else { return nil }
            return KBar(date: date, open: open, close: close, high: high, low: low,
                        volume: Double("\(row["v"] ?? "0")") ?? 0)
        }
        return Array(bars.suffix(days))
    }

    private static func fetchTencent(_ symbol: String, days: Int) -> [KBar] {
        guard let data = httpData("https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=\(symbol),day,,,\(days),qfq"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = (root["data"] as? [String: Any])?[symbol] as? [String: Any]
        else { return [] }

        let rows = (payload["qfqday"] as? [[Any]]) ?? (payload["day"] as? [[Any]]) ?? []
        return rows.compactMap { row in
            guard row.count >= 6,
                  let date = row[0] as? String,
                  let open = Double("\(row[1])"), let close = Double("\(row[2])"),
                  let high = Double("\(row[3])"), let low = Double("\(row[4])"),
                  let volume = Double("\(row[5])")
            else { return nil }
            return KBar(date: date, open: open, close: close, high: high, low: low, volume: volume)
        }
    }
}
